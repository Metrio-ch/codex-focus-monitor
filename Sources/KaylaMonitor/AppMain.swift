import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = PanelController()
        panelController = controller
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
enum KaylaMonitorMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
