import Foundation
import KaylaMonitorCore

if CommandLine.arguments.contains("--self-test") {
    do {
        let count = try CoreSelfChecks.run()
        print("{\"status\":\"passed\",\"checks\":\(count)}")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("self-test failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

// Hooks must never delay or block the user's task. Every failure is intentionally
// swallowed after a best-effort local append; the process always exits 0.
let input = FileHandle.standardInput.readDataToEndOfFile()
let paths = MonitorPaths()
let state = StateRepository(paths: paths).load()

if let event = HookPayloadParser.parse(input, selectedThreadIDs: state.selectedThreadIDs) {
    try? EventLog(paths: paths).append(event)
}

exit(EXIT_SUCCESS)
