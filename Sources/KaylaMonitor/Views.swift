import AppKit
import KaylaMonitorCore
import SwiftUI

private enum MonitorOverlay: Equatable {
    case picker
    case checkpoint(threadID: String, resume: Bool)
    case outsideActivities
    case replacement(OutsideActivity)
    case settings
}

struct MonitorRootView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var panelController: PanelController
    @ObservedObject var loginItemManager: LoginItemManager
    @State private var overlay: MonitorOverlay?

    var body: some View {
        Group {
            switch panelController.mode {
            case .collapsed:
                CollapsedPullTab(state: store.state) {
                    panelController.expandImmediately()
                }
                .contextMenu { pullTabMenu }

            case .peek(let threadID):
                PeekView(task: store.state.selectedTasks.first(where: { $0.threadID == threadID })) {
                    store.openThread(threadID: threadID)
                }

            case .expanded:
                ZStack {
                    DashboardView(
                        store: store,
                        panelController: panelController,
                        onAdd: { present(.picker) },
                        onCheckpoint: { threadID, resume in
                            present(.checkpoint(threadID: threadID, resume: resume))
                        },
                        onOutside: { present(.outsideActivities) },
                        onSettings: { present(.settings) }
                    )

                    if let overlay {
                        overlayView(overlay)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pullTabMenu: some View {
        Button(loginItemManager.isEnabled ? "关闭登录时启动" : "登录时启动") {
            loginItemManager.toggle()
        }
        Button("退出 Kayla 工作监控台") {
            NSApplication.shared.terminate(nil)
        }
    }

    @ViewBuilder
    private func overlayView(_ overlay: MonitorOverlay) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { dismissOverlay() }

            switch overlay {
            case .picker:
                TaskPickerView(store: store, onClose: dismissOverlay)
                    .frame(width: 470, height: 320)

            case .checkpoint(let threadID, let resume):
                if let task = store.state.selectedTasks.first(where: { $0.threadID == threadID }) {
                    CheckpointEditorView(
                        task: task,
                        initialPoint: store.draftRecoveryPoint(threadID: threadID),
                        isResume: resume,
                        onCancel: dismissOverlay,
                        onCommit: { current, next in
                            store.saveRecoveryPoint(
                                threadID: threadID,
                                currentDiscussion: current,
                                nextAction: next
                            )
                            dismissOverlay()
                            if resume {
                                store.openThread(threadID: threadID)
                            }
                        }
                    )
                    .id("\(threadID)-\(resume)")
                    .frame(width: 450, height: 286)
                }

            case .outsideActivities:
                OutsideActivitiesView(
                    store: store,
                    onClose: dismissOverlay,
                    onReplace: { activity in present(.replacement(activity)) }
                )
                .frame(width: 460, height: 300)

            case .replacement(let activity):
                ReplacementView(
                    activity: activity,
                    tasks: store.state.selectedTasks,
                    onCancel: { present(.outsideActivities) },
                    onReplace: { threadID in
                        store.replaceTask(threadID: threadID, with: activity)
                        dismissOverlay()
                    }
                )
                .frame(width: 430, height: 250)

            case .settings:
                SettingsView(
                    store: store,
                    loginItemManager: loginItemManager,
                    onClose: dismissOverlay
                )
                .frame(width: 420, height: 250)
            }
        }
    }

    private func present(_ newOverlay: MonitorOverlay) {
        overlay = newOverlay
        panelController.beginInteraction()
    }

    private func dismissOverlay() {
        overlay = nil
        panelController.endInteraction()
    }
}

private struct CollapsedPullTab: View {
    let state: MonitorState
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index < state.selectedTasks.count ? state.selectedTasks[index].displayColor : Color.white.opacity(0.28))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white.opacity(0.34), lineWidth: 1))
                    .shadow(
                        color: index < state.selectedTasks.count ? state.selectedTasks[index].displayColor.opacity(0.55) : .clear,
                        radius: 2
                    )
            }
            if state.actionRequiredCount > 0 {
                Text("待处理 \(state.actionRequiredCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.08, green: 0.09, blue: 0.11), in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .overlay(
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityLabel("展开 Kayla 工作监控台")
    }
}

private struct PeekView: View {
    let task: TaskCard?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Circle()
                    .fill(task?.displayColor ?? Color.orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task?.title ?? "有任务等你判断")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(task?.displaySummary ?? "有任务需要你处理，点击查看")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .padding(3)
    }
}

private struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var panelController: PanelController
    let onAdd: () -> Void
    let onCheckpoint: (String, Bool) -> Void
    let onOutside: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header

            if store.state.selectedTasks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 7) {
                    ForEach(store.state.selectedTasks) { task in
                        TaskCardView(
                            task: task,
                            onFocus: { store.setFocus(threadID: task.threadID) },
                            onCheckpoint: {
                                let isResume = task.attentionState == .parked && task.recoveryPoint != nil
                                onCheckpoint(task.threadID, isResume)
                            },
                            onOpen: { store.openThread(threadID: task.threadID) },
                            onComplete: { store.markStageComplete(threadID: task.threadID) },
                            onRemove: { store.removeTask(threadID: task.threadID) }
                        )
                    }
                }
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color.primary.opacity(0.1)))
        .padding(3)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Kayla 工作监控台")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("今天只看这三个探索线程")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if !store.state.outsideActivities.isEmpty {
                Button(action: onOutside) {
                    Label("\(store.state.outsideActivities.count)", systemImage: "bolt.badge.clock")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("今日范围外有活动")
            }

            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(HeaderButtonStyle())
            .disabled(store.state.selectedTasks.count >= 3)
            .help(store.state.selectedTasks.count >= 3 ? "最多三个任务；请先移除一个" : "添加探索线程")

            Button(action: panelController.togglePinned) {
                Image(systemName: panelController.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(HeaderButtonStyle(active: panelController.isPinned))
            .help(panelController.isPinned ? "取消固定" : "固定展开")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(HeaderButtonStyle())
        }
    }

    private var emptyState: some View {
        Button(action: onAdd) {
            VStack(spacing: 9) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 25))
                Text("选择今天要跟进的探索线程")
                    .font(.system(size: 13, weight: .medium))
                Text("不必先写目标或方案")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.blue).frame(width: 9, height: 9)
            Text("处理中")
            Circle().fill(Color.orange).frame(width: 9, height: 9)
            Text("等你判断")
            Circle().fill(Color.red).frame(width: 9, height: 9)
            Text("有阻塞")
            Spacer()
            if let error = store.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("本机存储")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 9))
    }
}

private struct TaskCardView: View {
    let task: TaskCard
    let onFocus: () -> Void
    let onCheckpoint: () -> Void
    let onOpen: () -> Void
    let onComplete: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Circle()
                    .fill(task.displayColor)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                Button(action: onOpen) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(task.displayLabel)
                                .foregroundStyle(task.displayColor)
                            if let project = task.projectDisplayName {
                                Text("· \(project)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 9))
                        if let blocker = task.blocker {
                            Text(blocker.summary)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(blocker.summary)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label(task.currentTurnDurationLabel(at: context.date), systemImage: "clock")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(task.kaylaStatus == .processing ? Color.blue : Color.secondary)
                            .monospacedDigit()
                    }
                    Text(task.attentionState.label)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            task.attentionState == .currentFocus ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                }
            }

            HStack(spacing: 6) {
                SmallActionButton(
                    title: task.attentionState == .currentFocus ? "正在聚焦" : "聚焦",
                    systemImage: "scope",
                    active: task.attentionState == .currentFocus,
                    action: onFocus
                )
                SmallActionButton(
                    title: task.attentionState == .parked && task.recoveryPoint != nil ? "恢复" : "停靠",
                    systemImage: task.attentionState == .parked && task.recoveryPoint != nil ? "arrow.uturn.forward" : "parkingsign.circle",
                    action: onCheckpoint
                )
                SmallActionButton(title: "打开", systemImage: "arrow.up.right.square", action: onOpen)
                Menu {
                    Button("今日阶段完成", action: onComplete)
                    Divider()
                    Button("从今日面板移除", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(task.attentionState == .currentFocus ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06))
        )
    }
}

private struct SmallActionButton: View {
    let title: String
    let systemImage: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(active ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.055), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TaskPickerView: View {
    @ObservedObject var store: MonitorStore
    let onClose: () -> Void
    @State private var manualInput = ""

    var body: some View {
        VStack(spacing: 10) {
            overlayHeader("选择探索线程", onClose: onClose) {
                Button(action: store.refreshRecentThreads) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }

            if store.isLoadingRecentThreads {
                ProgressView("读取最近任务…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.recentThreads.filter { !store.state.selectedThreadIDs.contains($0.id) }) { thread in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(thread.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(thread.projectDisplayName ?? "未标注项目")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("加入") {
                                    if store.addTask(thread), store.state.selectedTasks.count >= 3 {
                                        onClose()
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(store.state.selectedTasks.count >= 3)
                            }
                            .padding(7)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                TextField("粘贴 codex://threads/… 或任务 ID", text: $manualInput)
                    .textFieldStyle(.roundedBorder)
                Button("加入") {
                    if store.addTask(from: manualInput) {
                        manualInput = ""
                        if store.state.selectedTasks.count >= 3 { onClose() }
                    }
                }
                .disabled(manualInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.state.selectedTasks.count >= 3)
            }

            if let error = store.lastError {
                Text(error).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .onAppear {
            if store.recentThreads.isEmpty { store.refreshRecentThreads() }
        }
    }
}

private struct CheckpointEditorView: View {
    let task: TaskCard
    let isResume: Bool
    let onCancel: () -> Void
    let onCommit: (String, String) -> Void
    @State private var currentDiscussion: String
    @State private var nextAction: String

    init(
        task: TaskCard,
        initialPoint: RecoveryPoint?,
        isResume: Bool,
        onCancel: @escaping () -> Void,
        onCommit: @escaping (String, String) -> Void
    ) {
        self.task = task
        self.isResume = isResume
        self.onCancel = onCancel
        self.onCommit = onCommit
        _currentDiscussion = State(initialValue: initialPoint?.currentDiscussion ?? "")
        _nextAction = State(initialValue: initialPoint?.nextAction ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            overlayHeader(isResume ? "恢复任务" : "设置恢复点", onClose: onCancel)
            Text(task.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            checkpointField("当前讨论到", text: $currentDiscussion)
            checkpointField("回来后先做", text: $nextAction)

            HStack {
                Text("草稿由最近一轮对话预填，确认后才保存")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel)
                Button(isResume ? "保存并打开" : "确认停靠") {
                    onCommit(currentDiscussion, nextAction)
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentDiscussion.trimmedExcerpt(limit: 600).isEmpty || nextAction.trimmedExcerpt(limit: 600).isEmpty)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }

    private func checkpointField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium))
            TextEditor(text: text)
                .font(.system(size: 11))
                .frame(height: 58)
                .padding(4)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct OutsideActivitiesView: View {
    @ObservedObject var store: MonitorStore
    let onClose: () -> Void
    let onReplace: (OutsideActivity) -> Void

    var body: some View {
        VStack(spacing: 10) {
            overlayHeader("今日范围外有活动", onClose: onClose)
            Text("这些任务不会自动占用第四个注意力槽位。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(store.state.outsideActivities) { activity in
                        HStack(spacing: 8) {
                            Circle().fill(activity.lastKnownStatus.color).frame(width: 11, height: 11)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.displayName).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(activity.lastKnownStatus.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("忽略") { store.ignoreOutsideActivity(threadID: activity.threadID) }
                                .controlSize(.small)
                            Button(store.state.selectedTasks.count < 3 ? "加入" : "替换…") {
                                if store.state.selectedTasks.count < 3 {
                                    _ = store.addTask(
                                        RecentThread(
                                            id: activity.threadID,
                                            title: activity.displayName,
                                            projectPath: activity.projectPath,
                                            rolloutPath: nil,
                                            updatedAt: activity.lastEventAt
                                        )
                                    )
                                } else {
                                    onReplace(activity)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }
}

private struct ReplacementView: View {
    let activity: OutsideActivity
    let tasks: [TaskCard]
    let onCancel: () -> Void
    let onReplace: (String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            overlayHeader("替换一个今日任务", onClose: onCancel)
            Text("把“\(activity.displayName)”加入面板，并移除：")
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(tasks) { task in
                Button {
                    onReplace(task.threadID)
                } label: {
                    HStack {
                        Text(task.title).lineLimit(1)
                        Spacer()
                        Text(task.attentionState.label).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }
}

private struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var loginItemManager: LoginItemManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            overlayHeader("设置", onClose: onClose)
            Toggle(
                "登录时启动",
                isOn: Binding(
                    get: { loginItemManager.isEnabled },
                    set: { _ in loginItemManager.toggle() }
                )
            )
            .toggleStyle(.switch)

            if loginItemManager.requiresApproval {
                Text("macOS 需要你在“系统设置 → 通用 → 登录项”中允许此应用。")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if let error = loginItemManager.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }

            HStack {
                Button("打开本地数据目录", action: store.openDataDirectory)
                Spacer()
                Text("v0.3.4").foregroundStyle(.secondary)
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 10))
            Spacer()
            Text("仅已选任务保存有限对话摘录；未选任务只保存活动元数据。")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 25, height: 25)
            .background(
                active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06),
                in: Circle()
            )
    }
}

private extension KaylaStatus {
    var color: Color {
        switch self {
        case .processing: return .blue
        case .awaitingDecision: return .orange
        case .needsConfirmation: return .gray
        case .stageComplete: return .green
        }
    }
}

private extension TaskCard {
    var displayColor: Color {
        blocker == nil ? kaylaStatus.color : .red
    }

    var displayLabel: String {
        blocker?.kind.label ?? kaylaStatus.label
    }

    var displaySummary: String {
        if let blocker { return blocker.summary }
        if kaylaStatus == .awaitingDecision { return "Kayla 已完成这一轮，点击查看" }
        if kaylaStatus == .needsConfirmation { return "任务状态需要你确认，点击查看" }
        return kaylaStatus.label
    }
}

@ViewBuilder
private func overlayHeader<Trailing: View>(
    _ title: String,
    onClose: @escaping () -> Void,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack {
        Text(title).font(.system(size: 14, weight: .bold, design: .rounded))
        Spacer()
        trailing()
        Button(action: onClose) { Image(systemName: "xmark") }
            .buttonStyle(.plain)
    }
}

private func overlayHeader(_ title: String, onClose: @escaping () -> Void) -> some View {
    overlayHeader(title, onClose: onClose) { EmptyView() }
}
