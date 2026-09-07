import CodexOrbCore
import Darwin
import Foundation

enum CLIUpdateChecks {
    static func run() async throws {
        try self.checkReleaseSelection()
        try await self.checkIndependentUpdatesAndRetention()
        try await self.checkStagedOpenTokenReplacement()
        try await self.checkProcessAndSandbox()
        print("CLI updater checks passed: release validation, independent results, rollback, locking, process limits and sandbox")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CLIUpdateChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    private static func checkReleaseSelection() throws {
        try self.expect(CLIVersion("0.9.0")! < CLIVersion("0.10.0")!, "numeric versions")
        try self.expect(CLIVersion("v0.56.6") == CLIVersion("0.56.6"), "release tag versions")
        for invalid in ["../1.0.0", "0.1", "0.1.2-beta", "", "0.1.-2"] {
            try self.expect(CLIVersion(invalid) == nil, "reject ambiguous version")
        }
        func release(url: String, digest: String, prerelease: Bool = false) throws -> CodexBarRelease {
            let json: [String: Any] = [
                "tag_name": "v0.56.6", "draft": false, "prerelease": prerelease,
                "assets": [["name": "CodexBarCLI-v0.56.6-macos-arm64.tar.gz",
                            "browser_download_url": url, "digest": digest]],
            ]
            return try JSONDecoder().decode(CodexBarRelease.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let url = "https://github.com/steipete/CodexBar/releases/download/v0.56.6/CodexBarCLI-v0.56.6-macos-arm64.tar.gz"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        _ = try release(url: url, digest: digest).candidate(architecture: "arm64")
        for invalid in [try release(url: url.replacingOccurrences(of: "github.com", with: "example.com"), digest: digest),
                        try release(url: url, digest: "sha256:bad"),
                        try release(url: url, digest: digest, prerelease: true)] {
            do {
                _ = try invalid.candidate(architecture: "arm64")
                throw NSError(domain: "test", code: 1)
            } catch CLIUpdateError.channelUnavailable { }
        }
        try self.expect(CLIUpdater.safeArchivePaths("CodexBarCLI\n./VERSION\nCodexBar_CodexBarCore.bundle/file.js\n"), "valid archive")
        for invalid in ["/tmp/escape", "./../../escape", "a/../escape", ""] {
            try self.expect(!CLIUpdater.safeArchivePaths(invalid), "unsafe archive path")
        }
    }

    private static func fixture(_ directory: URL, tool: CLITool, body: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent(tool.rawValue)
        try Data(body.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }

    private static func checkIndependentUpdatesAndRetention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orb-update-check-\(UUID().uuidString)")
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let bundled = root.appendingPathComponent("bundled")
        for tool in CLITool.allCases { try self.fixture(bundled, tool: tool, body: "#!/bin/sh\necho old\n") }
        try Data(#"{"codexbar":"1.0.0","opentoken":"1.0.0"}"#.utf8).write(to: bundled.appendingPathComponent("versions.json"))
        let store = CLIInstallationStore(root: root.appendingPathComponent("managed"), bundledDirectory: bundled)
        let updater = CLIUpdater(store: store, prepare: { tool, _, _, work, _ in
            if tool == .codexbar { throw CLIUpdateError.checksum }
            try self.fixture(work.appendingPathComponent("ready"), tool: tool, body: "#!/bin/sh\necho new\n")
            return "1.1.0"
        }, validate: { _, directory, _, _ in
            try self.expect(try String(contentsOf: directory.appendingPathComponent("opentoken"), encoding: .utf8).contains("new"), "validate candidate bytes")
        })
        async let quota = updater.update(.codexbar)
        async let tokens = updater.update(.opentoken)
        let (q, t) = await (quota, tokens)
        try self.expect(q.outcome == .failed && t.outcome == .updated, "one failure must not cancel the other tool")
        try self.expect(store.activeDirectory(for: .codexbar) == bundled, "failed update retains bundled version")
        try self.expect(store.activeVersion(for: .opentoken) == "1.1.0", "successful independent update activated")
        let oldDirectory = store.activeDirectory(for: .opentoken)
        let pointer = store.toolDirectory(for: .opentoken).appendingPathComponent("current.json")
        let oldPointer = try Data(contentsOf: pointer)

        let rejected = CLIUpdater(store: store, prepare: { tool, _, _, work, _ in
            try self.fixture(work.appendingPathComponent("ready"), tool: tool, body: "broken")
            return "1.2.0"
        }, validate: { _, _, _, _ in throw CLIUpdateError.validation })
        let result = await rejected.update(.opentoken)
        try self.expect(result.outcome == .failed, "invalid candidate rejected")
        try self.expect(try Data(contentsOf: pointer) == oldPointer, "failed validation leaves pointer byte-for-byte unchanged")
        try self.expect(store.activeDirectory(for: .opentoken) == oldDirectory, "old managed version retained")

        let unchanged = CLIUpdater(store: store, prepare: { _, _, _, _, _ in nil })
        let noUpdate = await unchanged.update(.opentoken)
        try self.expect(noUpdate.outcome == .unchanged, "no update is a distinct result")
        try self.expect(try Data(contentsOf: pointer) == oldPointer, "no-update does not reinstall")

        let descriptor = open(store.toolDirectory(for: .opentoken).appendingPathComponent("update.lock").path, O_RDWR)
        guard descriptor >= 0 else { throw CLIUpdateError.storage }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CLIUpdateError.busy }
        let busy = await updater.update(.opentoken)
        try self.expect(busy.outcome == .failed && busy.message.contains("另一个更新"), "cross-process lock refuses concurrent mutation")
        try self.expect(try Data(contentsOf: pointer) == oldPointer, "busy update does not change installation")
        flock(descriptor, LOCK_UN)

        try Data("corrupted executable".utf8).write(to: oldDirectory.appendingPathComponent("opentoken"))
        try self.expect(store.activeDirectory(for: .opentoken) == bundled, "damaged managed binary falls back to bundled copy")
        try Data(#"{"version":"1.2.0","generation":"../../escape","sha256":"invalid"}"#.utf8).write(to: pointer)
        try self.expect(store.activeDirectory(for: .opentoken) == bundled, "unsafe manifest cannot escape managed root")
    }

    private static func checkProcessAndSandbox() async throws {
        let shell = URL(fileURLWithPath: "/bin/sh")
        let output = try await CLIUpdateProcess.run(shell, arguments: ["-c", "printf '%100000s' x"], timeout: 3)
        try self.expect(output.status == 0 && output.stdout.count == 100000, "large stdout does not deadlock")
        do {
            _ = try await CLIUpdateProcess.run(shell, arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
            throw NSError(domain: "test", code: 1)
        } catch CLIUpdateError.timeout { }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orb-sandbox-check-\(UUID().uuidString)")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let protected = root.appendingPathComponent("protected")
        try Data("old".utf8).write(to: protected)
        let sandbox = try await CLIUpdateProcess.run(shell,
            arguments: ["-c", "echo new > \"$1\"; echo stage > \"$2\"", "test", protected.path, work.appendingPathComponent("allowed").path],
            writableDirectory: work)
        try self.expect(sandbox.status == 0, "sandbox allows staged writes: \(String(decoding: sandbox.stderr, as: UTF8.self))")
        try self.expect(try String(contentsOf: protected, encoding: .utf8) == "old", "self-update cannot overwrite external executable")
        try self.expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("allowed").path), "staged output exists")
    }

    private static func checkStagedOpenTokenReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orb-self-update-check-\(UUID().uuidString)")
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let bundled = root.appendingPathComponent("bundled")
        // Emulate the official current-executable + .old replacement contract. The production
        // preparation path (including sandbox and version discovery) runs unchanged.
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo 'opentoken 1.0.0';;
          self-update)
            /bin/cp "$0" "$0.old" || exit 1
            printf '#!/bin/sh\\necho "opentoken 1.1.0"\\n' > "$0.new" || exit 2
            /bin/chmod 755 "$0.new" || exit 3
            /bin/mv "$0.new" "$0" || exit 4
            ;;
          *) exit 5;;
        esac
        """
        try self.fixture(bundled, tool: .opentoken, body: script)
        try Data(#"{"opentoken":"1.0.0"}"#.utf8).write(to: bundled.appendingPathComponent("versions.json"))
        let original = try CLIInstallationStore.digest(of: bundled.appendingPathComponent("opentoken"))
        let store = CLIInstallationStore(root: root.appendingPathComponent("managed"), bundledDirectory: bundled)
        let updater = CLIUpdater(store: store, validate: { tool, directory, expected, _ in
            let actual = try await CLIUpdater.readVersion(directory.appendingPathComponent(tool.rawValue), tool: tool)
            try self.expect(actual == expected, "new staged binary can run")
        })
        let result = await updater.update(.opentoken)
        try self.expect(result.outcome == .updated && store.activeVersion(for: .opentoken) == "1.1.0",
                        "staged self-update publishes the replacement: \(result.message)")
        try self.expect(try CLIInstallationStore.digest(of: bundled.appendingPathComponent("opentoken")) == original,
                        "self-update leaves the source binary untouched")
        try self.expect(!FileManager.default.fileExists(atPath: bundled.appendingPathComponent("opentoken.old").path),
                        "self-update backups stay in staging")
    }
}
