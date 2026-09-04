import AppKit
import Combine
import Foundation
import KaylaMonitorCore

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var state: MonitorState
    @Published private(set) var recentThreads: [RecentThread] = []
    @Published private(set) var isLoadingRecentThreads = false
    @Published private(set) var lastError: String?

    var onAwaitingDecision: ((String) -> Void)?

    let paths: MonitorPaths
    private let repository: StateRepository
    private var eventLog: EventLog
    private let recentThreadReader = RecentThreadReader()
    private let rolloutObserver = RolloutObserver()
    private var timer: Timer?

    init(paths: MonitorPaths = MonitorPaths()) {
        self.paths = paths
        self.repository = StateRepository(paths: paths)
        self.eventLog = EventLog(paths: paths)
        var loaded = repository.load()
        loaded.markPreviousProcessingAsUncertain()
        self.state = loaded
        persist()
    }

    func start() {
        processAllInputs()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processAllInputs()
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        persist()
    }

    func processPendingEvents() {
        var updated = state
        var changed = false
        var awaitingThreadIDs: [String] = []

        for event in eventLog.readNew() {
            let result = EventReducer.apply(event, to: &updated)
            changed = changed || result.changed
            if let threadID = result.newlyAwaitingThreadID {
                awaitingThreadIDs.append(threadID)
            }
        }

        guard changed else { return }
        state = updated
        persist()
        awaitingThreadIDs.forEach { onAwaitingDecision?($0) }
    }

    func processRolloutChanges() {
        let results = rolloutObserver.poll(tasks: state.selectedTasks)
        guard !results.isEmpty else { return }

        var updated = state
        var changed = false
        var awaitingThreadIDs: [String] = []
        for result in results {
            let before = updated.selectedTasks
            let newlyAwaiting = updated.applyRolloutObservation(
                threadID: result.threadID,
                rolloutPath: result.rolloutPath,
                observation: result.observation
            )
            changed = changed || before != updated.selectedTasks
            if newlyAwaiting, !result.isInitialRead {
                awaitingThreadIDs.append(result.threadID)
            }
        }

        guard changed else { return }
        state = updated
        persist()
        awaitingThreadIDs.forEach { onAwaitingDecision?($0) }
    }

    func refreshRecentThreads() {
        guard !isLoadingRecentThreads else { return }
        isLoadingRecentThreads = true
        lastError = nil
        Task {
            do {
                let threads = try await recentThreadReader.listThreads()
                recentThreads = threads
                isLoadingRecentThreads = false
                refreshSelectedTitles(from: threads)
            } catch {
                isLoadingRecentThreads = false
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func addTask(_ thread: RecentThread) -> Bool {
        mutateReturningBool { state in
            state.addTask(
                threadID: thread.id,
                title: thread.title,
                projectPath: thread.projectPath,
                rolloutPath: thread.rolloutPath
            )
        }
    }

    @discardableResult
    func addTask(from input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let threadID: String
        if let url = URL(string: trimmed), url.scheme == "codex", let last = url.pathComponents.last, !last.isEmpty {
            threadID = last
        } else {
            threadID = trimmed
        }
        return mutateReturningBool { state in
            state.addTask(
                threadID: threadID,
                title: "任务 \(threadID.shortThreadID)",
                projectPath: nil
            )
        }
    }

    func removeTask(threadID: String) {
        mutateState { $0.removeTask(threadID: threadID) }
    }

    func setFocus(threadID: String) {
        mutateState { $0.setFocus(threadID: threadID) }
    }

    func saveRecoveryPoint(threadID: String, currentDiscussion: String, nextAction: String) {
        mutateState {
            $0.saveRecoveryPoint(
                threadID: threadID,
                point: RecoveryPoint(currentDiscussion: currentDiscussion, nextAction: nextAction)
            )
        }
    }

    func markStageComplete(threadID: String) {
        mutateState { $0.markStageComplete(threadID: threadID) }
    }

    func ignoreOutsideActivity(threadID: String) {
        mutateState { $0.ignoreOutsideActivity(threadID: threadID) }
    }

    func replaceTask(threadID: String, with activity: OutsideActivity) {
        mutateState { $0.replaceTask(threadID: threadID, with: activity) }
    }

    func draftRecoveryPoint(threadID: String) -> RecoveryPoint? {
        processRolloutChanges()
        guard let task = state.selectedTasks.first(where: { $0.threadID == threadID }) else { return nil }
        return task.recoveryPoint ?? RecoveryPointDraft.make(for: task)
    }

    func openThread(threadID: String, focus: Bool = true) {
        if focus {
            setFocus(threadID: threadID)
        }
        guard let url = URL(string: "codex://threads/\(threadID)") else { return }
        NSWorkspace.shared.open(url)
    }

    func openDataDirectory() {
        try? paths.ensureDirectory()
        NSWorkspace.shared.open(paths.rootDirectory)
    }

    private func refreshSelectedTitles(from threads: [RecentThread]) {
        let byID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        mutateState { state in
            for index in state.selectedTasks.indices {
                guard let thread = byID[state.selectedTasks[index].threadID] else { continue }
                state.selectedTasks[index].title = thread.title
                state.selectedTasks[index].projectPath = thread.projectPath
                state.selectedTasks[index].rolloutPath = thread.rolloutPath
            }
        }
    }

    @discardableResult
    private func mutateReturningBool(_ body: (inout MonitorState) -> Bool) -> Bool {
        var updated = state
        let result = body(&updated)
        updated.normalize()
        state = updated
        persist()
        return result
    }

    private func mutateState(_ body: (inout MonitorState) -> Void) {
        var updated = state
        body(&updated)
        updated.normalize()
        state = updated
        persist()
    }

    private func persist() {
        do {
            try repository.save(state)
            lastError = nil
        } catch {
            lastError = "本地状态保存失败：\(error.localizedDescription)"
        }
    }

    private func processAllInputs() {
        processPendingEvents()
        processRolloutChanges()
        processPotentialStalls()
    }

    private func processPotentialStalls() {
        var updated = state
        let newlyStalled = updated.markPotentialStalls()
        guard !newlyStalled.isEmpty else { return }
        state = updated
        persist()
        newlyStalled.forEach { onAwaitingDecision?($0) }
    }
}
