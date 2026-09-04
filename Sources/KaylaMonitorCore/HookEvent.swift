import Foundation

public enum HookEventKind: String, Codable, Sendable {
    case userPromptSubmit
    case stop
}

public struct HookEvent: Codable, Equatable, Sendable {
    public let id: String
    public let kind: HookEventKind
    public let timestamp: Date
    public let threadID: String
    public let turnID: String?
    public let projectPath: String?
    public let userExcerpt: String?
    public let assistantExcerpt: String?

    public init(
        id: String = UUID().uuidString,
        kind: HookEventKind,
        timestamp: Date = Date(),
        threadID: String,
        turnID: String? = nil,
        projectPath: String? = nil,
        userExcerpt: String? = nil,
        assistantExcerpt: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.threadID = threadID
        self.turnID = turnID
        self.projectPath = projectPath
        self.userExcerpt = userExcerpt?.trimmedExcerpt(limit: 2_048)
        self.assistantExcerpt = assistantExcerpt?.trimmedExcerpt(limit: 2_048)
    }
}

public enum HookPayloadParser {
    public static func parse(_ data: Data, selectedThreadIDs: Set<String>, now: Date = Date()) -> HookEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any],
            let threadID = string(in: payload, keys: ["session_id", "sessionId", "thread_id", "threadId"]),
            !threadID.isEmpty,
            let kind = eventKind(in: payload)
        else {
            return nil
        }

        let keepText = selectedThreadIDs.contains(threadID)
        return HookEvent(
            id: string(in: payload, keys: ["event_id", "eventId"]) ?? UUID().uuidString,
            kind: kind,
            timestamp: timestamp(in: payload, fallback: now),
            threadID: threadID,
            turnID: string(in: payload, keys: ["turn_id", "turnId"]),
            projectPath: string(in: payload, keys: ["cwd", "project_path", "projectPath"]),
            userExcerpt: keepText ? string(in: payload, keys: ["prompt", "user_prompt", "userPrompt"]) : nil,
            assistantExcerpt: keepText ? string(in: payload, keys: ["last_assistant_message", "lastAssistantMessage", "assistant_message"]) : nil
        )
    }

    private static func eventKind(in payload: [String: Any]) -> HookEventKind? {
        let rawName = string(
            in: payload,
            keys: ["hook_event_name", "hookEventName", "event_name", "eventName", "type"]
        )?.lowercased().replacingOccurrences(of: "_", with: "")

        if rawName?.contains("userpromptsubmit") == true { return .userPromptSubmit }
        if rawName == "stop" || rawName?.hasSuffix("stop") == true { return .stop }
        if payload["prompt"] != nil { return .userPromptSubmit }
        if payload["last_assistant_message"] != nil || payload["lastAssistantMessage"] != nil { return .stop }
        return nil
    }

    private static func string(in payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func timestamp(in payload: [String: Any], fallback: Date) -> Date {
        for key in ["timestamp", "created_at", "createdAt"] {
            if let value = payload[key] as? NSNumber {
                let raw = value.doubleValue
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            }
            if let value = payload[key] as? String {
                if let numeric = Double(value) {
                    return Date(timeIntervalSince1970: numeric > 10_000_000_000 ? numeric / 1_000 : numeric)
                }
                if let date = ISO8601DateFormatter().date(from: value) {
                    return date
                }
            }
        }
        return fallback
    }
}

public struct ReductionResult: Equatable, Sendable {
    public var changed: Bool
    public var newlyAwaitingThreadID: String?

    public init(changed: Bool, newlyAwaitingThreadID: String? = nil) {
        self.changed = changed
        self.newlyAwaitingThreadID = newlyAwaitingThreadID
    }
}

public enum EventReducer {
    public static func apply(_ event: HookEvent, to state: inout MonitorState) -> ReductionResult {
        guard !state.processedEventIDs.contains(event.id) else {
            return ReductionResult(changed: false)
        }
        state.processedEventIDs.append(event.id)

        guard let index = state.selectedTasks.firstIndex(where: { $0.threadID == event.threadID }) else {
            let status: KaylaStatus = event.kind == .userPromptSubmit ? .processing : .awaitingDecision
            let activity = OutsideActivity(
                threadID: event.threadID,
                projectPath: event.projectPath,
                lastEventAt: event.timestamp,
                lastKnownStatus: status
            )
            if let outsideIndex = state.outsideActivities.firstIndex(where: { $0.threadID == event.threadID }) {
                if event.timestamp >= state.outsideActivities[outsideIndex].lastEventAt {
                    state.outsideActivities[outsideIndex] = activity
                }
            } else {
                state.outsideActivities.append(activity)
            }
            state.normalize()
            return ReductionResult(changed: true)
        }

        // A replayed prompt can outlive the bounded ID cache. Do not restart the same turn.
        if let lastEventAt = state.selectedTasks[index].lastEventAt,
           event.timestamp < lastEventAt || (event.timestamp == lastEventAt && event.kind == .userPromptSubmit) {
            state.normalize()
            return ReductionResult(changed: true)
        }

        switch event.kind {
        case .userPromptSubmit:
            state.selectedTasks[index].kaylaStatus = .processing
            state.selectedTasks[index].blocker = nil
            state.selectedTasks[index].latestTurnID = event.turnID
            state.selectedTasks[index].lastEventAt = event.timestamp
            state.selectedTasks[index].lastActivityAt = max(state.selectedTasks[index].lastActivityAt ?? event.timestamp, event.timestamp)
            state.selectedTasks[index].currentTurnStartedAt = event.timestamp
            state.selectedTasks[index].lastTurnDuration = nil
            if let excerpt = event.userExcerpt, !excerpt.isEmpty {
                state.selectedTasks[index].lastUserExcerpt = excerpt
            }
            state.normalize()
            return ReductionResult(changed: true)

        case .stop:
            if
                let currentTurn = state.selectedTasks[index].latestTurnID,
                let eventTurn = event.turnID,
                currentTurn != eventTurn
            {
                state.normalize()
                return ReductionResult(changed: true)
            }

            let wasAwaiting = state.selectedTasks[index].kaylaStatus == .awaitingDecision
            state.selectedTasks[index].kaylaStatus = .awaitingDecision
            state.selectedTasks[index].blocker = nil
            state.selectedTasks[index].latestTurnID = event.turnID ?? state.selectedTasks[index].latestTurnID
            state.selectedTasks[index].lastEventAt = event.timestamp
            state.selectedTasks[index].lastActivityAt = max(state.selectedTasks[index].lastActivityAt ?? event.timestamp, event.timestamp)
            if let startedAt = state.selectedTasks[index].currentTurnStartedAt {
                state.selectedTasks[index].lastTurnDuration = max(0, event.timestamp.timeIntervalSince(startedAt))
            }
            if let excerpt = event.assistantExcerpt, !excerpt.isEmpty {
                state.selectedTasks[index].lastAssistantExcerpt = excerpt
            }
            state.normalize()
            return ReductionResult(
                changed: true,
                newlyAwaitingThreadID: wasAwaiting ? nil : event.threadID
            )
        }
    }
}

public enum RecoveryPointDraft {
    public static func make(for task: TaskCard, now: Date = Date()) -> RecoveryPoint {
        let current = task.lastUserExcerpt?.conversationSummary(limit: 240, preferActionSentence: false)
        let assistantSummary = task.lastAssistantExcerpt?.conversationSummary(limit: 240, preferActionSentence: true)

        return RecoveryPoint(
            currentDiscussion: current?.isEmpty == false ? current! : "尚未读取到最近一次用户消息",
            nextAction: assistantSummary?.isEmpty == false ? assistantSummary! : "尚未读取到最近一次 Kayla 回复",
            updatedAt: now
        )
    }
}

public extension String {
    func conversationSummary(limit: Int, preferActionSentence: Bool) -> String {
        let paragraphs = components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^[-*•]\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "`", with: "")
            }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else { return "" }
        let candidates = paragraphs.flatMap { paragraph in
            paragraph.components(separatedBy: CharacterSet(charactersIn: "。！？!?"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let chosen: String
        if preferActionSentence {
            let actionWords = ["下一步", "接下来", "回来后", "建议", "需要", "先", "继续", "待"]
            chosen = candidates.last(where: { sentence in
                actionWords.contains(where: sentence.contains)
            }) ?? candidates.last ?? paragraphs.last!
        } else {
            chosen = candidates.first ?? paragraphs.first!
        }
        return chosen.flattenedExcerpt(limit: limit)
    }
}
