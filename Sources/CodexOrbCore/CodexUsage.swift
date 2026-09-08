import Foundation

public struct CodexQuotaWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - self.usedPercent))
    }
}

public struct CodexResetCredits: Decodable, Equatable, Sendable {
    public struct Credit: Decodable, Equatable, Sendable {
        public let id: String?
        public let status: String
        public let resetType: String?
        public let expiresAt: Date?

        public init(id: String?, status: String, resetType: String?, expiresAt: Date?) {
            self.id = id; self.status = status; self.resetType = resetType; self.expiresAt = expiresAt
        }
        private enum CodingKeys: String, CodingKey {
            case id, status, resetType
            case expiresAt = "expires_at"
        }
        public func isRedeemable(now: Date = Date()) -> Bool {
            id?.isEmpty == false && status == "available" && resetType == "codexRateLimits"
                && (expiresAt.map { $0 > now } ?? true)
        }
    }

    public let availableCount: Int
    public let credits: [Credit]?
    public init(availableCount: Int, credits: [Credit]?) {
        self.availableCount = max(0, availableCount); self.credits = credits
    }
    public var availableCards: [Credit] {
        (credits ?? []).filter { $0.status == "available" }.sorted {
            if $0.expiresAt != $1.expiresAt { return ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            return ($0.id ?? "") < ($1.id ?? "")
        }
    }
    public var availableExpirations: [Date] { availableCards.compactMap(\.expiresAt) }
    public var nextExpiration: Date? { availableCount > 0 ? availableExpirations.first : nil }
}

public struct CodexUsage: Equatable, Sendable {
    public let provider: String
    public let session: CodexQuotaWindow?
    public let weekly: CodexQuotaWindow?
    public let resetCredits: CodexResetCredits?
    public let todayTokens: OpenTokenDailyUsage?
    public let updatedAt: Date

    public init(
        provider: String = "codex",
        session: CodexQuotaWindow?,
        weekly: CodexQuotaWindow?,
        todayTokens: OpenTokenDailyUsage? = nil,
        resetCredits: CodexResetCredits? = nil,
        updatedAt: Date)
    {
        self.provider = provider
        self.session = session
        self.weekly = weekly
        self.todayTokens = todayTokens
        self.resetCredits = resetCredits
        self.updatedAt = updatedAt
    }

    public var bindingRemainingPercent: Double? {
        [self.session, self.weekly]
            .compactMap { $0?.remainingPercent }
            .min()
    }

    public var ringQuota: CodexQuotaWindow? {
        if self.weekly?.windowMinutes == 10_080 { return self.weekly }
        if self.session?.windowMinutes == 10_080 { return self.session }
        return self.weekly ?? self.session
    }

    /// The core five-hour window, independent of which protocol slot contains it;
    public var fiveHourQuota: CodexQuotaWindow? {
        [self.session, self.weekly]
            .compactMap { $0 }
            .first { $0.windowMinutes == 300 }
    }

    public var weeklyPaceDeltaPercent: Double? {
        guard
            let weekly = [self.session, self.weekly]
                .compactMap({ $0 })
                .first(where: { $0.windowMinutes == 10_080 }),
            weekly.remainingPercent > 0,
            let resetsAt = weekly.resetsAt,
            let windowMinutes = weekly.windowMinutes,
            windowMinutes > 0
        else { return nil }

        let duration = TimeInterval(windowMinutes) * 60
        let startedAt = resetsAt.addingTimeInterval(-duration)
        let elapsed = self.updatedAt.timeIntervalSince(startedAt)
        let elapsedFraction = elapsed / duration
        guard elapsedFraction >= 0, elapsedFraction <= 1 else { return nil }
        return weekly.usedPercent - (elapsedFraction * 100)
    }
}
