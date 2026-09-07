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
            try expect(usage.accountKey == account.identityKey, "explicit home and stable account journal key")
        }
        try expect(try Data(contentsOf: store.nativeHome.appendingPathComponent("auth.json")) == nativeAuth,
                   "account selection does not overwrite native login")
        do {
            _ = try await CodexBarCLIUsageSource(accountHome: missing.path, bundledExecutableDirectory: root).fetch()
            throw AccountCheckFailure(message: "missing selected account fell back")
        } catch CodexAccountError.invalidAccount { }
          catch CocoaError.fileReadNoSuchFile { }
        let journal = DailyQuotaStore(directory: root.appendingPathComponent("journal"))
        let baseline = Date(timeIntervalSince1970: 1_788_652_800)
        @Sendable func sample(_ account: CodexAccount, percent: Double, at date: Date) -> CodexUsage {
            CodexUsage(accountKey: account.identityKey, session: nil,
                       weekly: CodexQuotaWindow(usedPercent: percent, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil),
                       updatedAt: date)
        }
        let result = await DailyAccountRecorder.record(accounts: accounts + [accounts[0]], store: journal,
            fetch: { account in sample(account, percent: 20, at: baseline) }, retries: 0)
        try expect(result.succeeded == 2 && result.failed == 0, "midnight records every unique account")
        let first = try journal.record(sample(accounts[0], percent: 25, at: baseline.addingTimeInterval(3600)))
        let second = try journal.record(sample(accounts[1], percent: 28, at: baseline.addingTimeInterval(3600)))
        try expect(first?.consumedPercent == 5 && second?.consumedPercent == 8, "switching reuses each account's baseline")
        let failingKey = accounts[0].identityKey
        let partial = await DailyAccountRecorder.record(accounts: accounts, store: journal, fetch: { account in
            if account.identityKey == failingKey { throw CodexAccountError.invalidAccount }
            return sample(account, percent: 30, at: baseline.addingTimeInterval(7200))
        }, retries: 0)
        try expect(partial.succeeded == 1 && partial.failed == 1, "failed account cannot prevent another account's record")
        let oldJournal = DailyQuotaStore(directory: root.appendingPathComponent("legacy-journal"))
        let window = CodexQuotaWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil)
        _ = try oldJournal.record(CodexUsage(accountKey: "old-email-plan-key", session: nil, weekly: window, updatedAt: baseline))
        let migrated = try oldJournal.record(CodexUsage(accountKey: accounts[0].identityKey,
            legacyAccountKey: "old-email-plan-key", session: nil,
            weekly: CodexQuotaWindow(usedPercent: 27, windowMinutes: 10_080, resetsAt: nil, resetDescription: nil),
            updatedAt: baseline.addingTimeInterval(3600)))
        try expect(migrated?.consumedPercent == 7, "unambiguous legacy baseline survives migration")
        print("Account checks passed: discovery, workspace isolation, scoped CLI, missing account, all-account midnight recording")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw AccountCheckFailure(message: message) }
    }
}
