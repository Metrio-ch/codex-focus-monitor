import Foundation

public struct RolloutObservation: Equatable, Sendable {
    public var status: KaylaStatus?
    public var statusAt: Date?
    public var latestTurnID: String?
    public var lastUserExcerpt: String?
    public var lastUserAt: Date?
    public var lastAssistantExcerpt: String?
    public var lastAssistantAt: Date?
    public var lastActivityAt: Date?
    public var blocker: TaskBlocker?
    public var currentTurnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?

    public init() {}
}

public enum RolloutRecordParser {
    @discardableResult
    public static func apply(line: Data, to observation: inout RolloutObservation) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let record = object as? [String: Any],
            let timestampText = record["timestamp"] as? String,
            let timestamp = parseTimestamp(timestampText),
            let recordType = record["type"] as? String,
            let payload = record["payload"] as? [String: Any]
        else {
            return false
        }

        var changed = false
        if isActivityRecord(recordType: recordType, payload: payload), observation.lastActivityAt == nil || timestamp >= observation.lastActivityAt! {
            observation.lastActivityAt = timestamp
            changed = true
        }
        if recordType == "event_msg", let eventType = payload["type"] as? String {
            switch eventType {
            case "task_started":
                if observation.statusAt == nil || timestamp >= observation.statusAt! {
                    observation.status = .processing
                    observation.statusAt = timestamp
                    observation.latestTurnID = string(in: payload, keys: ["turn_id", "turnId"])
                    observation.currentTurnStartedAt = timestamp
                    observation.lastTurnDuration = nil
                    observation.blocker = nil
                    changed = true
                }
            case "task_complete":
                if observation.statusAt == nil || timestamp >= observation.statusAt! {
                    observation.status = .awaitingDecision
                    observation.statusAt = timestamp
                    observation.latestTurnID = string(in: payload, keys: ["turn_id", "turnId"])
                    observation.lastTurnDuration = duration(from: observation.currentTurnStartedAt, to: timestamp)
                    observation.blocker = nil
                    changed = true
                }
            case "turn_aborted":
                if observation.statusAt == nil || timestamp >= observation.statusAt! {
                    let reason = string(in: payload, keys: ["reason"]) ?? "unknown"
                    observation.status = .needsConfirmation
                    observation.statusAt = timestamp
                    observation.latestTurnID = string(in: payload, keys: ["turn_id", "turnId"])
                    observation.lastTurnDuration = duration(from: observation.currentTurnStartedAt, to: timestamp)
                    observation.blocker = TaskBlocker(
                        kind: .interrupted,
                        summary: reason == "interrupted" ? "本轮已被中断，请决定是否继续" : "本轮异常结束：\(reason)",
                        detectedAt: timestamp
                    )
                    changed = true
                }
            case "agent_message":
                if let message = payload["message"] as? String {
                    changed = updateAssistant(message, at: timestamp, observation: &observation) || changed
                }
            default:
                break
            }
        }

        if recordType == "response_item", let itemType = payload["type"] as? String {
            switch itemType {
            case "custom_tool_call", "function_call":
                let callID = string(in: payload, keys: ["call_id", "callId"])
                let name = string(in: payload, keys: ["name"]) ?? ""
                let input = string(in: payload, keys: ["input", "arguments"]) ?? ""
                if name.localizedCaseInsensitiveContains("request_user_input") {
                    observation.blocker = TaskBlocker(
                        kind: .needsInput,
                        summary: userInputSummary(from: input) ?? "Kayla 正在等待你回答一个问题",
                        detectedAt: timestamp,
                        callID: callID
                    )
                    changed = true
                } else if requestsEscalatedPermission(input) {
                    observation.blocker = TaskBlocker(
                        kind: .needsApproval,
                        summary: approvalSummary(from: input) ?? "Kayla 正在等待你批准一项系统操作",
                        detectedAt: timestamp,
                        callID: callID
                    )
                    changed = true
                }
            case "custom_tool_call_output", "function_call_output":
                let callID = string(in: payload, keys: ["call_id", "callId"])
                if callID != nil, observation.blocker?.callID == callID {
                    observation.blocker = nil
                    changed = true
                }
            default:
                break
            }
        }

        if
            recordType == "response_item",
            payload["type"] as? String == "message",
            let role = payload["role"] as? String,
            let text = messageText(from: payload)
        {
            if role == "user", !isInjectedContext(text) {
                if observation.lastUserAt == nil || timestamp >= observation.lastUserAt! {
                    observation.lastUserExcerpt = text.trimmedExcerpt(limit: 2_048)
                    observation.lastUserAt = timestamp
                    changed = true
                }
            } else if role == "assistant" {
                changed = updateAssistant(text, at: timestamp, observation: &observation) || changed
            }
        }
        return changed
    }

    public static func looksRelevant(_ line: Data) -> Bool {
        let ignoredMarkers = [
            Data("\"type\":\"token_count\"".utf8),
            Data("\"type\":\"thread_settings_applied\"".utf8)
        ]
        if ignoredMarkers.contains(where: { line.range(of: $0) != nil }) {
            return false
        }
        let markers = [
            Data("\"type\":\"event_msg\"".utf8),
            Data("\"type\":\"custom_tool_call\"".utf8),
            Data("\"type\":\"custom_tool_call_output\"".utf8),
            Data("\"type\":\"function_call\"".utf8),
            Data("\"type\":\"function_call_output\"".utf8),
            Data("\"role\":\"user\"".utf8),
            Data("\"role\":\"assistant\"".utf8)
        ]
        return markers.contains { line.range(of: $0) != nil }
    }

    private static func isActivityRecord(recordType: String, payload: [String: Any]) -> Bool {
        if recordType == "response_item" { return true }
        guard recordType == "event_msg", let type = payload["type"] as? String else { return false }
        return type != "token_count" && type != "thread_settings_applied"
    }

    private static func requestsEscalatedPermission(_ input: String) -> Bool {
        let compact = input.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return compact.contains(#"sandbox_permissions:"require_escalated""#)
            || compact.contains(#""sandbox_permissions":"require_escalated""#)
    }

    private static func approvalSummary(from input: String) -> String? {
        guard
            let expression = try? NSRegularExpression(
                pattern: #"justification\s*:\s*("(?:\\.|[^"\\])*")"#
            ),
            let match = expression.firstMatch(
                in: input,
                range: NSRange(input.startIndex..., in: input)
            ),
            let quotedRange = Range(match.range(at: 1), in: input),
            let decoded = try? JSONDecoder().decode(String.self, from: Data(input[quotedRange].utf8))
        else {
            return nil
        }
        return decoded.trimmedExcerpt(limit: 180)
    }

    private static func userInputSummary(from arguments: String) -> String? {
        guard
            let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let questions = object["questions"] as? [[String: Any]],
            let question = questions.first?["question"] as? String
        else {
            return nil
        }
        return question.trimmedExcerpt(limit: 180)
    }

    private static func updateAssistant(
        _ text: String,
        at timestamp: Date,
        observation: inout RolloutObservation
    ) -> Bool {
        guard observation.lastAssistantAt == nil || timestamp >= observation.lastAssistantAt! else { return false }
        observation.lastAssistantExcerpt = text.trimmedExcerpt(limit: 2_048)
        observation.lastAssistantAt = timestamp
        return true
    }

    private static func duration(from start: Date?, to end: Date) -> TimeInterval? {
        guard let start else { return nil }
        return max(0, end.timeIntervalSince(start))
    }

    private static func messageText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let texts = content.compactMap { item -> String? in
            guard let type = item["type"] as? String, type == "input_text" || type == "output_text" else { return nil }
            return item["text"] as? String
        }
        let result = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func isInjectedContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let injectedPrefixes = [
            "# AGENTS.md instructions",
            "<environment_context>",
            "<permissions instructions>",
            "<skills_instructions>",
            "<recommended_plugins>"
        ]
        return injectedPrefixes.contains(where: trimmed.hasPrefix)
    }

    private static func string(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
