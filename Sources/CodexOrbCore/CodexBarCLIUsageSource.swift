import Foundation

public protocol CodexUsageSourcing: Sendable {
    func fetch() async throws -> CodexUsage
}

public enum CodexBarCLIError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case outputTooLarge
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "CodexBar CLI is missing. Rebuild or reinstall CodexOrb with its bundled tools."
        case let .launchFailed(message):
            "Could not start CodexBar CLI: \(message)"
        case .timedOut:
            "CodexBar CLI timed out."
        case .outputTooLarge:
            "CodexBar CLI returned too much output."
        case let .commandFailed(_, message):
            message.isEmpty ? "CodexBar CLI failed." : message
        }
    }
}

public struct CodexBarCLIUsageSource: CodexUsageSourcing {
    public static let defaultTimeout: TimeInterval = 20
    public static let maximumOutputBytes = 1_048_576

    private let bundledExecutableDirectory: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let accountHome: String?
    private let additionalExecutableDirectories: [URL]

    public init(
        accountHome: String? = nil,
        bundledExecutableDirectory: URL? = BundledCLITools.directory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = Self.defaultTimeout,
        additionalExecutableDirectories: [URL] = [])
    {
        self.accountHome = accountHome
        self.bundledExecutableDirectory = bundledExecutableDirectory
        self.environment = environment
        self.timeout = timeout
        self.additionalExecutableDirectories = additionalExecutableDirectories
    }

    public func fetch() async throws -> CodexUsage {

        var environment = self.environment
        var account: CodexAccount?
        if let home = self.accountHome {
            account = try CodexAccountStore.read(home: URL(fileURLWithPath: home))
            environment["CODEX_HOME"] = home
        }
        let result = try await CLIUpdateProcess.run(self.resolveExecutable(), arguments: [
            "usage", "--provider", "codex", "--source", "oauth", "--format", "json", "--json-only",
        ], timeout: self.timeout, environment: environment)
        guard result.status == 0 else {
            throw CodexBarCLIError.commandFailed(result.status, L10n.text("Codex 额度查询失败，请检查所选账号的登录状态。"))
        }
        let usage = try CodexUsageParser.parse(result.stdout)
        if let account {
            let current = try CodexAccountStore.read(home: URL(fileURLWithPath: account.home))
            guard current.identityKey == account.identityKey else { throw CodexAccountError.invalidAccount }
        }
        // The old journal used email + plan. Migrate only when this email has one known workspace.
        let sameEmailAccounts = account.map { selected in
            CodexAccountStore().accounts(additionalHomes: CodexAccountStore.configuredHomes() + [selected.home])
                .filter { $0.email.caseInsensitiveCompare(selected.email) == .orderedSame }
        } ?? []
        let canMigrate = Set(sameEmailAccounts.map(\.identityKey)).count == 1
        return CodexUsage(provider: "codex", accountKey: account?.identityKey ?? usage.accountKey,
                          legacyAccountKey: canMigrate ? usage.accountKey : nil,
                          session: usage.session, weekly: usage.weekly, resetCredits: usage.resetCredits,
                          updatedAt: usage.updatedAt)
    }

    private func resolveExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let configuredDirectory = self.bundledExecutableDirectory {
            let directory = configuredDirectory == BundledCLITools.directory
                ? CLIInstallationStore().activeDirectory(for: .codexbar) : configuredDirectory
            let executable = directory.appendingPathComponent("codexbar")
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw CodexBarCLIError.executableNotFound
            }
            return executable
        }
        let pathCandidates = (self.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codexbar") }
        let injectedCandidates = self.additionalExecutableDirectories.map {
            $0.appendingPathComponent("codexbar")
        }
        let fallbackCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/codexbar"),
            URL(fileURLWithPath: "/usr/local/bin/codexbar"),
            URL(fileURLWithPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"),
        ]
        guard let executable = (pathCandidates + injectedCandidates + fallbackCandidates).first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw CodexBarCLIError.executableNotFound
        }
        return executable
    }
}
