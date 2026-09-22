import Foundation

public struct AutomaticResetPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var hoursBeforeExpiration: Int
    public var allAccounts: Bool

    public init(enabled: Bool = false, hoursBeforeExpiration: Int = 6, allAccounts: Bool = false) {
        self.enabled = enabled
        self.hoursBeforeExpiration = hoursBeforeExpiration
        self.allAccounts = allAccounts
    }

    public func accounts(from managedAccounts: [CodexAccount], selectedHome: String?) -> [CodexAccount] {
        guard enabled else { return [] }
        var seen = Set<String>()
        return managedAccounts.filter {
            (allAccounts || $0.home == selectedHome) && seen.insert($0.identityKey).inserted
        }
    }

    /// Requires a fresh, complete inventory. Unknown details cannot establish the earliest card.
    public func candidate(in usage: CodexUsage, now: Date = Date()) -> CodexResetCredits.Credit? {
        guard enabled, (1...12).contains(hoursBeforeExpiration),
              usage.updatedAt <= now, now.timeIntervalSince(usage.updatedAt) <= 60,
              let weekly = usage.weeklyQuota, weekly.usedPercent.isFinite,
              weekly.usedPercent > 0, weekly.usedPercent <= 100,
              let resetsAt = weekly.resetsAt, resetsAt > now,
              let inventory = usage.resetCredits, inventory.availableCount > 0,
              inventory.availableCards.count == inventory.availableCount else { return nil }
        let cards = inventory.availableCards
        guard cards.allSatisfy({ $0.isRedeemable(now: now) && $0.expiresAt != nil }),
              Set(cards.compactMap(\.id)).count == cards.count,
              let first = cards.first, let expiration = first.expiresAt,
              expiration.timeIntervalSince(now) <= Double(hoursBeforeExpiration) * 3600 else { return nil }
        return first
    }
}
