import Foundation
import CodexOrbCore

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
