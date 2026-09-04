import Foundation

struct RecentThread: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let projectPath: String?
    let rolloutPath: String?
    let updatedAt: Date

    var projectDisplayName: String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }
}

enum RecentThreadReaderError: LocalizedError {
    case executableUnavailable
    case serverFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "没有找到桌面任务应用的本机命令行组件"
        case .serverFailed(let detail):
            return detail.isEmpty ? "最近任务读取失败" : "最近任务读取失败：\(detail)"
        case .invalidResponse:
            return "最近任务返回了无法识别的数据"
        }
    }
}

struct RecentThreadReader: Sendable {
    func listThreads(limit: Int = 30) async throws -> [RecentThread] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try listThreadsSynchronously(limit: limit))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func listThreadsSynchronously(limit: Int) throws -> [RecentThread] {
        let executableCandidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path,
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        guard let executable = executableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RecentThreadReaderError.executableUnavailable
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let initialize: [String: Any] = [
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "kayla-monitor",
                    "title": "Kayla Monitor",
                    "version": "0.3.4"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        ]
        let list: [String: Any] = [
            "id": 2,
            "method": "thread/list",
            "params": [
                "limit": max(1, min(limit, 100)),
                "sortKey": "recency_at",
                "sortDirection": "desc"
            ]
        ]

        let responseSemaphore = DispatchSemaphore(value: 0)
        let responseLock = NSLock()
        var buffer = Data()
        var rows: [[String: Any]]?
        var responseError: Error?
        var listWasSent = false
        var responseFinished = false

        func encodeLine(_ request: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            return data
        }

        let initializeLine = try encodeLine(initialize)
        let listLine = try encodeLine(list)
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let incoming = handle.availableData
            guard !incoming.isEmpty else { return }

            var shouldSendList = false
            responseLock.lock()
            buffer.append(incoming)
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                guard
                    let object = try? JSONSerialization.jsonObject(with: Data(line)),
                    let dictionary = object as? [String: Any],
                    let responseID = (dictionary["id"] as? NSNumber)?.intValue
                else { continue }

                if responseID == 1, !listWasSent {
                    listWasSent = true
                    shouldSendList = true
                } else if responseID == 2, !responseFinished {
                    if
                        let result = dictionary["result"] as? [String: Any],
                        let data = result["data"] as? [[String: Any]]
                    {
                        rows = data
                    } else {
                        responseError = RecentThreadReaderError.invalidResponse
                    }
                    responseFinished = true
                    responseSemaphore.signal()
                }
            }
            responseLock.unlock()

            if shouldSendList {
                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: listLine)
                } catch {
                    responseLock.lock()
                    if !responseFinished {
                        responseError = error
                        responseFinished = true
                        responseSemaphore.signal()
                    }
                    responseLock.unlock()
                }
            }
        }

        try process.run()
        try inputPipe.fileHandleForWriting.write(contentsOf: initializeLine)

        let waitResult = responseSemaphore.wait(timeout: .now() + 6)
        outputPipe.fileHandleForReading.readabilityHandler = nil
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        if waitResult == .timedOut {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RecentThreadReaderError.serverFailed(detail.isEmpty ? "读取超时" : detail)
        }
        if let responseError {
            throw responseError
        }
        guard let rows else {
            throw RecentThreadReaderError.invalidResponse
        }

        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = (row["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String
            if let name, !name.isEmpty {
                title = name
            } else if let preview, !preview.isEmpty {
                title = String(preview.prefix(80))
            } else {
                title = "任务 \(String(id.prefix(8)))"
            }
            let updatedAt = (row["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            return RecentThread(
                id: id,
                title: title,
                projectPath: row["cwd"] as? String,
                rolloutPath: row["path"] as? String,
                updatedAt: updatedAt
            )
        }
    }
}
