import CodexOrbCore
import Foundation

@main
enum CodexOrbCoreChecks {
    static func main() async throws {
        if CommandLine.arguments.contains("--live-gui-environment") {
            try await self.checkLiveGUIEnvironment()
            print("CodexOrb live GUI environment check passed")
            return
        }
        try await AppServerChecks.run()
        try LocalizationChecks.run()
        try await AccountChecks.run()
        try await CLIUpdateChecks.run()
        try await self.checkBundledToolIsolation()
        try self.checkSessionAndWeeklyParsing()
        try self.checkResetCredits()
        try self.checkSingleObjectCompatibility()
        try self.checkSyntheticPlaceholderFiltering()
        self.checkRemainingClamping()
        try self.checkProviderError()
        try await self.checkPATHInvocation()
        try self.checkOpenTokenAggregation()
        try self.checkOpenTokenEmptyDay()
        try await self.checkOpenTokenPATHInvocation()
        try self.checkWeeklyPaceDelta()
        try self.checkEarlyWeeklyPaceDelta()
        try self.checkExhaustedWeeklyPaceDelta()
        try self.checkProviderSelection()
        try self.checkRingQuotaFallback()
        try await self.checkCodexBarFallbackInvocation()
        try self.checkIndependentMerge()
        try await self.checkIndependentSourceFailure()
        try await self.checkRetryPolicy()
        print("CodexOrbCoreChecks passed")
    }

    private static func checkBundledToolIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orb-bundled-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }
        for name in ["codexbar", "opentoken"] {
            let executable = directory.appendingPathComponent(name)
            try Data("#!/bin/sh\necho '{\"rows\":[]}'\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        let tokens = try await OpenTokenCLIUsageSource(bundledExecutableDirectory: directory, environment: ["PATH": ""]).fetch()
        try self.expect(tokens.combinedTokens == 0, "bundled OpenToken without PATH")
        // A missing bundled CLI must not silently invoke a global installation.
        let missing = directory.appendingPathComponent("missing")
        do {
            _ = try await CodexBarCLIUsageSource(bundledExecutableDirectory: missing, environment: ["PATH": directory.path]).fetch()
            throw CheckFailure(message: "missing bundled CodexBar fell back to PATH")
        } catch CodexBarCLIError.executableNotFound { }
        do {
            _ = try await OpenTokenCLIUsageSource(bundledExecutableDirectory: missing, environment: ["PATH": directory.path]).fetch()
            throw CheckFailure(message: "missing bundled OpenToken fell back to PATH")
        } catch OpenTokenCLIError.executableNotFound { }
        for name in ["CodexOrb"] {
            let executable = URL(fileURLWithPath: "/tmp/Relocated Orb.app/Contents/MacOS/\(name)")
            try self.expect(BundledCLITools.appHelpersDirectory(for: executable)?.path == "/tmp/Relocated Orb.app/Contents/Helpers", "relocated app helpers")
        }
    }

    private static func checkResetCredits() throws {
        let json = """
        {"provider":"codex","usage":{"updatedAt":"2026-09-04T00:00:00Z",
        "codexResetCredits":{"availableCount":2,"credits":[
        {"status":"available","expires_at":"2026-09-21T00:29:06Z"},
        {"status":"redeemed","expires_at":"2026-09-05T00:00:00Z"},
        {"status":"available","expires_at":"2026-09-10T00:00:00.123Z"}]}}}
        """
        let usage = try CodexUsageParser.parse(Data(json.utf8))
        try self.expect(usage.resetCredits?.availableCount == 2, "reset inventory count")
        try self.expect(usage.resetCredits?.availableExpirations.count == 2, "exclude redeemed resets")
        let expected = ISO8601DateFormatter()
        expected.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try self.expect(usage.resetCredits?.nextExpiration == expected.date(from: "2026-09-10T00:00:00.123Z"), "nearest available expiry")
        let merged = IndependentUsageRefresh(quota: .success(usage), tokens: .failure("offline"))
            .merged(with: nil, fallbackProvider: "codex")
        try self.expect(merged.usage?.resetCredits == usage.resetCredits, "inventory survives independent merge")
        let tokens = OpenTokenDailyUsage(date: "2026-09-04", totalTokens: 100, cacheReadTokens: 200)
        let quotaUpdate = IndependentUsageUpdate.quota(.success(usage))
        let tokenUpdate = IndependentUsageUpdate.tokens(.success(tokens))
        let firstQuota = quotaUpdate.applying(to: nil, fallbackProvider: "codex")
        try self.expect(firstQuota?.resetCredits == usage.resetCredits, "GUI quota update preserves reset inventory")
        let thenTokens = tokenUpdate.applying(to: firstQuota, fallbackProvider: "codex")
        try self.expect(thenTokens?.resetCredits == usage.resetCredits, "GUI token update preserves reset inventory")
        let firstTokens = tokenUpdate.applying(to: nil, fallbackProvider: "codex")
        let thenQuota = quotaUpdate.applying(to: firstTokens, fallbackProvider: "codex")
        try self.expect(thenQuota?.resetCredits == usage.resetCredits && thenQuota?.todayTokens == tokens, "GUI reverse completion order")
        let zero = try CodexUsageParser.parse(Data(json.replacingOccurrences(of: "availableCount\":2", with: "availableCount\":0").utf8))
        try self.expect(zero.resetCredits?.nextExpiration == nil, "zero inventory has no upcoming expiry")
    }

    private static func checkSessionAndWeeklyParsing() throws {
        let json = """
        [{
          "provider": "codex",
          "source": "codex-cli",
          "usage": {
            "primary": {
              "usedPercent": 28,
              "windowMinutes": 300,
              "resetsAt": "2026-08-30T12:00:00Z"
            },
            "secondary": {
              "usedPercent": 59,
              "windowMinutes": 10080,
              "resetsAt": "2026-09-05T12:00:00.123Z"
            },
            "updatedAt": "2026-08-30T10:00:00Z"
          }
        }]
        """
        let usage = try CodexUsageParser.parse(Data(json.utf8))
        try self.expect(usage.session?.remainingPercent == 72, "session remaining")
        try self.expect(usage.weekly?.remainingPercent == 41, "weekly remaining")
        try self.expect(usage.bindingRemainingPercent == 41, "binding remaining")
        try self.expect(usage.session?.windowMinutes == 300, "session duration")
        try self.expect(usage.fiveHourQuota?.remainingPercent == 72, "five-hour remaining")
        try self.expect(usage.weekly?.windowMinutes == 10080, "weekly duration")
        try self.expect(usage.weekly?.resetsAt != nil, "fractional ISO-8601 date")
    }

    private static func checkSingleObjectCompatibility() throws {
        let json = """
        {
          "provider": "codex",
          "usage": {
            "primary": { "usedPercent": 10 },
            "secondary": null,
            "updatedAt": "2026-08-30T10:00:00Z"
          }
        }
        """
        let usage = try CodexUsageParser.parse(Data(json.utf8))
        try self.expect(usage.session?.remainingPercent == 90, "single-object session")
        try self.expect(usage.weekly == nil, "single-object missing weekly")
        try self.expect(usage.resetCredits == nil, "missing inventory is unknown, not zero")
    }

    private static func checkSyntheticPlaceholderFiltering() throws {
        let json = """
        [{
          "provider": "codex",
          "usage": {
            "primary": { "usedPercent": 0, "isSyntheticPlaceholder": true },
            "secondary": { "usedPercent": 80 },
            "updatedAt": "2026-08-30T10:00:00Z"
          }
        }]
        """
        let usage = try CodexUsageParser.parse(Data(json.utf8))
        try self.expect(usage.session == nil, "synthetic session filtered")
        try self.expect(usage.bindingRemainingPercent == 20, "synthetic binding remaining")
    }

    private static func checkRemainingClamping() {
        let over = CodexQuotaWindow(
            usedPercent: 140,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        let negative = CodexQuotaWindow(
            usedPercent: -20,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil)
        precondition(over.remainingPercent == 0, "over-quota remaining was not clamped")
        precondition(negative.remainingPercent == 100, "negative usage remaining was not clamped")
    }

    private static func checkProviderError() throws {
        let json = """
        [{
          "provider": "codex",
          "source": "cli",
          "usage": null,
          "error": { "code": 1, "message": "Codex is not logged in", "kind": "provider" }
        }]
        """
        do {
            _ = try CodexUsageParser.parse(Data(json.utf8))
            throw CheckFailure(message: "provider error was not surfaced")
        } catch let error as CodexUsageParserError {
            try self.expect(error == .providerError("Codex is not logged in"), "provider error message")
        }
    }

    private static func checkPATHInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexorb-path-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }

        let executable = directory.appendingPathComponent("codexbar")
        let script = """
        #!/bin/sh
        test "$*" = "usage --provider codex --source oauth --format json --json-only" || exit 64
        printf '%s\n' '[{"provider":"codex","usage":{"primary":{"usedPercent":25},"secondary":{"usedPercent":50},"updatedAt":"2026-08-30T10:00:00Z"}}]'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let source = CodexBarCLIUsageSource(bundledExecutableDirectory: nil, environment: ["PATH": directory.path], timeout: 2)
        let usage = try await source.fetch()
        try self.expect(usage.session?.remainingPercent == 75, "PATH session remaining")
        try self.expect(usage.weekly?.remainingPercent == 50, "PATH weekly remaining")
    }

    private static func checkOpenTokenAggregation() throws {
        let json = """
        {
          "rows": [
            {"date":"2026-08-30","tool":"codex","model":"gpt-5.6-sol","normalized":720292,"cache_read":15750912},
            {"date":"2026-08-30","tool":"hermes","model":"gpt-5.6-sol","normalized":8,"cache_read":2},
            {"date":"2026-08-30","tool":"hermes","model":"gpt-5.6-luna","normalized":141297,"cache_read":1414144},
            {"date":"2026-08-30","tool":"workbuddy","model":"glm-5.3-flash","normalized":1448969,"cache_read":18737792},
            {"date":"2026-08-29","tool":"codex","model":"gpt-5.6-sol","normalized":999,"cache_read":999}
          ],
          "sessions": []
        }
        """
        let usage = try OpenTokenUsageParser.parse(Data(json.utf8), date: "2026-08-30")
        try self.expect(usage.totalTokens == 2_310_566, "all-tool daily total")
        try self.expect(usage.cacheReadTokens == 35_902_850, "all-tool cache total")
        try self.expect(usage.combinedTokens == 38_213_416, "all-tool total including cache")
        try self.expect(
            usage.modelUsages.map(\.model) == [
                "glm-5.3-flash",
                "gpt-5.6-sol",
                "gpt-5.6-luna",
            ],
            "models sorted by combined token usage")
        try self.expect(
            usage.modelUsages.map(\.displayName) == ["glm-5.3-flash", "sol", "luna"],
            "model display names")
        try self.expect(
            usage.modelUsages.first(where: { $0.model == "gpt-5.6-sol" })?.combinedTokens == 16_471_214,
            "same-model rows aggregated")
    }

    private static func checkOpenTokenEmptyDay() throws {
        let usage = try OpenTokenUsageParser.parse(Data("{\"rows\":[],\"sessions\":[]}".utf8), date: "2026-08-30")
        try self.expect(usage.totalTokens == 0, "empty daily total")
        try self.expect(usage.cacheReadTokens == 0, "empty cache total")
        try self.expect(usage.combinedTokens == 0, "empty combined total")
        try self.expect(usage.modelUsages.isEmpty, "empty daily models")
    }

    private static func checkOpenTokenPATHInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexorb-opentoken-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }

        let executable = directory.appendingPathComponent("opentoken")
        let script = """
        #!/bin/sh
        test "$*" = "preview --since 2026-08-30 --json" || exit 64
        printf '%s\n' '{"rows":[{"date":"2026-08-30","normalized":200,"cache_read":800}],"sessions":[]}'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let now = ISO8601DateFormatter().date(from: "2026-08-30T10:00:00Z")!
        let source = OpenTokenCLIUsageSource(
            bundledExecutableDirectory: nil,
            environment: ["PATH": directory.path, "TZ": "UTC"],
            timeout: 2,
            now: { now })
        let usage = try await source.fetch()
        try self.expect(usage.combinedTokens == 1_000, "OpenToken PATH combined total")
        try self.expect(usage.modelUsages.isEmpty, "missing model remains compatible")
    }

    private static func checkWeeklyPaceDelta() throws {
        let updatedAt = ISO8601DateFormatter().date(from: "2026-08-03T18:00:00Z")!
        let resetsAt = ISO8601DateFormatter().date(from: "2026-08-09T00:00:00Z")!
        let weekly = CodexQuotaWindow(
            usedPercent: 30,
            windowMinutes: 10_080,
            resetsAt: resetsAt,
            resetDescription: nil)
        let usage = CodexUsage(session: nil, weekly: weekly, updatedAt: updatedAt)
        try self.expect(abs((usage.weeklyPaceDeltaPercent ?? 0) - 5) < 0.001, "weekly pace delta")
    }

    private static func checkEarlyWeeklyPaceDelta() throws {
        let duration = TimeInterval(10_080 * 60)
        let resetsAt = Date(timeIntervalSince1970: 2_000_000)
        let updatedAt = resetsAt.addingTimeInterval(-duration * 0.99)
        let weekly = CodexQuotaWindow(
            usedPercent: 2,
            windowMinutes: 10_080,
            resetsAt: resetsAt,
            resetDescription: nil)
        let usage = CodexUsage(session: nil, weekly: weekly, updatedAt: updatedAt)
        guard let pace = usage.weeklyPaceDeltaPercent else {
            throw CheckFailure(message: "Weekly pace was hidden during the first 3 percent of the cycle")
        }
        try self.expect(abs(pace - 1) < 0.001, "early weekly pace delta")
    }

    private static func checkExhaustedWeeklyPaceDelta() throws {
        let duration = TimeInterval(10_080 * 60)
        let resetsAt = Date(timeIntervalSince1970: 2_000_000)
        let updatedAt = resetsAt.addingTimeInterval(-duration * 0.01)
        for used in [100.0, 101.0] {
            let window = CodexQuotaWindow(usedPercent: used, windowMinutes: 10_080,
                                          resetsAt: resetsAt, resetDescription: nil)
            for usage in [CodexUsage(session: nil, weekly: window, updatedAt: updatedAt),
                          CodexUsage(session: window, weekly: nil, updatedAt: updatedAt)] {
                try self.expect(usage.weeklyPaceDeltaPercent == nil,
                                "Exhausted weekly quota must hide pace, got \(String(describing: usage.weeklyPaceDeltaPercent))")
            }
        }
        let available = CodexQuotaWindow(usedPercent: 99, windowMinutes: 10_080,
                                        resetsAt: resetsAt, resetDescription: nil)
        try self.expect(CodexUsage(session: nil, weekly: available, updatedAt: updatedAt)
            .weeklyPaceDeltaPercent != nil, "Available weekly quota retains pace")
    }

    private static func checkProviderSelection() throws {
        let json = """
        [
          {"provider":"codex","usage":{"primary":{"usedPercent":10},"updatedAt":"2026-08-30T10:00:00Z"}},
          {"provider":"claude","usage":{"primary":{"usedPercent":25},"secondary":{"usedPercent":40,"windowMinutes":10080},"updatedAt":"2026-08-30T10:00:00Z"}}
        ]
        """
        let usage = try CodexUsageParser.parse(Data(json.utf8))
        try self.expect(usage.provider == "codex", "selected provider identity")
        try self.expect(usage.ringQuota?.remainingPercent == 90, "only Codex is selected")
    }

    private static func checkRingQuotaFallback() throws {
        let primary = CodexQuotaWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)
        let usage = CodexUsage(session: primary, weekly: nil, updatedAt: Date())
        try self.expect(usage.ringQuota?.remainingPercent == 65, "primary ring fallback")
    }

    private static func checkCodexBarFallbackInvocation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexorb-codexbar-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }

        let executable = directory.appendingPathComponent("codexbar")
        let script = """
        #!/bin/sh
        test "$*" = "usage --provider codex --source oauth --format json --json-only" || exit 64
        printf '%s\n' '[{"provider":"codex","usage":{"primary":{"usedPercent":20},"secondary":{"usedPercent":30,"windowMinutes":10080},"updatedAt":"2026-08-30T10:00:00Z"}}]'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let source = CodexBarCLIUsageSource(
            bundledExecutableDirectory: nil,
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            timeout: 2,
            additionalExecutableDirectories: [directory])
        let usage = try await source.fetch()
        try self.expect(usage.ringQuota?.remainingPercent == 70, "CodexBar fallback directory")
    }

    private static func checkLiveGUIEnvironment() async throws {
        let usage = try await CodexAppServerUsageSource().fetch()
        try self.expect(usage.fiveHourQuota != nil || usage.weekly != nil, "live Codex windows")
    }

    private static func checkIndependentMerge() throws {
        let previousTokens = OpenTokenDailyUsage(date: "2026-08-30", totalTokens: 100, cacheReadTokens: 900)
        let previous = CodexUsage(
            session: nil,
            weekly: CodexQuotaWindow(
                usedPercent: 50,
                windowMinutes: 10_080,
                resetsAt: nil,
                resetDescription: nil),
            todayTokens: previousTokens,
            updatedAt: Date(timeIntervalSince1970: 1))
        let refreshedQuota = CodexUsage(
            session: nil,
            weekly: CodexQuotaWindow(
                usedPercent: 20,
                windowMinutes: 10_080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 2))

        let quotaOnly = IndependentUsageRefresh(
            quota: .success(refreshedQuota),
            tokens: .failure("OpenToken failed"))
            .merged(with: previous, fallbackProvider: "codex")
        try self.expect(quotaOnly.usage?.ringQuota?.remainingPercent == 80, "independent quota refresh")
        try self.expect(quotaOnly.usage?.todayTokens == previousTokens, "stale token preservation")
        try self.expect(quotaOnly.errors.count == 1, "partial refresh error")

        let refreshedTokens = OpenTokenDailyUsage(date: "2026-08-30", totalTokens: 200, cacheReadTokens: 1_800)
        let tokensOnly = IndependentUsageRefresh(
            quota: .failure("CodexBar failed"),
            tokens: .success(refreshedTokens))
            .merged(with: previous, fallbackProvider: "codex")
        try self.expect(tokensOnly.usage?.ringQuota?.remainingPercent == 50, "stale quota preservation")
        try self.expect(tokensOnly.usage?.todayTokens == refreshedTokens, "independent token refresh")
    }

    private static func checkIndependentSourceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexorb-independent-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }

        let codexbar = directory.appendingPathComponent("codexbar")
        let codexbarScript = """
        #!/bin/sh
        printf '%s\n' '[{"provider":"codex","usage":{"secondary":{"usedPercent":25,"windowMinutes":10080},"updatedAt":"2026-08-30T10:00:00Z"}}]'
        """
        try Data(codexbarScript.utf8).write(to: codexbar)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexbar.path)

        let opentoken = directory.appendingPathComponent("opentoken")
        try Data("#!/bin/sh\necho 'fixture failure' >&2\nexit 42\n".utf8).write(to: opentoken)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opentoken.path)

        let environment = ["PATH": directory.path]
        let source = CombinedUsageSource(
            quotaSource: CodexBarCLIUsageSource(bundledExecutableDirectory: nil, environment: environment, timeout: 2),
            openToken: OpenTokenCLIUsageSource(bundledExecutableDirectory: nil, environment: environment, timeout: 2),
            retryPolicy: UsageRetryPolicy(maxRetries: 3, delayNanoseconds: 0))
        let refresh = await source.fetchIndependently()
        guard case let .success(quota) = refresh.quota else {
            throw CheckFailure(message: "CodexBar success was lost when OpenToken failed")
        }
        try self.expect(quota.ringQuota?.remainingPercent == 75, "independent source quota result")
        guard case .failure = refresh.tokens else {
            throw CheckFailure(message: "OpenToken failure was not isolated")
        }
    }

    private static func checkRetryPolicy() async throws {
        try self.expect(UsageRetryPolicy.standard.maxRetries == 3, "standard retry count")
        try self.expect(
            UsageRetryPolicy.standard.delayNanoseconds == 5_000_000_000,
            "standard retry delay")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexorb-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) }

        let counter = directory.appendingPathComponent("attempts")
        let codexbar = directory.appendingPathComponent("codexbar")
        let script = """
        #!/bin/sh
        count=0
        if [ -f "\(counter.path)" ]; then count=$(/bin/cat "\(counter.path)"); fi
        count=$((count + 1))
        printf '%s' "$count" > "\(counter.path)"
        if [ "$count" -lt 4 ]; then
          echo 'transient fixture failure' >&2
          exit 42
        fi
        printf '%s\n' '[{"provider":"codex","usage":{"secondary":{"usedPercent":25,"windowMinutes":10080},"updatedAt":"2026-08-30T10:00:00Z"}}]'
        """
        try Data(script.utf8).write(to: codexbar)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexbar.path)

        let source = CombinedUsageSource(
            quotaSource: CodexBarCLIUsageSource(bundledExecutableDirectory: nil, environment: ["PATH": directory.path], timeout: 2),
            retryPolicy: UsageRetryPolicy(maxRetries: 3, delayNanoseconds: 0))
        let result = await source.fetchQuota()
        guard case let .success(quota) = result else {
            throw CheckFailure(message: "CodexBar did not recover on the third retry")
        }
        try self.expect(quota.ringQuota?.remainingPercent == 75, "retry result")
        let attempts = try String(contentsOf: counter, encoding: .utf8)
        try self.expect(attempts == "4", "initial attempt plus three retries")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw CheckFailure(message: "Failed check: \(label)") }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { self.message }
}
