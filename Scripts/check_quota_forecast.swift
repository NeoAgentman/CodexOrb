import AppKit
import CodexOrbCore

@main
struct QuotaForecastChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let usage = CodexUsage(
            windows: [
                CodexQuotaWindow(kind: .fiveHour, usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), resetDescription: nil),
                CodexQuotaWindow(kind: .weekly, usedPercent: 40, resetsAt: Date().addingTimeInterval(86400), resetDescription: nil),
            ],
            updatedAt: Date())
        let forecast = CodexResetForecast(
            probability24h: 25,
            probability48h: 45,
            confidence: "future-value",
            updatedAt: Date())
        let view = QuotaDetailsView(usage: usage, forecast: forecast)
        let labels = Self.descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        for expected in ["额度详情", "全局重置预测", "25%", "45%", "24 小时内", "48 小时内", "置信度：future-value"] {
            precondition(labels.contains(expected), "Missing forecast UI label: \(expected)")
        }
        for forbidden in ["更新时间", "来源", "非个人额度", "实验性"] {
            precondition(!labels.contains(forbidden), "Unexpected forecast explanation in compact card: \(forbidden)")
        }
        precondition(view.frame.height > 227.2, "Forecast card did not make room for the compact section")
        let bars = Self.descendants(of: view).filter { !($0 is NSTextField) && !($0 is NSBox) }
        precondition(bars.count >= 6, "Expected two forecast bars in addition to four quota bars")

        let monthlyOnly = QuotaDetailsView(usage: CodexUsage(
            windows: [CodexQuotaWindow(kind: .monthly, usedPercent: 35, resetsAt: nil, resetDescription: nil)],
            updatedAt: Date()))
        let monthlyLabels = Self.descendants(of: monthlyOnly).compactMap { ($0 as? NSTextField)?.stringValue }
        precondition(monthlyLabels.contains("30 天剩余额度"), "Monthly quota row is missing")
        for forbidden in ["5 小时剩余额度", "5 小时重置剩余时间", "周剩余额度", "周重置剩余时间", "暂不可用"] {
            precondition(!monthlyLabels.contains(forbidden), "Missing quota must not render a placeholder: \(forbidden)")
        }
        precondition(monthlyOnly.frame.height < 227.2,
                     "Sparse quota card retained the full four-row height")
        print("Quota forecast UI checks passed: compact two-column probabilities and confidence")
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
