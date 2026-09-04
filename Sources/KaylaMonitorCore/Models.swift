import Foundation

public enum KaylaStatus: String, Codable, CaseIterable, Sendable {
    case processing
    case awaitingDecision
    case needsConfirmation
    case stageComplete

    public var label: String {
        switch self {
        case .processing: return "处理中"
        case .awaitingDecision: return "等你判断"
        case .needsConfirmation: return "状态待确认"
        case .stageComplete: return "今日阶段完成"
        }
    }
}

public enum AttentionState: String, Codable, Sendable {
    case currentFocus
    case parked

    public var label: String {
        switch self {
        case .currentFocus: return "当前焦点"
        case .parked: return "已停靠"
        }
    }
}

public enum BlockerKind: String, Codable, Sendable {
    case needsApproval
    case needsInput
    case interrupted
    case suspectedStall

    public var label: String {
        switch self {
        case .needsApproval: return "等你授权"
        case .needsInput: return "等你答复"
        case .interrupted: return "执行已中断"
        case .suspectedStall: return "疑似停滞"
        }
    }
}

public struct TaskBlocker: Codable, Equatable, Sendable {
    public var kind: BlockerKind
    public var summary: String
    public var detectedAt: Date
    public var callID: String?

    public init(kind: BlockerKind, summary: String, detectedAt: Date, callID: String? = nil) {
        self.kind = kind
        self.summary = summary.trimmedExcerpt(limit: 240)
        self.detectedAt = detectedAt
        self.callID = callID
    }
}

public struct RecoveryPoint: Codable, Equatable, Sendable {
    public var currentDiscussion: String
    public var nextAction: String
    public var updatedAt: Date

    public init(currentDiscussion: String, nextAction: String, updatedAt: Date = Date()) {
        self.currentDiscussion = currentDiscussion.trimmedExcerpt(limit: 600)
        self.nextAction = nextAction.trimmedExcerpt(limit: 600)
        self.updatedAt = updatedAt
    }
}

public struct TaskCard: Codable, Identifiable, Equatable, Sendable {
    public var id: String { threadID }
    public let threadID: String
    public var title: String
    public var projectPath: String?
    public var rolloutPath: String?
    public var kaylaStatus: KaylaStatus
    public var attentionState: AttentionState
    public var recoveryPoint: RecoveryPoint?
    public var lastUserExcerpt: String?
    public var lastAssistantExcerpt: String?
    public var latestTurnID: String?
    public var lastEventAt: Date?
    public var lastActivityAt: Date?
    public var blocker: TaskBlocker?
    public var currentTurnStartedAt: Date?
    public var lastTurnDuration: TimeInterval?

    public init(
        threadID: String,
        title: String,
        projectPath: String? = nil,
        rolloutPath: String? = nil,
        kaylaStatus: KaylaStatus = .needsConfirmation,
        attentionState: AttentionState = .parked
    ) {
        self.threadID = threadID
        self.title = title.trimmedExcerpt(limit: 120)
        self.projectPath = projectPath
        self.rolloutPath = rolloutPath
        self.kaylaStatus = kaylaStatus
        self.attentionState = attentionState
    }

    public var projectDisplayName: String? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    public var requiresUserAction: Bool {
        blocker != nil || kaylaStatus == .awaitingDecision || kaylaStatus == .needsConfirmation
    }

    public func currentTurnDuration(at now: Date = Date()) -> TimeInterval? {
        if kaylaStatus == .processing, let currentTurnStartedAt {
            return max(0, now.timeIntervalSince(currentTurnStartedAt))
        }
        return lastTurnDuration
    }

    public func currentTurnDurationLabel(at now: Date = Date()) -> String {
        guard let duration = currentTurnDuration(at: now) else { return "本轮 --:--" }
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "本轮 %d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "本轮 %02d:%02d", minutes, seconds)
    }
}

public struct OutsideActivity: Codable, Identifiable, Equatable, Sendable {
    public var id: String { threadID }
    public let threadID: String
    public var projectPath: String?
    public var lastEventAt: Date
    public var lastKnownStatus: KaylaStatus

    public init(
        threadID: String,
        projectPath: String?,
        lastEventAt: Date,
        lastKnownStatus: KaylaStatus
    ) {
        self.threadID = threadID
        self.projectPath = projectPath
        self.lastEventAt = lastEventAt
        self.lastKnownStatus = lastKnownStatus
    }

    public var displayName: String {
        if let projectPath, !projectPath.isEmpty {
            return URL(fileURLWithPath: projectPath).lastPathComponent
        }
        return "任务 \(threadID.shortThreadID)"
    }
}

public struct MonitorState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var selectedTasks: [TaskCard]
    public var outsideActivities: [OutsideActivity]
    public var processedEventIDs: [String]

    public init(
        schemaVersion: Int = 1,
        selectedTasks: [TaskCard] = [],
        outsideActivities: [OutsideActivity] = [],
        processedEventIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.selectedTasks = selectedTasks
        self.outsideActivities = outsideActivities
        self.processedEventIDs = processedEventIDs
        normalize()
    }

    public var awaitingDecisionCount: Int {
        selectedTasks.filter { $0.kaylaStatus == .awaitingDecision }.count
    }

    public var actionRequiredCount: Int {
        selectedTasks.filter(\.requiresUserAction).count
    }

    public var selectedThreadIDs: Set<String> {
        Set(selectedTasks.map(\.threadID))
    }

    public mutating func normalize() {
        var seen = Set<String>()
        selectedTasks = selectedTasks.filter { seen.insert($0.threadID).inserted }
        if selectedTasks.count > 3 {
            selectedTasks = Array(selectedTasks.prefix(3))
        }

        var foundFocus = false
        for index in selectedTasks.indices {
            if selectedTasks[index].attentionState == .currentFocus {
                if foundFocus {
                    selectedTasks[index].attentionState = .parked
                } else {
                    foundFocus = true
                }
            }
        }

        let activeThreadIDs = Set(selectedTasks.map(\.threadID))
        outsideActivities.removeAll { activeThreadIDs.contains($0.threadID) }
        var outsideSeen = Set<String>()
        outsideActivities = outsideActivities
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .filter { outsideSeen.insert($0.threadID).inserted }
        if outsideActivities.count > 20 {
            outsideActivities = Array(outsideActivities.prefix(20))
        }
        if processedEventIDs.count > 500 {
            processedEventIDs = Array(processedEventIDs.suffix(500))
        }
    }

    @discardableResult
    public mutating func addTask(
        threadID: String,
        title: String,
        projectPath: String?,
        rolloutPath: String? = nil
    ) -> Bool {
        guard !selectedThreadIDs.contains(threadID), selectedTasks.count < 3 else { return false }
        let attention: AttentionState = selectedTasks.contains(where: { $0.attentionState == .currentFocus }) ? .parked : .currentFocus
        selectedTasks.append(
            TaskCard(
                threadID: threadID,
                title: title,
                projectPath: projectPath,
                rolloutPath: rolloutPath,
                attentionState: attention
            )
        )
        outsideActivities.removeAll { $0.threadID == threadID }
        normalize()
        return true
    }

    public mutating func removeTask(threadID: String) {
        let removedWasFocus = selectedTasks.first(where: { $0.threadID == threadID })?.attentionState == .currentFocus
        selectedTasks.removeAll { $0.threadID == threadID }
        if removedWasFocus {
            focusFirstAvailableTask()
        }
        normalize()
    }

    public mutating func setFocus(threadID: String) {
        guard let targetIndex = selectedTasks.firstIndex(where: { $0.threadID == threadID }) else { return }
        for index in selectedTasks.indices {
            selectedTasks[index].attentionState = index == targetIndex ? .currentFocus : .parked
        }
        if selectedTasks[targetIndex].kaylaStatus == .stageComplete {
            selectedTasks[targetIndex].kaylaStatus = .needsConfirmation
        }
        selectedTasks[targetIndex].recoveryPoint = nil
    }

    public mutating func saveRecoveryPoint(threadID: String, point: RecoveryPoint) {
        guard let index = selectedTasks.firstIndex(where: { $0.threadID == threadID }) else { return }
        selectedTasks[index].recoveryPoint = point
        selectedTasks[index].attentionState = .parked
    }

    public mutating func markStageComplete(threadID: String) {
        guard let index = selectedTasks.firstIndex(where: { $0.threadID == threadID }) else { return }
        let wasFocus = selectedTasks[index].attentionState == .currentFocus
        selectedTasks[index].kaylaStatus = .stageComplete
        selectedTasks[index].attentionState = .parked
        selectedTasks[index].recoveryPoint = nil
        selectedTasks[index].blocker = nil
        selectedTasks[index].lastEventAt = Date()
        if wasFocus {
            focusFirstAvailableTask(excluding: threadID)
        }
    }

    public mutating func replaceTask(threadID: String, with activity: OutsideActivity) {
        guard let index = selectedTasks.firstIndex(where: { $0.threadID == threadID }) else { return }
        let attention = selectedTasks[index].attentionState
        selectedTasks[index] = TaskCard(
            threadID: activity.threadID,
            title: activity.displayName,
            projectPath: activity.projectPath,
            kaylaStatus: activity.lastKnownStatus,
            attentionState: attention
        )
        outsideActivities.removeAll { $0.threadID == activity.threadID }
        normalize()
    }

    public mutating func ignoreOutsideActivity(threadID: String) {
        outsideActivities.removeAll { $0.threadID == threadID }
    }

    public mutating func markPreviousProcessingAsUncertain() {
        for index in selectedTasks.indices where selectedTasks[index].kaylaStatus == .processing {
            selectedTasks[index].kaylaStatus = .needsConfirmation
        }
    }

    public mutating func markPotentialStalls(
        now: Date = Date(),
        inactivityThreshold: TimeInterval = 15 * 60
    ) -> [String] {
        var newlyStalled: [String] = []
        for index in selectedTasks.indices {
            guard
                selectedTasks[index].kaylaStatus == .processing,
                selectedTasks[index].blocker == nil,
                let lastActivity = selectedTasks[index].lastActivityAt ?? selectedTasks[index].lastEventAt,
                now.timeIntervalSince(lastActivity) >= inactivityThreshold
            else {
                continue
            }
            selectedTasks[index].blocker = TaskBlocker(
                kind: .suspectedStall,
                summary: "超过 15 分钟没有新活动，请打开任务确认是否仍在执行",
                detectedAt: now
            )
            newlyStalled.append(selectedTasks[index].threadID)
        }
        return newlyStalled
    }

    @discardableResult
    public mutating func applyRolloutObservation(
        threadID: String,
        rolloutPath: String,
        observation: RolloutObservation
    ) -> Bool {
        guard let index = selectedTasks.firstIndex(where: { $0.threadID == threadID }) else { return false }
        let previouslyRequiredAction = selectedTasks[index].requiresUserAction
        // Hook receipt time can be later than task_started. Fresh activity from the
        // same turn still confirms it is processing after a monitor restart.
        let resumesCurrentTurn = selectedTasks[index].kaylaStatus == .needsConfirmation
            && observation.status == .processing
            && observation.latestTurnID != nil
            && observation.latestTurnID == selectedTasks[index].latestTurnID
            && selectedTasks[index].blocker?.kind != .interrupted
            && (observation.lastActivityAt ?? .distantPast) > (selectedTasks[index].lastEventAt ?? .distantPast)
        selectedTasks[index].rolloutPath = rolloutPath

        if let userExcerpt = observation.lastUserExcerpt, !userExcerpt.isEmpty {
            selectedTasks[index].lastUserExcerpt = userExcerpt
        }
        if let assistantExcerpt = observation.lastAssistantExcerpt, !assistantExcerpt.isEmpty {
            selectedTasks[index].lastAssistantExcerpt = assistantExcerpt
        }

        if let lastActivityAt = observation.lastActivityAt {
            selectedTasks[index].lastActivityAt = max(selectedTasks[index].lastActivityAt ?? lastActivityAt, lastActivityAt)
        }
        selectedTasks[index].currentTurnStartedAt = observation.currentTurnStartedAt
        selectedTasks[index].lastTurnDuration = observation.lastTurnDuration
        selectedTasks[index].blocker = observation.blocker

        if
            let observedStatus = observation.status,
            let statusAt = observation.statusAt,
            selectedTasks[index].lastEventAt == nil || statusAt >= selectedTasks[index].lastEventAt! || resumesCurrentTurn
        {
            selectedTasks[index].kaylaStatus = observedStatus
            selectedTasks[index].latestTurnID = observation.latestTurnID
            selectedTasks[index].lastEventAt = max(selectedTasks[index].lastEventAt ?? statusAt, statusAt)
            if observedStatus == .processing {
                selectedTasks[index].recoveryPoint = nil
            }
        }
        return !previouslyRequiredAction && selectedTasks[index].requiresUserAction
    }

    private mutating func focusFirstAvailableTask(excluding excludedThreadID: String? = nil) {
        guard !selectedTasks.contains(where: { $0.attentionState == .currentFocus }) else { return }
        if let index = selectedTasks.firstIndex(where: {
            $0.threadID != excludedThreadID && $0.kaylaStatus != .stageComplete
        }) {
            selectedTasks[index].attentionState = .currentFocus
        }
    }
}

public extension String {
    var shortThreadID: String {
        String(prefix(8))
    }

    func trimmedExcerpt(limit: Int) -> String {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)) + "…"
    }

    func flattenedExcerpt(limit: Int) -> String {
        let flattened = split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        return flattened.trimmedExcerpt(limit: limit)
    }
}
