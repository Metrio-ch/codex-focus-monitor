import Darwin
import Foundation

public struct MonitorPaths: Sendable {
    public let rootDirectory: URL
    public let stateFile: URL
    public let eventLogFile: URL

    public init(rootDirectory: URL? = nil) {
        let root: URL
        if let rootDirectory {
            root = rootDirectory
        } else if let override = ProcessInfo.processInfo.environment["KAYLA_MONITOR_HOME"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Kayla Monitor", isDirectory: true)
        }
        self.rootDirectory = root
        self.stateFile = root.appendingPathComponent("state.json")
        self.eventLogFile = root.appendingPathComponent("events.jsonl")
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectory.path
        )
    }
}

public enum MonitorJSON {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

public struct StateRepository: Sendable {
    public let paths: MonitorPaths

    public init(paths: MonitorPaths = MonitorPaths()) {
        self.paths = paths
    }

    public func load() -> MonitorState {
        guard
            let data = try? Data(contentsOf: paths.stateFile),
            var state = try? MonitorJSON.decoder().decode(MonitorState.self, from: data)
        else {
            return MonitorState()
        }
        state.normalize()
        return state
    }

    public func save(_ state: MonitorState) throws {
        try paths.ensureDirectory()
        var normalized = state
        normalized.normalize()
        let data = try MonitorJSON.encoder(pretty: true).encode(normalized)
        try data.write(to: paths.stateFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateFile.path)
    }
}

public struct EventLog: Sendable {
    public let paths: MonitorPaths
    private var readOffset: UInt64 = 0
    private var readFileNumber: UInt64?
    private var partialLine = Data()

    public init(paths: MonitorPaths = MonitorPaths()) {
        self.paths = paths
    }

    public func append(_ event: HookEvent) throws {
        try paths.ensureDirectory()
        var line = try MonitorJSON.encoder().encode(event)
        line.append(0x0A)

        let descriptor = Darwin.open(paths.eventLogFile.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }

        try line.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var pointer = base
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        _ = fsync(descriptor)
    }

    public func readAll() -> [HookEvent] {
        guard let data = try? Data(contentsOf: paths.eventLogFile) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? MonitorJSON.decoder().decode(HookEvent.self, from: Data(line))
        }
    }

    public mutating func readNew() -> [HookEvent] {
        guard let handle = try? FileHandle(forReadingFrom: paths.eventLogFile) else { return [] }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else { return [] }
        let fileNumber = UInt64(info.st_ino)
        let fileSize = UInt64(info.st_size)
        if readFileNumber != fileNumber || fileSize < readOffset {
            readOffset = 0
            partialLine = Data()
            readFileNumber = fileNumber
        }
        guard fileSize > readOffset else { return [] }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            readOffset += UInt64(data.count)
            partialLine.append(data)
        } catch {
            return []
        }

        // Keep an unfinished append until its newline arrives on a later poll.
        guard let lastNewline = partialLine.lastIndex(of: 0x0A) else { return [] }
        let completeLines = partialLine.prefix(through: lastNewline)
        let events = completeLines.split(separator: 0x0A).compactMap { line in
            try? MonitorJSON.decoder().decode(HookEvent.self, from: Data(line))
        }
        partialLine = Data(partialLine.suffix(from: partialLine.index(after: lastNewline)))
        return events
    }
}
