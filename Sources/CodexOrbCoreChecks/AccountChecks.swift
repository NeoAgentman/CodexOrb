import CodexOrbCore
import Foundation

private struct AccountCheckFailure: Error { let message: String }

enum AccountChecks {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("orb-accounts-\(UUID().uuidString)")
        defer { try? fm.trashItem(at: root, resultingItemURL: nil) }
        let store = CodexAccountStore(root: root.appendingPathComponent("owned"), nativeHome: root.appendingPathComponent("native"))
        do {
            _ = try await CodexAppServerUsageSource().fetch()
            throw AccountCheckFailure(message: "empty account selection fell back to native")
        } catch CodexAccountError.noManagedAccount { }
        do {
            _ = try await CodexAppServerUsageSource(accountHome: CodexAccountStore().nativeHome.path).fetch()
            throw AccountCheckFailure(message: "native account was accepted by the app-server source")
        } catch CodexAccountError.notManaged { }

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
        let managedAccounts = store.managedAccounts()
        try expect(managedAccounts.count == 1 && managedAccounts[0].home == secondHome.path,
                   "managed discovery excludes native and unfinished homes")
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

        let managed = managedAccounts[0]
        let resetRoot = root.appendingPathComponent("reset-operations")
        let resetStore = PendingResetStore(root: resetRoot)
        try Data("account state".utf8).write(to: secondHome.appendingPathComponent("config.toml"))
        try resetStore.save(PendingReset(identityKey: managed.identityKey, creditID: "credit"))
        let quarantine = resetRoot.appendingPathComponent("Quarantine")
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let quarantined = quarantine.appendingPathComponent("\(managed.identityKey)-old.json")
        try Data("damaged".utf8).write(to: quarantined)
        try store.delete(account: managed, pendingResetStore: resetStore)
        try expect(!fm.fileExists(atPath: secondHome.path), "managed account home removed")
        try expect(!fm.fileExists(atPath: resetRoot.appendingPathComponent(managed.identityKey).path),
                   "account reset state removed")
        try expect(!fm.fileExists(atPath: quarantined.path), "quarantined account state removed")

        let native = accounts[0]
        let nativePending = PendingReset(identityKey: native.identityKey, creditID: "native-credit")
        try resetStore.save(nativePending)
        do {
            try store.delete(account: native, pendingResetStore: resetStore)
            throw AccountCheckFailure(message: "native account was deletable")
        } catch CodexAccountError.notManaged { }
        try expect(try Data(contentsOf: store.nativeHome.appendingPathComponent("auth.json")) == nativeAuth,
                   "native account remains untouched")
        try expect(try resetStore.read(native.identityKey) == nativePending,
                   "native account reset state remains untouched")

        print("Account checks passed: managed-only source, discovery, managed-only account list, scoped CLI, missing account, safe account deletion")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AccountCheckFailure(message: message) }
    }
}
