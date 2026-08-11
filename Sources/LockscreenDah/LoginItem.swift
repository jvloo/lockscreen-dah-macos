import AppKit
import ServiceManagement

/// "Open at Login" registration.
///
/// The OS-level registration is tied to the app's code signature, and ad-hoc
/// signing produces a new one on every rebuild — so it does not reliably survive
/// a reinstall. The user's *intent* is therefore stored separately and the two
/// are reconciled at launch. Without that, an update could silently leave the
/// login item unregistered while the menu still showed it on, and the next
/// manual toggle would add a second entry alongside the orphan.
enum LoginItem {
    static var isRegistered: Bool { SMAppService.mainApp.status == .enabled }

    /// Brings the real registration in line with the stored intent. Safe to call
    /// on every launch; a no-op when they already agree.
    static func syncWithStoredIntent() {
        let wanted = Settings.openAtLoginEnabled
        guard wanted != isRegistered else { return }
        apply(wanted)
    }

    /// Flips the setting and records the new intent. Returns the error if macOS
    /// refused, so the caller can surface it rather than failing silently.
    @discardableResult
    static func toggle() -> Error? {
        let enabling = !isRegistered
        do {
            try applyThrowing(enabling)
            Settings.openAtLoginEnabled = enabling
            return nil
        } catch {
            return error
        }
    }

    private static func apply(_ enabled: Bool) { try? applyThrowing(enabled) }

    private static func applyThrowing(_ enabled: Bool) throws {
        // Always unregister first when enabling: a stale entry from a previous
        // build's signature would otherwise sit alongside the new one.
        try? SMAppService.mainApp.unregister()
        if enabled { try SMAppService.mainApp.register() }
    }
}
