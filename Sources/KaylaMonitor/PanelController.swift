import AppKit
import Combine
import KaylaMonitorCore
import SwiftUI

enum PanelDisplayMode: Equatable {
    case collapsed
    case peek(threadID: String)
    case expanded
}

final class KaylaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TrackingHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

@MainActor
final class PanelController: NSObject, ObservableObject {
    private static let preferredDisplayName = "T270CF"

    @Published private(set) var mode: PanelDisplayMode = .collapsed
    @Published var isPinned = false {
        didSet {
            if isPinned { expandImmediately() }
        }
    }
    @Published private(set) var isInteractionLocked = false

    let store: MonitorStore
    let loginItemManager: LoginItemManager

    private let panel: KaylaPanel
    private var isHovered = false
    private var expandWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var peekWorkItem: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?

    override init() {
        self.store = MonitorStore()
        self.loginItemManager = LoginItemManager()
        self.panel = KaylaPanel(
            contentRect: NSRect(x: 0, y: 0, width: 150, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false

        let rootView = MonitorRootView(store: store, panelController: self, loginItemManager: loginItemManager)
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.onMouseEntered = { [weak self] in self?.mouseEntered() }
        hostingView.onMouseExited = { [weak self] in self?.mouseExited() }
        panel.contentView = hostingView

        store.onAwaitingDecision = { [weak self] threadID in
            self?.showPeek(threadID: threadID)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updatePanelFrame(animated: false) }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        updatePanelFrame(animated: false)
        panel.orderFrontRegardless()
        store.start()
        store.refreshRecentThreads()
    }

    func shutdown() {
        store.stop()
    }

    func expandImmediately() {
        cancelScheduledTransitions()
        setMode(.expanded)
    }

    func collapseIfAllowed() {
        guard !isHovered, !isPinned, !isInteractionLocked else { return }
        setMode(.collapsed)
    }

    func togglePinned() {
        isPinned.toggle()
        if !isPinned {
            collapseIfAllowed()
        }
    }

    func beginInteraction() {
        isInteractionLocked = true
        expandImmediately()
        panel.makeKey()
    }

    func endInteraction() {
        isInteractionLocked = false
        panel.resignKey()
        if !isHovered && !isPinned {
            scheduleCollapse()
        }
    }

    func showPeek(threadID: String) {
        peekWorkItem?.cancel()
        if isHovered || isPinned || isInteractionLocked {
            setMode(.expanded)
        } else {
            setMode(.peek(threadID: threadID))
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isHovered && !self.isPinned && !self.isInteractionLocked {
                self.setMode(.collapsed)
            }
        }
        peekWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func mouseEntered() {
        isHovered = true
        collapseWorkItem?.cancel()
        peekWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.setMode(.expanded) }
        expandWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func mouseExited() {
        isHovered = false
        expandWorkItem?.cancel()
        scheduleCollapse()
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.collapseIfAllowed() }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
    }

    private func cancelScheduledTransitions() {
        expandWorkItem?.cancel()
        collapseWorkItem?.cancel()
        peekWorkItem?.cancel()
    }

    private func setMode(_ newMode: PanelDisplayMode) {
        guard mode != newMode else { return }
        mode = newMode
        updatePanelFrame(animated: true)
        panel.orderFrontRegardless()
    }

    private func updatePanelFrame(animated: Bool) {
        guard let screen = targetScreen() else { return }
        let size: NSSize
        switch mode {
        case .collapsed:
            size = NSSize(width: 150, height: 28)
        case .peek:
            size = NSSize(width: 420, height: 68)
        case .expanded:
            size = NSSize(width: 520, height: 360)
        }

        panel.hasShadow = mode != .collapsed
        let screenFrame = screen.frame
        let frame = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )

        let shouldAnimate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let candidates = screens.map {
            DisplayCandidate(name: $0.localizedName, isBuiltIn: isBuiltIn($0))
        }
        guard let index = DisplaySelection.preferredIndex(
            in: candidates,
            preferredName: Self.preferredDisplayName
        ) else {
            return nil
        }
        return screens[index]
    }

    private func isBuiltIn(_ screen: NSScreen) -> Bool {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
