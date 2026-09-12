import AppKit
import Darwin

/// Nonactivating panels cannot normally update the system cursor while another app is active.
/// Resolve this private WindowServer compatibility hook dynamically so its absence does not
/// prevent launch. Access is scoped to pointer entry/exit; no app activation or polling is used.
@MainActor
enum BackgroundCursorAccess {
    private typealias ConnectionID = @convention(c) () -> UInt32
    private typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
    private static let connection: (id: UInt32, setProperty: SetProperty)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL)
        else { return nil }
        guard let getID = dlsym(handle, "CGSMainConnectionID") ?? dlsym(handle, "_CGSDefaultConnection"),
              let setProperty = dlsym(handle, "CGSSetConnectionProperty") else {
            dlclose(handle)
            return nil
        }
        return (unsafeBitCast(getID, to: ConnectionID.self)(), unsafeBitCast(setProperty, to: SetProperty.self))
    }()
    private static var isEnabled = false

    static func setEnabled(_ enabled: Bool) {
        guard enabled != self.isEnabled, let connection else { return }
        let result = connection.setProperty(connection.id, connection.id,
                                            "SetsCursorInBackground" as CFString,
                                            enabled ? kCFBooleanTrue! : kCFBooleanFalse!)
        if result == 0 { self.isEnabled = enabled }
    }
}
