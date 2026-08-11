import AppKit

/// App lifecycle only. The menu bar lives in `StatusMenuController`, login-item
/// reconciliation in `LoginItem`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = MonitorCoordinator()
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusMenu = StatusMenuController(coordinator: coordinator)
        LoginItem.syncWithStoredIntent()
        coordinator.startPerSchedule()
    }
}
