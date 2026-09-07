import Darwin
import Foundation

/// File-backed capture avoids filling a pipe while waiting for a child to finish.
public enum CLIUpdateProcess {
    public struct Output: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: Data
    }

    public static func run(
        _ executable: URL, arguments: [String], timeout: TimeInterval = 30,
        writableDirectory: URL? = nil, environment: [String: String]? = nil) async throws -> Output
    {
        try await Task.detached(priority: .utility) {
            try self.runBlocking(executable, arguments: arguments, timeout: timeout,
                                 writableDirectory: writableDirectory, environment: environment)
        }.value
    }

    private static func runBlocking(
        _ executable: URL, arguments: [String], timeout: TimeInterval,
        writableDirectory: URL?, environment: [String: String]?) throws -> Output
    {
        let fm = FileManager.default
        let capture = fm.temporaryDirectory.appendingPathComponent("orb-cli-output-\(UUID().uuidString)")
        try fm.createDirectory(at: capture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: capture) }
        let outURL = capture.appendingPathComponent("stdout")
        let errURL = capture.appendingPathComponent("stderr")
        guard fm.createFile(atPath: outURL.path, contents: nil), fm.createFile(atPath: errURL.path, contents: nil)
        else { throw CLIUpdateError.storage }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        if let writableDirectory {
            // The self-updater and archive extractor cannot write into the app, active CLI,
            // global installation, login files or service definitions, even if upstream changes.
            func quoted(_ url: URL) throws -> String {
                // Foundation normalizes /private/var back to /var; Seatbelt matches the real path.
                guard let resolved = realpath(url.path, nil) else { throw CLIUpdateError.storage }
                defer { free(resolved) }
                let path = String(cString: resolved)
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(path)\""
            }
            let writablePath = try quoted(writableDirectory)
            let capturePath = try quoted(capture)
            let profile = "(version 1) (allow default) (deny file-write*) "
                + "(allow file-write* (subpath \(writablePath))) "
                + "(allow file-write* (subpath \(capturePath)))"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, executable.path] + arguments
        } else {
            process.executableURL = executable
            process.arguments = arguments
        }
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: CLIUpdateError?
        while process.isRunning {
            if Date() >= deadline { failure = .timeout; break }
            let sizes = [outURL, errURL].map {
                (try? fm.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue ?? 0
            }
            if sizes.contains(where: { $0 > 2_097_152 }) { failure = .outputTooLarge; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let failure {
            process.terminate()
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw failure
        }
        process.waitUntilExit()
        let stdout = try Data(contentsOf: outURL)
        let stderr = try Data(contentsOf: errURL)
        guard stdout.count <= 2_097_152, stderr.count <= 2_097_152 else { throw CLIUpdateError.outputTooLarge }
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
