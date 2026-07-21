import CoreGraphics
import Foundation

enum ScreenLocker {
    /// Locks the session the same way Ctrl-Cmd-Q does.
    /// `SACLockScreenImmediate` is private API (login.framework) but is the only
    /// way to trigger a real lock without keychain tricks; `CGSession -suspend`
    /// is the fallback (fast user switching suspend, which also requires a
    /// password when "require password immediately" is on).
    ///
    /// The return value only means an API accepted the call — callers must
    /// confirm with `sessionIsLocked` after a beat, since a silent failure
    /// here leaves the desktop exposed.
    @discardableResult
    static func lock() -> Bool {
        lockViaLoginFramework() || lockViaCGSession()
    }

    /// Whether the session is actually locked right now.
    static var sessionIsLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func lockViaLoginFramework() -> Bool {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            RTLD_LAZY
        ) else { return false }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFunction = @convention(c) () -> Int32
        let lockScreen = unsafeBitCast(symbol, to: LockFunction.self)
        return lockScreen() == 0
    }

    private static func lockViaCGSession() -> Bool {
        let path = "/System/Library/CoreServices/RemoteManagement/AppleVNCServer.bundle/Contents/Support/CGSession"
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-suspend"]
        return (try? process.run()) != nil
    }
}
