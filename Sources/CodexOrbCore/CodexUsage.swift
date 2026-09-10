import Foundation

public struct CodexQuotaWindow: Equatable, Sendable {
    /// The semantic kind is derived from the server-reported duration, never from
    /// the protocol's primary/secondary slot.
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case fiveHour
        case weekly
        case monthly

        public init?(windowMinutes: Int) {
            switch windowMinutes {
            case 300: self = .fiveHour
            case 10_080: self = .weekly
            case 43_200: self = .monthly
            default: return nil
            }
        }

        public var windowMinutes: Int {
            switch self {
            case .fiveHour: 300
            case .weekly: 10_080
            case .monthly: 43_200
            }
        }
    }

    public let kind: Kind
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetDescription: String?

    public init(
        kind: Kind,
        usedPercent: Double,
        resetsAt: Date?,
        resetDescription: String?)
    {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
    }

    public var windowMinutes: Int { self.kind.windowMinutes }

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
    public let windows: [CodexQuotaWindow]
    public let resetCredits: CodexResetCredits?
    public let todayTokens: OpenTokenDailyUsage?
    public let updatedAt: Date

    public init(
        provider: String = "codex",
        windows: [CodexQuotaWindow] = [],
        todayTokens: OpenTokenDailyUsage? = nil,
        resetCredits: CodexResetCredits? = nil,
        updatedAt: Date)
    {
        self.provider = provider
        // Keep one window per supported kind in a stable display order.
        var unique: [CodexQuotaWindow.Kind: CodexQuotaWindow] = [:]
        for window in windows where unique[window.kind] == nil {
            unique[window.kind] = window
        }
        self.windows = CodexQuotaWindow.Kind.allCases.compactMap { unique[$0] }
        self.todayTokens = todayTokens
        self.resetCredits = resetCredits
        self.updatedAt = updatedAt
    }

    public func quota(for kind: CodexQuotaWindow.Kind) -> CodexQuotaWindow? {
        self.windows.first { $0.kind == kind }
    }

    public var fiveHourQuota: CodexQuotaWindow? { self.quota(for: .fiveHour) }
    public var weeklyQuota: CodexQuotaWindow? { self.quota(for: .weekly) }
    public var monthlyQuota: CodexQuotaWindow? { self.quota(for: .monthly) }

    public var bindingRemainingPercent: Double? {
        self.windows
            .map(\.remainingPercent)
            .min()
    }

    public var ringQuota: CodexQuotaWindow? {
        [.weekly, .fiveHour, .monthly]
            .compactMap { self.quota(for: $0) }
            .first
    }

    public var weeklyPaceDeltaPercent: Double? {
        guard
            let weekly = self.weeklyQuota,
            weekly.remainingPercent > 0,
            let resetsAt = weekly.resetsAt,
            weekly.windowMinutes > 0
        else { return nil }

        let duration = TimeInterval(weekly.windowMinutes) * 60
        let startedAt = resetsAt.addingTimeInterval(-duration)
        let elapsed = self.updatedAt.timeIntervalSince(startedAt)
        let elapsedFraction = elapsed / duration
        guard elapsedFraction >= 0, elapsedFraction <= 1 else { return nil }
        return weekly.usedPercent - (elapsedFraction * 100)
    }
}
