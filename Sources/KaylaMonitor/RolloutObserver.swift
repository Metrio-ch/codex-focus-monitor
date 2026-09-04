import Foundation
import KaylaMonitorCore

struct RolloutPollResult {
    let threadID: String
    let rolloutPath: String
    let observation: RolloutObservation
    let isInitialRead: Bool
}

final class RolloutObserver {
    private struct Cursor {
        var rolloutPath: String
        var offset: UInt64
        var partialLine: Data
        var observation: RolloutObservation
    }

    private let initialTailBytes: UInt64 = 16 * 1_024 * 1_024
    private let sessionsRoot: URL
    private var cursors: [String: Cursor] = [:]
    private var locatedPaths: [String: String] = [:]
    private var lastDiscoveryAt = Date.distantPast

    init(sessionsRoot: URL? = nil) {
        self.sessionsRoot = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func poll(tasks: [TaskCard]) -> [RolloutPollResult] {
        let activeIDs = Set(tasks.map(\.threadID))
        cursors = cursors.filter { activeIDs.contains($0.key) }
        locatedPaths = locatedPaths.filter { activeIDs.contains($0.key) }

        let missingIDs = Set(tasks.compactMap { task -> String? in
            if let path = task.rolloutPath, FileManager.default.fileExists(atPath: path) {
                locatedPaths[task.threadID] = path
                return nil
            }
            if let path = locatedPaths[task.threadID], FileManager.default.fileExists(atPath: path) {
                return nil
            }
            return task.threadID
        })
        if !missingIDs.isEmpty, Date().timeIntervalSince(lastDiscoveryAt) >= 10 {
            discoverPaths(for: missingIDs)
            lastDiscoveryAt = Date()
        }

        return tasks.compactMap { task in
            let path = task.rolloutPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? locatedPaths[task.threadID]
            guard let path else { return nil }
            return readChanges(threadID: task.threadID, rolloutPath: path)
        }
    }

    private func discoverPaths(for threadIDs: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var remaining = threadIDs
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            for threadID in Array(remaining) where fileURL.lastPathComponent.hasSuffix("\(threadID).jsonl") {
                locatedPaths[threadID] = fileURL.path
                remaining.remove(threadID)
                break
            }
            if remaining.isEmpty { break }
        }
    }

    private func readChanges(threadID: String, rolloutPath: String) -> RolloutPollResult? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: rolloutPath),
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
            let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: rolloutPath))
        else { return nil }
        defer { try? handle.close() }

        var cursor = cursors[threadID]
        let isInitialRead = cursor == nil || cursor?.rolloutPath != rolloutPath || fileSize < (cursor?.offset ?? 0)
        if isInitialRead {
            let start = fileSize > initialTailBytes ? fileSize - initialTailBytes : 0
            try? handle.seek(toOffset: start)
            var data = (try? handle.readToEnd()) ?? Data()
            if start > 0, let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(...newline)
            }
            cursor = Cursor(
                rolloutPath: rolloutPath,
                offset: fileSize,
                partialLine: Data(),
                observation: RolloutObservation()
            )
            _ = parse(data, cursor: &cursor!)
            cursors[threadID] = cursor
            return RolloutPollResult(
                threadID: threadID,
                rolloutPath: rolloutPath,
                observation: cursor!.observation,
                isInitialRead: true
            )
        }

        guard var existing = cursor, fileSize > existing.offset else { return nil }
        try? handle.seek(toOffset: existing.offset)
        let data = (try? handle.readToEnd()) ?? Data()
        existing.offset = fileSize
        let changed = parse(data, cursor: &existing)
        cursors[threadID] = existing
        guard changed else { return nil }
        return RolloutPollResult(
            threadID: threadID,
            rolloutPath: rolloutPath,
            observation: existing.observation,
            isInitialRead: false
        )
    }

    private func parse(_ newData: Data, cursor: inout Cursor) -> Bool {
        var buffer = cursor.partialLine
        buffer.append(newData)
        var changed = false

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer.prefix(upTo: newline))
            buffer.removeSubrange(...newline)
            guard RolloutRecordParser.looksRelevant(line) else { continue }
            changed = RolloutRecordParser.apply(line: line, to: &cursor.observation) || changed
        }
        cursor.partialLine = buffer
        return changed
    }
}
