import Foundation
import KaylaMonitorCore

enum SelfCheckError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum CoreSelfChecks {
    static func run() throws -> Int {
        var count = 0
        try checkPromptAndStop(); count += 1
        try checkDuplicateAndStaleEvents(); count += 1
        try checkOutsideActivity(); count += 1
        try checkSingleFocus(); count += 1
        try checkRestartUncertainty(); count += 1
        try checkPrivacyBoundary(); count += 1
        try checkRecoveryDraft(); count += 1
        try checkPersistence(); count += 1
        try checkRolloutLifecycleAndConversation(); count += 1
        try checkRolloutObservationUpdatesTask(); count += 1
        try checkPreferredDisplaySelection(); count += 1
        try checkBuiltInDisplayFallback(); count += 1
        try checkApprovalBlockerLifecycle(); count += 1
        try checkUserInputBlocker(); count += 1
        try checkInterruptedTurn(); count += 1
        try checkPotentialStall(); count += 1
        try checkCurrentTurnTiming(); count += 1
        try checkEvictedPromptDoesNotResetTask(); count += 1
        try checkIncrementalEventLog(); count += 1
        try checkEventLogPartialAndReplacement(); count += 1
        try checkActivityNeverRegresses(); count += 1
        try checkRestartWithDelayedHookTimestamp(); count += 1
        try checkStallThresholdUnchanged(); count += 1
        return count
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SelfCheckError.failed(message) }
    }

    private static func checkPromptAndStop() throws {
        var state = MonitorState()
        try require(state.addTask(threadID: "thread-1", title: "探索线程", projectPath: "/tmp/project"), "无法添加任务")
        let prompt = HookEvent(
            id: "event-1",
            kind: .userPromptSubmit,
            timestamp: Date(timeIntervalSince1970: 100),
            threadID: "thread-1",
            turnID: "turn-1",
            userExcerpt: "先讨论一下方案"
        )
        _ = EventReducer.apply(prompt, to: &state)
        try require(state.selectedTasks[0].kaylaStatus == .processing, "提交事件未进入处理中")
        try require(state.selectedTasks[0].currentTurnDurationLabel(at: Date(timeIntervalSince1970: 105)) == "本轮 00:05", "处理中计时未实时增长")

        let stop = HookEvent(
            id: "event-2",
            kind: .stop,
            timestamp: Date(timeIntervalSince1970: 110),
            threadID: "thread-1",
            turnID: "turn-1",
            assistantExcerpt: "下一步先做样机"
        )
        let result = EventReducer.apply(stop, to: &state)
        try require(state.selectedTasks[0].kaylaStatus == .awaitingDecision, "Stop 未进入等你判断")
        try require(result.newlyAwaitingThreadID == "thread-1", "Stop 未触发轻量提醒")
        try require(state.selectedTasks[0].lastTurnDuration == 10, "Stop 未冻结本轮耗时")
    }

    private static func checkDuplicateAndStaleEvents() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        let current = HookEvent(
            id: "current",
            kind: .userPromptSubmit,
            timestamp: Date(timeIntervalSince1970: 200),
            threadID: "thread",
            turnID: "turn-2"
        )
        _ = EventReducer.apply(current, to: &state)
        try require(!EventReducer.apply(current, to: &state).changed, "重复事件未去重")
        _ = EventReducer.apply(
            HookEvent(
                id: "stale",
                kind: .stop,
                timestamp: Date(timeIntervalSince1970: 190),
                threadID: "thread",
                turnID: "turn-1"
            ),
            to: &state
        )
        try require(state.selectedTasks[0].kaylaStatus == .processing, "旧 Stop 覆盖了新状态")
        _ = EventReducer.apply(
            HookEvent(
                id: "wrong-turn",
                kind: .stop,
                timestamp: Date(timeIntervalSince1970: 210),
                threadID: "thread",
                turnID: "turn-1"
            ),
            to: &state
        )
        try require(state.selectedTasks[0].kaylaStatus == .processing, "错误 turn 覆盖了当前状态")
    }

    private static func checkOutsideActivity() throws {
        var state = MonitorState()
        for index in 1...3 {
            try require(state.addTask(threadID: "thread-\(index)", title: "任务", projectPath: nil), "三任务上限提前触发")
        }
        try require(!state.addTask(threadID: "thread-4", title: "第四个", projectPath: nil), "允许了第四张卡片")
        _ = EventReducer.apply(HookEvent(kind: .userPromptSubmit, threadID: "thread-4"), to: &state)
        try require(state.selectedTasks.count == 3, "范围外活动占用了卡片")
        try require(state.outsideActivities.first?.threadID == "thread-4", "范围外活动未记录")
    }

    private static func checkSingleFocus() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "one", title: "一", projectPath: nil)
        _ = state.addTask(threadID: "two", title: "二", projectPath: nil)
        _ = state.addTask(threadID: "three", title: "三", projectPath: nil)
        state.setFocus(threadID: "three")
        let focused = state.selectedTasks.filter { $0.attentionState == .currentFocus }
        try require(focused.count == 1 && focused[0].threadID == "three", "当前焦点不唯一")
    }

    private static func checkRestartUncertainty() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        state.selectedTasks[0].kaylaStatus = .processing
        state.markPreviousProcessingAsUncertain()
        try require(state.selectedTasks[0].kaylaStatus == .needsConfirmation, "重启后仍宣称处理中")
    }

    private static func checkPrivacyBoundary() throws {
        let payload: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "selected",
            "prompt": String(repeating: "内容", count: 2_000),
            "cwd": "/tmp/project"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let selected = HookPayloadParser.parse(data, selectedThreadIDs: ["selected"])
        let unselected = HookPayloadParser.parse(data, selectedThreadIDs: [])
        try require(selected?.userExcerpt != nil, "已选任务没有保存有限摘录")
        try require((selected?.userExcerpt?.count ?? 0) <= 2_048, "摘录超过 2,048 字符")
        try require(unselected?.userExcerpt == nil, "未选任务保存了正文")
    }

    private static func checkRecoveryDraft() throws {
        var task = TaskCard(threadID: "thread", title: "任务")
        task.lastUserExcerpt = "正在讨论悬浮窗。"
        task.lastAssistantExcerpt = "第一段。\n\n回来后先验证事件桥。"
        let draft = RecoveryPointDraft.make(for: task)
        try require(draft.currentDiscussion == "正在讨论悬浮窗", "恢复点讨论位置错误")
        try require(draft.nextAction == "回来后先验证事件桥", "恢复点下一步错误")
    }

    private static func checkPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MonitorPaths(rootDirectory: root)
        let repository = StateRepository(paths: paths)
        let log = EventLog(paths: paths)
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        try repository.save(state)
        try log.append(HookEvent(id: "event", kind: .stop, threadID: "thread"))
        try require(repository.load().selectedTasks.first?.threadID == "thread", "状态未持久化")
        try require(log.readAll().first?.id == "event", "事件日志未持久化")
    }

    private static func checkRolloutLifecycleAndConversation() throws {
        let records = [
            #"{"timestamp":"2026-08-13T01:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>忽略"}]}}"#,
            #"{"timestamp":"2026-08-13T01:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-08-13T01:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"检查真实状态为什么不变化，并修复自动总结。"}]}}"#,
            #"{"timestamp":"2026-08-13T01:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"我先检查事件链。","phase":"commentary"}}"#,
            #"{"timestamp":"2026-08-13T01:00:04.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#
        ]
        var observation = RolloutObservation()
        for record in records {
            _ = RolloutRecordParser.apply(line: Data(record.utf8), to: &observation)
        }
        try require(observation.status == .awaitingDecision, "真实会话完成状态未识别")
        try require(observation.latestTurnID == "turn-1", "真实会话 turn 未识别")
        try require(observation.lastUserExcerpt == "检查真实状态为什么不变化，并修复自动总结。", "真实用户消息未提取或错误纳入系统上下文")
        try require(observation.lastAssistantExcerpt == "我先检查事件链。", "真实 Kayla 回复未提取")
        try require(observation.lastTurnDuration == 3, "真实会话起止时间未计算本轮耗时")
    }

    private static func checkRolloutObservationUpdatesTask() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        state.selectedTasks[0].recoveryPoint = RecoveryPoint(currentDiscussion: "旧", nextAction: "旧")
        var observation = RolloutObservation()
        observation.status = .processing
        observation.statusAt = Date(timeIntervalSince1970: 200)
        observation.latestTurnID = "turn"
        observation.lastUserExcerpt = "新的讨论"
        observation.lastAssistantExcerpt = "下一步验证"
        _ = state.applyRolloutObservation(
            threadID: "thread",
            rolloutPath: "/tmp/thread.jsonl",
            observation: observation
        )
        try require(state.selectedTasks[0].kaylaStatus == .processing, "会话观察未更新处理中状态")
        try require(state.selectedTasks[0].recoveryPoint == nil, "新一轮开始后旧恢复点未清除")
        let draft = RecoveryPointDraft.make(for: state.selectedTasks[0])
        try require(draft.currentDiscussion == "新的讨论", "恢复点未使用真实用户消息")
        try require(draft.nextAction == "下一步验证", "恢复点未使用真实 Kayla 回复")
    }

    private static func checkPreferredDisplaySelection() throws {
        let displays = [
            DisplayCandidate(name: "内建视网膜显示器", isBuiltIn: true),
            DisplayCandidate(name: "T270CF", isBuiltIn: false)
        ]
        let index = DisplaySelection.preferredIndex(in: displays, preferredName: "T270CF")
        try require(index == 1, "连接 T270CF 时没有优先选择外接显示器")
    }

    private static func checkBuiltInDisplayFallback() throws {
        let displays = [
            DisplayCandidate(name: "其他外接显示器", isBuiltIn: false),
            DisplayCandidate(name: "内建视网膜显示器", isBuiltIn: true)
        ]
        let index = DisplaySelection.preferredIndex(in: displays, preferredName: "T270CF")
        try require(index == 1, "T270CF 缺席时没有回退到内建显示器")
    }

    private static func checkApprovalBlockerLifecycle() throws {
        let call = #"{"timestamp":"2026-08-14T01:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"approval-1","input":"tools.exec_command({ sandbox_permissions: \"require_escalated\", justification: \"允许安装更新吗？\" })"}}"#
        let output = #"{"timestamp":"2026-08-14T01:00:01Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"approval-1","output":"ok"}}"#
        var observation = RolloutObservation()
        _ = RolloutRecordParser.apply(line: Data(call.utf8), to: &observation)
        try require(observation.blocker?.kind == .needsApproval, "授权请求未识别为阻塞")
        try require(observation.blocker?.summary == "允许安装更新吗？", "授权原因未提取")
        _ = RolloutRecordParser.apply(line: Data(output.utf8), to: &observation)
        try require(observation.blocker == nil, "授权请求完成后阻塞未清除")
    }

    private static func checkUserInputBlocker() throws {
        let call = #"{"timestamp":"2026-08-14T01:00:00Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"question-1","arguments":"{\"questions\":[{\"question\":\"请选择下一步方案\"}]}"}}"#
        var observation = RolloutObservation()
        _ = RolloutRecordParser.apply(line: Data(call.utf8), to: &observation)
        try require(observation.blocker?.kind == .needsInput, "用户问题未识别为阻塞")
        try require(observation.blocker?.summary == "请选择下一步方案", "用户问题文本未提取")
    }

    private static func checkInterruptedTurn() throws {
        let line = #"{"timestamp":"2026-08-14T01:00:00Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}"#
        var observation = RolloutObservation()
        _ = RolloutRecordParser.apply(line: Data(line.utf8), to: &observation)
        try require(observation.status == .needsConfirmation, "中断事件未进入状态待确认")
        try require(observation.blocker?.kind == .interrupted, "中断事件未显示阻塞原因")
    }

    private static func checkPotentialStall() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        state.selectedTasks[0].kaylaStatus = .processing
        state.selectedTasks[0].lastActivityAt = Date(timeIntervalSince1970: 100)
        let stalled = state.markPotentialStalls(
            now: Date(timeIntervalSince1970: 1_001),
            inactivityThreshold: 900
        )
        try require(stalled == ["thread"], "长时间无活动未标记疑似停滞")
        try require(state.selectedTasks[0].blocker?.kind == .suspectedStall, "疑似停滞原因缺失")
    }

    private static func checkCurrentTurnTiming() throws {
        var task = TaskCard(threadID: "thread", title: "任务", kaylaStatus: .processing)
        task.currentTurnStartedAt = Date(timeIntervalSince1970: 100)
        try require(
            task.currentTurnDurationLabel(at: Date(timeIntervalSince1970: 3_825)) == "本轮 1:02:05",
            "超过一小时的实时耗时格式错误"
        )
        task.kaylaStatus = .awaitingDecision
        task.lastTurnDuration = 125
        try require(
            task.currentTurnDurationLabel(at: Date(timeIntervalSince1970: 9_999)) == "本轮 02:05",
            "完成后的耗时没有冻结"
        )
    }

    private static func checkEvictedPromptDoesNotResetTask() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        let prompt = HookEvent(id: "prompt", kind: .userPromptSubmit, timestamp: Date(timeIntervalSince1970: 100), threadID: "thread", turnID: "turn")
        _ = EventReducer.apply(prompt, to: &state)
        state.selectedTasks[0].lastActivityAt = Date(timeIntervalSince1970: 1_000)
        state.selectedTasks[0].currentTurnStartedAt = Date(timeIntervalSince1970: 99)
        state.selectedTasks[0].blocker = TaskBlocker(kind: .needsApproval, summary: "待授权", detectedAt: Date(timeIntervalSince1970: 1_000))
        for index in 0..<501 {
            _ = EventReducer.apply(HookEvent(id: "outside-\(index)", kind: .userPromptSubmit, threadID: "outside"), to: &state)
        }
        try require(!state.processedEventIDs.contains(prompt.id), "测试没有触发去重窗口淘汰")
        let before = state.selectedTasks
        _ = EventReducer.apply(prompt, to: &state)
        try require(state.selectedTasks == before, "被淘汰的旧提交事件重置了活动时间、计时或阻塞")
    }

    private static func checkIncrementalEventLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MonitorPaths(rootDirectory: root)
        try paths.ensureDirectory()
        let events = (0..<1_201).map { index in
            HookEvent(id: "event-\(index)", kind: .userPromptSubmit, timestamp: Date(timeIntervalSince1970: Double(index)), threadID: index == 1_200 ? "thread" : "outside")
        }
        var data = Data()
        for event in events {
            data.append(try MonitorJSON.encoder().encode(event))
            data.append(0x0A)
        }
        try data.write(to: paths.eventLogFile)
        var log = EventLog(paths: paths)
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        let initial = log.readNew()
        try require(initial.count == events.count, "首次读取遗漏历史或离线事件")
        for event in initial { _ = EventReducer.apply(event, to: &state) }
        state.selectedTasks[0].lastActivityAt = Date(timeIntervalSince1970: 2_000)
        for _ in 0..<3 {
            try require(log.readNew().isEmpty, "超过 500 条后仍在重复读取旧事件")
        }
        try require(state.markPotentialStalls(now: Date(timeIntervalSince1970: 2_100)).isEmpty, "正常活动任务被重复事件误报停滞")
        try log.append(HookEvent(id: "new-stop", kind: .stop, timestamp: Date(timeIntervalSince1970: 2_200), threadID: "thread"))
        let appended = log.readNew()
        try require(appended.map(\.id) == ["new-stop"], "追加事件没有且仅有一次被读取")
        for event in appended { _ = EventReducer.apply(event, to: &state) }
        try require(state.selectedTasks[0].kaylaStatus == .awaitingDecision, "新增 Stop 未应用")

        // A new reader scans history once to recover events received while the app was closed.
        try log.append(HookEvent(id: "offline-prompt", kind: .userPromptSubmit, timestamp: Date(timeIntervalSince1970: 2_300), threadID: "thread"))
        var restarted = EventLog(paths: paths)
        for event in restarted.readNew() { _ = EventReducer.apply(event, to: &state) }
        try require(state.selectedTasks[0].lastEventAt == Date(timeIntervalSince1970: 2_300), "重启后遗漏离线事件")
        try require(restarted.readNew().isEmpty, "重启后重复回放日志")
    }

    private static func checkEventLogPartialAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MonitorPaths(rootDirectory: root)
        var log = EventLog(paths: paths)
        try require(log.readNew().isEmpty, "日志不存在时应该返回空")
        try paths.ensureDirectory()
        let event = HookEvent(id: "partial", kind: .stop, threadID: "thread")
        let data = try MonitorJSON.encoder().encode(event)
        try data.prefix(data.count / 2).write(to: paths.eventLogFile)
        try require(log.readNew().isEmpty, "读取了未完成事件")
        let handle = try FileHandle(forWritingTo: paths.eventLogFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: data.suffix(data.count - data.count / 2))
        try require(log.readNew().isEmpty, "没有换行符的事件被提前读取")
        try handle.write(contentsOf: Data([0x0A]))
        try require(log.readNew().map(\.id) == ["partial"], "完整换行到达后事件丢失")
        try require(log.readNew().isEmpty, "完整事件被重复读取")
        try handle.truncate(atOffset: 0)
        try handle.close()
        try log.append(HookEvent(id: "x", kind: .stop, threadID: "thread"))
        try require(log.readNew().map(\.id) == ["x"], "截断日志后未从头恢复")
        let replacement = HookEvent(id: "replacement-with-longer-id", kind: .stop, threadID: "thread")
        var replacementData = try MonitorJSON.encoder().encode(replacement)
        replacementData.append(0x0A)
        try replacementData.write(to: paths.eventLogFile, options: .atomic)
        try require(log.readNew().map(\.id) == [replacement.id], "替换日志后错误沿用旧偏移")
    }

    private static func checkActivityNeverRegresses() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        state.selectedTasks[0].lastEventAt = Date(timeIntervalSince1970: 100)
        state.selectedTasks[0].lastActivityAt = Date(timeIntervalSince1970: 300)
        _ = EventReducer.apply(HookEvent(id: "late-prompt", kind: .userPromptSubmit, timestamp: Date(timeIntervalSince1970: 200), threadID: "thread", turnID: "turn"), to: &state)
        try require(state.selectedTasks[0].lastActivityAt == Date(timeIntervalSince1970: 300), "延迟提交事件使活动时间倒退")
        _ = EventReducer.apply(HookEvent(id: "late-stop", kind: .stop, timestamp: Date(timeIntervalSince1970: 250), threadID: "thread", turnID: "turn"), to: &state)
        try require(state.selectedTasks[0].lastActivityAt == Date(timeIntervalSince1970: 300), "延迟 Stop 使活动时间倒退")
        try require(state.selectedTasks[0].kaylaStatus == .awaitingDecision, "合法的延迟 Stop 未保留结束状态")
        var old = RolloutObservation()
        old.lastActivityAt = Date(timeIntervalSince1970: 150)
        _ = state.applyRolloutObservation(threadID: "thread", rolloutPath: "/tmp/thread.jsonl", observation: old)
        try require(state.selectedTasks[0].lastActivityAt == Date(timeIntervalSince1970: 300), "旧会话快照使活动时间倒退")
    }

    private static func checkRestartWithDelayedHookTimestamp() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        _ = EventReducer.apply(HookEvent(kind: .userPromptSubmit, timestamp: Date(timeIntervalSince1970: 101), threadID: "thread", turnID: "turn"), to: &state)
        state.markPreviousProcessingAsUncertain()
        var observation = RolloutObservation()
        observation.status = .processing
        observation.statusAt = Date(timeIntervalSince1970: 100)
        observation.latestTurnID = "older-turn"
        observation.lastActivityAt = Date(timeIntervalSince1970: 102)
        _ = state.applyRolloutObservation(threadID: "thread", rolloutPath: "/tmp/thread.jsonl", observation: observation)
        try require(state.selectedTasks[0].kaylaStatus == .needsConfirmation, "其他轮次错误恢复处理中")
        observation.latestTurnID = "turn"
        _ = state.applyRolloutObservation(threadID: "thread", rolloutPath: "/tmp/thread.jsonl", observation: observation)
        try require(state.selectedTasks[0].kaylaStatus == .processing, "同轮新活动未恢复重启后的处理中状态")
        try require(state.selectedTasks[0].lastEventAt == Date(timeIntervalSince1970: 101), "恢复状态时事件时间倒退")
    }

    private static func checkStallThresholdUnchanged() throws {
        var state = MonitorState()
        _ = state.addTask(threadID: "thread", title: "任务", projectPath: nil)
        state.selectedTasks[0].kaylaStatus = .processing
        state.selectedTasks[0].lastActivityAt = Date(timeIntervalSince1970: 100)
        try require(state.markPotentialStalls(now: Date(timeIntervalSince1970: 999)).isEmpty, "不足 15 分钟就提示停滞")
        try require(state.markPotentialStalls(now: Date(timeIntervalSince1970: 1_000)) == ["thread"], "15 分钟阈值发生改变")
        try require(state.selectedTasks[0].blocker?.summary == "超过 15 分钟没有新活动，请打开任务确认是否仍在执行", "停滞文案发生改变")
    }
}
