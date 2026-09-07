import Foundation
import CodexOrbCore

struct DailyQuotaLaunchAgent {
    static let label = "com.local.CodexOrb.daily-quota"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var service: String { "gui/\(getuid())/\(label)" }
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path) && (try? run(["print", service])) != nil
    }

    static func setEnabled(_ enabled: Bool, accountHome: String) throws {
        if !enabled {
            if (try? run(["print", service])) != nil { try run(["bootout", service]) }
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.trashItem(at: plistURL, resultingItemURL: nil)
            }
            return
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CodexOrbRecorder")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NSError(domain: label, code: 1, userInfo: [NSLocalizedDescriptionKey: "Recorder missing from the installed app."])
        }
        let dir = DailyQuotaStore.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path, "--account-home", accountHome],
            "StartCalendarInterval": ["Hour": 0, "Minute": 0],
            "RunAtLoad": true,
            "ProcessType": "Background",
            "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
            "StandardOutPath": dir.appendingPathComponent("recorder.log").path,
            "StandardErrorPath": dir.appendingPathComponent("recorder-error.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let oldData = try? Data(contentsOf: plistURL)
        if oldData == data, isEnabled { return }
        if (try? run(["print", service])) != nil { try run(["bootout", service]) }
        do {
            try data.write(to: plistURL, options: .atomic)
            try run(["bootstrap", "gui/\(getuid())", plistURL.path])
        } catch {
            if let oldData {
                try? oldData.write(to: plistURL, options: .atomic)
                try? run(["bootstrap", "gui/\(getuid())", plistURL.path])
            } else if FileManager.default.fileExists(atPath: plistURL.path) {
                try? FileManager.default.trashItem(at: plistURL, resultingItemURL: nil)
            }
            throw error
        }
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: label, code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "launchctl failed",
            ])
        }
    }
}
