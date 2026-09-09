import Foundation

public struct OpenTokenToolUsage: Equatable, Sendable {
    public let tool: String
    public let totalTokens: Int64
    public let cacheReadTokens: Int64

    public init(tool: String, totalTokens: Int64, cacheReadTokens: Int64) {
        self.tool = tool
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var combinedTokens: Int64 {
        let result = self.totalTokens.addingReportingOverflow(self.cacheReadTokens)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public struct OpenTokenModelUsage: Equatable, Sendable {
    public let model: String
    public let totalTokens: Int64
    public let cacheReadTokens: Int64

    public init(model: String, totalTokens: Int64, cacheReadTokens: Int64) {
        self.model = model
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public var combinedTokens: Int64 {
        let result = self.totalTokens.addingReportingOverflow(self.cacheReadTokens)
        return result.overflow ? Int64.max : result.partialValue
    }

    public var displayName: String {
        if self.model == "gpt-6-astra" { return "Astra" }
        let prefix = "gpt-5.6-"
        guard self.model.hasPrefix(prefix) else { return self.model }
        return String(self.model.dropFirst(prefix.count))
    }
}

public struct OpenTokenDailyUsage: Equatable, Sendable {
    public let date: String
    public let totalTokens: Int64
    public let inputTokens: Int64
    public let cacheReadTokens: Int64
    public let toolUsages: [OpenTokenToolUsage]
    public let modelUsages: [OpenTokenModelUsage]

    public init(
        date: String,
        totalTokens: Int64,
        cacheReadTokens: Int64,
        inputTokens: Int64 = 0,
        toolUsages: [OpenTokenToolUsage] = [],
        modelUsages: [OpenTokenModelUsage] = [])
    {
        self.date = date
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.toolUsages = toolUsages
        self.modelUsages = modelUsages
    }

    public var combinedTokens: Int64 {
        let result = self.totalTokens.addingReportingOverflow(self.cacheReadTokens)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public enum OpenTokenCLIError: LocalizedError, Equatable, Sendable {
    case executableNotFound
    case launchFailed(String)
    case timedOut
    case outputTooLarge
    case commandFailed(Int32, String)
    case invalidPayload
    case totalOverflow

    public var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "OpenToken CLI is missing. Rebuild or reinstall CodexOrb with its bundled tools."
        case let .launchFailed(message):
            "Could not start OpenToken CLI: \(message)"
        case .timedOut:
            "OpenToken CLI timed out."
        case .outputTooLarge:
            "OpenToken CLI returned too much output."
        case let .commandFailed(_, message):
            message.isEmpty ? "OpenToken CLI failed." : message
        case .invalidPayload:
            "OpenToken CLI returned invalid JSON."
        case .totalOverflow:
            "OpenToken usage total was too large."
        }
    }
}

public enum OpenTokenUsageParser {
    public static func parse(_ data: Data, date: String) throws -> OpenTokenDailyUsage {
        guard let payload = try? JSONDecoder().decode(OpenTokenPayload.self, from: data) else {
            throw OpenTokenCLIError.invalidPayload
        }

        var totalTokens: Int64 = 0
        var inputTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var toolTotals: [String: OpenTokenUsageTotals] = [:]
        var modelTotals: [String: OpenTokenModelTotals] = [:]
        for row in payload.rows where row.date == date {
            let totalResult = totalTokens.addingReportingOverflow(row.normalized)
            let inputResult = inputTokens.addingReportingOverflow(row.input)
            let cacheResult = cacheReadTokens.addingReportingOverflow(row.cacheRead)
            guard !totalResult.overflow, !inputResult.overflow, !cacheResult.overflow else {
                throw OpenTokenCLIError.totalOverflow
            }
            totalTokens = totalResult.partialValue
            inputTokens = inputResult.partialValue
            cacheReadTokens = cacheResult.partialValue

            if let tool = row.tool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
                let current = toolTotals[tool]
                    ?? OpenTokenUsageTotals(totalTokens: 0, cacheReadTokens: 0)
                let toolTotalResult = current.totalTokens.addingReportingOverflow(row.normalized)
                let toolCacheResult = current.cacheReadTokens.addingReportingOverflow(row.cacheRead)
                guard !toolTotalResult.overflow, !toolCacheResult.overflow else {
                    throw OpenTokenCLIError.totalOverflow
                }
                toolTotals[tool] = OpenTokenUsageTotals(
                    totalTokens: toolTotalResult.partialValue,
                    cacheReadTokens: toolCacheResult.partialValue)
            }

            if let model = row.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                let current = modelTotals[model]
                    ?? OpenTokenModelTotals(totalTokens: 0, cacheReadTokens: 0)
                let modelTotalResult = current.totalTokens.addingReportingOverflow(row.normalized)
                let modelCacheResult = current.cacheReadTokens.addingReportingOverflow(row.cacheRead)
                guard !modelTotalResult.overflow, !modelCacheResult.overflow else {
                    throw OpenTokenCLIError.totalOverflow
                }
                modelTotals[model] = OpenTokenModelTotals(
                    totalTokens: modelTotalResult.partialValue,
                    cacheReadTokens: modelCacheResult.partialValue)
            }
        }

        let toolUsages = toolTotals
            .map { tool, totals in
                OpenTokenToolUsage(
                    tool: tool,
                    totalTokens: totals.totalTokens,
                    cacheReadTokens: totals.cacheReadTokens)
            }
            .sorted {
                if $0.combinedTokens == $1.combinedTokens {
                    return $0.tool.localizedStandardCompare($1.tool) == .orderedAscending
                }
                return $0.combinedTokens > $1.combinedTokens
            }

        let modelUsages = modelTotals
            .map { model, totals in
                OpenTokenModelUsage(
                    model: model,
                    totalTokens: totals.totalTokens,
                    cacheReadTokens: totals.cacheReadTokens)
            }
            .sorted {
                if $0.combinedTokens == $1.combinedTokens {
                    return $0.model.localizedStandardCompare($1.model) == .orderedAscending
                }
                return $0.combinedTokens > $1.combinedTokens
            }

        return OpenTokenDailyUsage(
            date: date,
            totalTokens: totalTokens,
            cacheReadTokens: cacheReadTokens,
            inputTokens: inputTokens,
            toolUsages: toolUsages,
            modelUsages: modelUsages)
    }
}

public struct OpenTokenCLIUsageSource: Sendable {
    public static let defaultTimeout: TimeInterval = 20
    public static let maximumOutputBytes = 1_048_576

    private let bundledExecutableDirectory: URL?
    private let environment: [String: String]
    private let timeout: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        bundledExecutableDirectory: URL? = BundledCLITools.directory,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = Self.defaultTimeout,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.bundledExecutableDirectory = bundledExecutableDirectory
        self.environment = environment
        self.timeout = timeout
        self.now = now
    }

    public func fetch() async throws -> OpenTokenDailyUsage {
        try await Task.detached(priority: .utility) {
            try self.fetchBlocking()
        }.value
    }

    private func fetchBlocking() throws -> OpenTokenDailyUsage {
        let date = Self.localDateString(for: self.now())
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = try self.resolveExecutable()
        process.arguments = ["preview", "--since", date, "--json"]
        process.environment = self.environment
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw OpenTokenCLIError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(self.timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw OpenTokenCLIError.timedOut
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= Self.maximumOutputBytes, errorOutput.count <= Self.maximumOutputBytes else {
            throw OpenTokenCLIError.outputTooLarge
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw OpenTokenCLIError.commandFailed(process.terminationStatus, message)
        }

        return try OpenTokenUsageParser.parse(output, date: date)
    }

    private func resolveExecutable() throws -> URL {
        let fileManager = FileManager.default
        if let configuredDirectory = self.bundledExecutableDirectory {
            let directory = configuredDirectory == BundledCLITools.directory
                ? CLIInstallationStore().activeDirectory(for: .opentoken) : configuredDirectory
            let executable = directory.appendingPathComponent("opentoken")
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw OpenTokenCLIError.executableNotFound
            }
            return executable
        }
        let pathCandidates = (self.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("opentoken") }
        let fallbackCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opentoken"),
            URL(fileURLWithPath: "/opt/homebrew/bin/opentoken"),
            URL(fileURLWithPath: "/usr/local/bin/opentoken"),
        ]
        guard let executable = (pathCandidates + fallbackCandidates).first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw OpenTokenCLIError.executableNotFound
        }
        return executable
    }

    private static func localDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct OpenTokenPayload: Decodable {
    let rows: [OpenTokenRow]
}

private struct OpenTokenRow: Decodable {
    let date: String
    let input: Int64
    let normalized: Int64
    let cacheRead: Int64
    let tool: String?
    let model: String?

    private enum CodingKeys: String, CodingKey {
        case date
        case input
        case normalized
        case cacheRead = "cache_read"
        case tool
        case model
    }
}

private struct OpenTokenUsageTotals {
    let totalTokens: Int64
    let cacheReadTokens: Int64
}

private struct OpenTokenModelTotals {
    let totalTokens: Int64
    let cacheReadTokens: Int64
}
