import Foundation

public struct DailyAccountRecordingResult: Sendable {
    public let succeeded: Int
    public let failed: Int
}

public enum DailyAccountRecorder {
    /// All accounts are attempted independently, including accounts not selected in the capsule.
    public static func record(
        accounts: [CodexAccount], store: DailyQuotaStore = DailyQuotaStore(),
        fetch: @escaping @Sendable (CodexAccount) async throws -> CodexUsage = { account in
            try await CodexBarCLIUsageSource(accountHome: account.home).fetch()
        }, retries: Int = 2, retryDelay: Duration = .seconds(10)) async -> DailyAccountRecordingResult {
        var seen = Set<String>()
        var succeeded = 0
        var failed = 0
        // Fetch independently so a stale account cannot delay other midnight baselines.
        let unique = accounts.filter { seen.insert($0.identityKey).inserted }
        await withTaskGroup(of: Bool.self) { group in
            for account in unique {
                group.addTask {
                    for attempt in 0...max(0, retries) {
                        do {
                            let usage = try await fetch(account)
                            guard usage.accountKey == account.identityKey,
                                  try store.record(usage) != nil else { throw CodexAccountError.invalidAccount }
                            return true
                        } catch {
                            if attempt < retries { try? await Task.sleep(for: retryDelay) }
                        }
                    }
                    return false
                }
            }
            for await result in group {
                if result { succeeded += 1 } else { failed += 1 }
            }
        }
        return DailyAccountRecordingResult(succeeded: succeeded, failed: failed)
    }
}
