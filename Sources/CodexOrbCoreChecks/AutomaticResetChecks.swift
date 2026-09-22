import CodexOrbCore
import Foundation

enum AutomaticResetChecks {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let policy = AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: 1)
        func card(_ id: String, _ seconds: Double?, status: String = "available", type: String = "codexRateLimits") -> CodexResetCredits.Credit {
            .init(id: id, status: status, resetType: type, expiresAt: seconds.map { now.addingTimeInterval($0) })
        }
        func usage(_ cards: [CodexResetCredits.Credit]?, count: Int? = nil, used: Double = 1,
                   kind: CodexQuotaWindow.Kind = .weekly, age: Double = 0, reset: Double = 86400) -> CodexUsage {
            .init(windows: [.init(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(reset), resetDescription: nil)],
                  resetCredits: .init(availableCount: count ?? cards?.count ?? 1, credits: cards),
                  updatedAt: now.addingTimeInterval(-age))
        }
        func expect(_ condition: Bool, _ message: String) throws { try AppServerChecks.expect(condition, message) }
        let valid = usage([card("later", 7200), card("first", 3600)])
        try expect(policy.candidate(in: valid, now: now)?.id == "first", "exact threshold selects earliest ID")
        try expect(AutomaticResetPolicy().candidate(in: valid, now: now) == nil, "disabled by default")
        try expect(policy.candidate(in: usage([card("soon", 1)]), now: now)?.id == "soon", "under one hour remains eligible")
        try expect(policy.candidate(in: usage([card("late", 3601)]), now: now) == nil, "outside threshold")
        for hours in [1, 12] {
            let p = AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: hours)
            try expect(p.candidate(in: usage([card("edge", Double(hours) * 3600)]), now: now) != nil, "inclusive hour boundaries")
        }
        for hours in [0, 13] {
            try expect(AutomaticResetPolicy(enabled: true, hoursBeforeExpiration: hours).candidate(in: valid, now: now) == nil,
                       "invalid configuration cannot consume")
        }
        for invalid in [
            usage([card("expired", 0)]), usage([card("expired", -1)]), usage([card("unknown", nil)]),
            usage(nil), usage([], count: 1), usage([card("partial", 60)], count: 2),
            usage([card("dup", 60), card("dup", 70)]), usage([card("", 60)]),
            usage([card("used", 60, status: "redeemed")]), usage([card("type", 60, type: "other")]),
            usage([card("full", 60)], used: 0), usage([card("invalid", 60)], used: -1),
            usage([card("invalid", 60)], used: .nan), usage([card("invalid", 60)], used: 101),
            usage([card("missing-week", 60)], kind: .fiveHour), usage([card("stale", 60)], age: 61),
            usage([card("future", 60)], age: -1), usage([card("old-cycle", 60)], reset: 0),
        ] {
            try expect(policy.candidate(in: invalid, now: now) == nil, "unsafe or ineligible snapshot skipped")
        }
        try expect(policy.candidate(in: usage([card("depleted", 60)], used: 100), now: now) != nil, "zero remaining weekly quota is eligible")
        try expect(policy.candidate(in: usage([card("fraction", 60)], used: 0.01), now: now) != nil, "use raw percentage before display rounding")
        print("Automatic reset policy checks passed: time boundaries, weekly semantics, complete inventory and fresh data")
    }
}
