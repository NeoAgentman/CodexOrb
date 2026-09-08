import CodexOrbCore
import Foundation

private struct AccountCheckFailure: Error { let message: String }

enum AccountChecks {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orb-accounts-\(UUID().uuidString)")
        defer { try? fm.trashItem(at: root, resultingItemURL: nil) }
        let store = CodexAccountStore(root: root.appendingPathComponent("owned"), nativeHome: root.appendingPathComponent("native"))
        func writeAccount(_ home: URL, email: String, workspace: String) throws {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let claims: [String: Any] = ["email": email, "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let auth = ["tokens": ["id_token": "header.\(payload).signature", "access_token": "fixture", "account_id": workspace]]
            try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent("auth.json"))
        }
        try writeAccount(store.nativeHome, email: "same@example.test", workspace: "workspace-A")
        let secondHome = try store.createLoginHome()
        try writeAccount(secondHome, email: "same@example.test", workspace: "workspace-B")
        let missing = try store.createLoginHome()
        let accounts = store.accounts(additionalHomes: [store.nativeHome.path, missing.path])
        try expect(accounts.count == 2, "deduplicate homes and exclude unfinished login")
        try expect(accounts[0].identityKey != accounts[1].identityKey, "same email, different workspaces stay isolated")
        let nativeAuth = try Data(contentsOf: store.nativeHome.appendingPathComponent("auth.json"))
        let executable = root.appendingPathComponent("codexbar")
        let script = """
        #!/bin/sh
        test "$*" = "usage --provider codex --source oauth --format json --json-only" || exit 64
        test "$CODEX_HOME" = "$EXPECTED_HOME" || exit 65
        printf '%s' '{"provider":"codex","usage":{"accountEmail":"same@example.test","primary":{"usedPercent":20},"secondary":{"usedPercent":30,"windowMinutes":10080},"updatedAt":"2026-09-06T00:00:00Z"}}'
        """
        try Data(script.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        for account in accounts {
            let usage = try await CodexBarCLIUsageSource(accountHome: account.home, bundledExecutableDirectory: root,
                environment: ["EXPECTED_HOME": account.home, "CODEX_HOME": "/wrong"], timeout: 2).fetch()
            try expect(usage.weekly?.usedPercent == 30, "explicit home and scoped CLI")
        }
        try expect(try Data(contentsOf: store.nativeHome.appendingPathComponent("auth.json")) == nativeAuth,
                   "account selection does not overwrite native login")
        do {
            _ = try await CodexBarCLIUsageSource(accountHome: missing.path, bundledExecutableDirectory: root).fetch()
            throw AccountCheckFailure(message: "missing selected account fell back")
        } catch CodexAccountError.invalidAccount { }
          catch CocoaError.fileReadNoSuchFile { }
        print("Account checks passed: discovery, workspace isolation, scoped CLI, missing account")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AccountCheckFailure(message: message) }
    }
}
