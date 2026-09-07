import CoreGraphics
import Foundation

// Open the installed app's right-click menu before running this read-only check.
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
guard let menu = windows.first(where: {
    ($0[kCGWindowOwnerName as String] as? String) == "CodexOrb"
        && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
}), let bounds = menu[kCGWindowBounds as String] as? [String: Any],
      let height = bounds["Height"] as? Double else {
    print("Open the CodexOrb context menu first")
    exit(2)
}
guard height >= 80 else {
    print("Context menu is clipped: height = \(height), expected at least 80")
    exit(1)
}
print("Context menu height passed: \(height)")
