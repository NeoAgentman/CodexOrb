import Foundation

/// Both the GUI and recorder resolve tools relative to their own app, never the working directory.
public enum BundledCLITools {
    public static var directory: URL {
        if let executable = Bundle.main.executableURL,
           let helpers = appHelpersDirectory(for: executable) {
            return helpers
        }
        return Bundle.module.resourceURL!.appendingPathComponent("Tools", isDirectory: true)
    }

    public static func appHelpersDirectory(for executable: URL) -> URL? {
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              contents.deletingLastPathComponent().pathExtension == "app" else { return nil }
        return contents.appendingPathComponent("Helpers", isDirectory: true)
    }
}
