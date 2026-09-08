import Foundation

public enum UsageRefreshResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

public enum IndependentUsageUpdate: Sendable {
    case quota(UsageRefreshResult<CodexUsage>)
    case tokens(UsageRefreshResult<OpenTokenDailyUsage>)

    public func applying(to previous: CodexUsage?, fallbackProvider: String, now: Date = Date()) -> CodexUsage? {
        switch self {
        case let .quota(.success(quota)):
            return CodexUsage(
                provider: quota.provider,
                session: quota.session,
                weekly: quota.weekly,
                todayTokens: previous?.todayTokens,
                resetCredits: quota.resetCredits,
                updatedAt: quota.updatedAt)
        case let .tokens(.success(tokens)):
            return CodexUsage(
                provider: previous?.provider ?? fallbackProvider,
                session: previous?.session,
                weekly: previous?.weekly,
                todayTokens: tokens,
                resetCredits: previous?.resetCredits,
                updatedAt: previous?.updatedAt ?? now)
        case .quota(.failure), .tokens(.failure):
            return previous
        }
    }
}

public struct UsageRetryPolicy: Sendable {
    public static let standard = UsageRetryPolicy(maxRetries: 3, delayNanoseconds: 5_000_000_000)

    public let maxRetries: Int
    public let delayNanoseconds: UInt64

    public init(maxRetries: Int, delayNanoseconds: UInt64) {
        self.maxRetries = max(0, maxRetries)
        self.delayNanoseconds = delayNanoseconds
    }
}

public struct IndependentUsageRefresh: Sendable {
    public let quota: UsageRefreshResult<CodexUsage>
    public let tokens: UsageRefreshResult<OpenTokenDailyUsage>

    public init(
        quota: UsageRefreshResult<CodexUsage>,
        tokens: UsageRefreshResult<OpenTokenDailyUsage>)
    {
        self.quota = quota
        self.tokens = tokens
    }

    public func merged(
        with previous: CodexUsage?,
        fallbackProvider: String,
        now: Date = Date()) -> MergedUsageRefresh
    {
        var quota = previous
        var tokens = previous?.todayTokens
        var errors: [String] = []
        var refreshedAnySource = false

        switch self.quota {
        case let .success(usage):
            quota = usage
            refreshedAnySource = true
        case let .failure(message):
            errors.append(message)
        }
        switch self.tokens {
        case let .success(usage):
            tokens = usage
            refreshedAnySource = true
        case let .failure(message):
            errors.append(message)
        }

        guard refreshedAnySource else {
            return MergedUsageRefresh(usage: previous, errors: errors, refreshedAnySource: false)
        }
        return MergedUsageRefresh(
            usage: CodexUsage(
                provider: quota?.provider ?? previous?.provider ?? fallbackProvider,
                session: quota?.session,
                weekly: quota?.weekly,
                todayTokens: tokens,
                resetCredits: quota?.resetCredits,
                updatedAt: quota?.updatedAt ?? previous?.updatedAt ?? now),
            errors: errors,
            refreshedAnySource: true)
    }
}

public struct MergedUsageRefresh: Sendable {
    public let usage: CodexUsage?
    public let errors: [String]
    public let refreshedAnySource: Bool

    public init(usage: CodexUsage?, errors: [String], refreshedAnySource: Bool) {
        self.usage = usage
        self.errors = errors
        self.refreshedAnySource = refreshedAnySource
    }
}

public struct CombinedUsageError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { self.message }
}

public struct CombinedUsageSource: CodexUsageSourcing {
    private let quotaSource: any CodexUsageSourcing
    private let openToken: OpenTokenCLIUsageSource
    private let retryPolicy: UsageRetryPolicy

    public init(
        accountHome: String? = nil,
        quotaSource: (any CodexUsageSourcing)? = nil,
        openToken: OpenTokenCLIUsageSource = OpenTokenCLIUsageSource(),
        retryPolicy: UsageRetryPolicy = .standard)
    {
        self.quotaSource = quotaSource ?? CodexAppServerUsageSource(accountHome: accountHome)
        self.openToken = openToken
        self.retryPolicy = retryPolicy
    }

    public func fetch() async throws -> CodexUsage {
        let refresh = await self.fetchIndependently()
        guard case let .success(codex) = refresh.quota else {
            if case let .failure(message) = refresh.quota { throw CombinedUsageError(message: message) }
            throw CombinedUsageError(message: "Codex refresh failed.")
        }
        guard case let .success(tokens) = refresh.tokens else {
            if case let .failure(message) = refresh.tokens { throw CombinedUsageError(message: message) }
            throw CombinedUsageError(message: "OpenToken refresh failed.")
        }
        return Self.combine(codex: codex, tokens: tokens)
    }

    public func fetchIndependently() async -> IndependentUsageRefresh {
        async let quota = self.fetchQuota()
        async let tokens = self.fetchTokens()
        return await IndependentUsageRefresh(quota: quota, tokens: tokens)
    }

    public func fetchQuota() async -> UsageRefreshResult<CodexUsage> {
        await self.fetchWithRetry(sourceName: "Codex") {
            try await self.quotaSource.fetch()
        }
    }

    public func fetchTokens() async -> UsageRefreshResult<OpenTokenDailyUsage> {
        await self.fetchWithRetry(sourceName: "OpenToken") {
            try await self.openToken.fetch()
        }
    }

    private func fetchWithRetry<Value: Sendable>(
        sourceName: String,
        operation: @escaping @Sendable () async throws -> Value) async -> UsageRefreshResult<Value>
    {
        var lastErrorMessage = "Unknown error"
        for attempt in 0 ... self.retryPolicy.maxRetries {
            guard !Task.isCancelled else { return .failure("\(sourceName) refresh was cancelled.") }
            do {
                return .success(try await operation())
            } catch is CancellationError {
                return .failure("\(sourceName) refresh was cancelled.")
            } catch {
                lastErrorMessage = error.localizedDescription
            }

            guard attempt < self.retryPolicy.maxRetries else { break }
            do {
                try await Task<Never, Never>.sleep(nanoseconds: self.retryPolicy.delayNanoseconds)
            } catch {
                return .failure("\(sourceName) refresh was cancelled.")
            }
        }
        let attempts = self.retryPolicy.maxRetries + 1
        return .failure("\(sourceName) failed after \(attempts) attempts: \(lastErrorMessage)")
    }

    private static func combine(codex: CodexUsage, tokens: OpenTokenDailyUsage) -> CodexUsage {
        CodexUsage(
            provider: codex.provider,
            session: codex.session,
            weekly: codex.weekly,
            todayTokens: tokens,
            resetCredits: codex.resetCredits,
            updatedAt: codex.updatedAt)
    }
}
