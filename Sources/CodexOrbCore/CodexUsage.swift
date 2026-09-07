import Foundation
import CryptoKit

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
        public let status: String
        public let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
        }
    }

    public let availableCount: Int
    public let credits: [Credit]

    public var availableExpirations: [Date] {
        credits.filter { $0.status == "available" }.compactMap(\.expiresAt).sorted()
    }

    public var nextExpiration: Date? {
        availableCount > 0 ? availableExpirations.first : nil
    }
}

public struct CodexUsage: Equatable, Sendable {
    public let provider: String
    public let accountKey: String?
    public let legacyAccountKey: String?
    public let session: CodexQuotaWindow?
    public let weekly: CodexQuotaWindow?
    public let resetCredits: CodexResetCredits?
    public let todayTokens: OpenTokenDailyUsage?
    public let updatedAt: Date

    public init(
        provider: String = "codex",
        accountKey: String? = nil,
        legacyAccountKey: String? = nil,
        session: CodexQuotaWindow?,
        weekly: CodexQuotaWindow?,
        todayTokens: OpenTokenDailyUsage? = nil,
        resetCredits: CodexResetCredits? = nil,
        updatedAt: Date)
    {
        self.provider = provider
        self.accountKey = accountKey
        self.legacyAccountKey = legacyAccountKey
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

public enum CodexUsageParserError: LocalizedError, Equatable, Sendable {
    case invalidPayload
    case providerMissing(String)
    case providerError(String)
    case usageMissing

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "CodexBar CLI returned invalid JSON."
        case let .providerMissing(provider):
            "CodexBar CLI output did not contain the \(provider) provider."
        case let .providerError(message):
            message
        case .usageMissing:
            "Codex usage is currently unavailable."
        }
    }
}

public enum CodexUsageParser {
    public static func parse(_ data: Data) throws -> CodexUsage {
        let requestedProvider = "codex"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)

        let payloads: [ProviderPayload]
        if let array = try? decoder.decode([ProviderPayload].self, from: data) {
            payloads = array
        } else if let payload = try? decoder.decode(ProviderPayload.self, from: data) {
            payloads = [payload]
        } else {
            throw CodexUsageParserError.invalidPayload
        }

        guard let payload = payloads.first(where: {
            $0.provider.caseInsensitiveCompare(requestedProvider) == .orderedSame
        })
        else {
            throw CodexUsageParserError.providerMissing(requestedProvider)
        }
        if let error = payload.error {
            throw CodexUsageParserError.providerError(error.message)
        }
        guard let usage = payload.usage else {
            throw CodexUsageParserError.usageMissing
        }

        return CodexUsage(
            provider: payload.provider,
            accountKey: usage.accountEmail.map { email in
                SHA256.hash(data: Data((email.lowercased() + ":" + (usage.loginMethod ?? "")).utf8))
                    .map { String(format: "%02x", $0) }.joined()
            },
            session: usage.primary?.quotaWindow,
            weekly: usage.secondary?.quotaWindow,
            resetCredits: usage.codexResetCredits,
            updatedAt: usage.updatedAt)
    }

    private static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(raw)")
    }
}

private struct ProviderPayload: Decodable {
    let provider: String
    let usage: UsagePayload?
    let error: ErrorPayload?
}

private struct UsagePayload: Decodable {
    let accountEmail: String?
    let loginMethod: String?
    let primary: WindowPayload?
    let secondary: WindowPayload?
    let codexResetCredits: CodexResetCredits?
    let updatedAt: Date
}

private struct WindowPayload: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?
    let resetDescription: String?
    let isSyntheticPlaceholder: Bool?

    var quotaWindow: CodexQuotaWindow? {
        guard self.isSyntheticPlaceholder != true, self.usedPercent.isFinite else { return nil }
        return CodexQuotaWindow(
            usedPercent: self.usedPercent,
            windowMinutes: self.windowMinutes,
            resetsAt: self.resetsAt,
            resetDescription: self.resetDescription)
    }
}

private struct ErrorPayload: Decodable {
    let message: String
}
