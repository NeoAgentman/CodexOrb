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
        let view = QuotaDetailsView(usage: usage)
        let labels = Self.descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        precondition(labels.contains("额度详情"))
        precondition(!labels.contains("全局重置预测"), "Forecast must move out of quota details")
        precondition(view.frame.height < 227.2, "Removed forecast section must release its space")

        let suite = "CodexOrb.ForecastChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OrbPanelController(defaults: defaults)
        defer { controller.close() }
        controller.update(.available(usage))
        controller.updateForecast(forecast)
        controller.show()
        let capsule = NSApp.windows.first { $0.contentView is OrbView }!
        let forecastPanel = NSApp.windows.first { $0.contentView is ForecastBadgeView }!
        let badges = forecastPanel.contentView as! ForecastBadgeView
        badges.layoutSubtreeIfNeeded()
        precondition(forecastPanel.isVisible, "Forecast is visible even without an account")
        precondition(forecastPanel.frame.minX == capsule.frame.maxX - AccountBadgeLayout.overlap)
        let ordered = badges.subviews.sorted { $0.frame.midY > $1.frame.midY }
        precondition(ordered.count == 2)
        precondition(ordered[0].accessibilityValue() as? String == "25%")
        precondition(ordered[1].accessibilityValue() as? String == "45%")
        precondition(ordered[0].accessibilityLabel()?.contains("24 小时内") == true)
        precondition(ordered[1].accessibilityLabel()?.contains("48 小时内") == true)
        controller.updateForecast(nil)
        precondition(ordered.allSatisfy { $0.accessibilityValue() as? String == "未知" })
        controller.updateForecast(forecast)
        controller.updateDefaultExpansion(true, animated: false)
        precondition(forecastPanel.frame.minX == capsule.frame.maxX - AccountBadgeLayout.overlap)
        let orb = capsule.contentView as! OrbView
        for delta in [CGPoint(x: 10000, y: 0), CGPoint(x: -10000, y: 0)] {
            controller.orbView(orb, didDragBy: delta)
            controller.orbViewDidFinishDragging(orb)
            let screen = capsule.screen!.frame
            precondition(forecastPanel.frame.maxX <= screen.maxX, "Forecast clipped at screen edge")
            precondition(capsule.frame.minX - AccountBadgeLayout.baseSize >= screen.minX,
                         "Account badge needs space at left edge")
        }
        try Self.preview(usage: usage, forecast: forecast)

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
        print("Quota forecast UI checks passed: right-side stacked badges, updates, edge placement and compact details")
    }

    @MainActor private static func preview(usage: CodexUsage, forecast: CodexResetForecast) throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 90))
        let orb = OrbView(frame: NSRect(x: 47, y: 17, width: 176, height: 56))
        orb.displayState = .available(usage)
        let account = AccountBadgeView(frame: NSRect(x: 18, y: 30, width: 30, height: 30))
        account.account = AccountBadgeInfo(email: "h@example.test", workspace: "pro")
        let badges = ForecastBadgeView(frame: ForecastBadgeView.frame(capsuleFrame: orb.frame, scale: 1))
        badges.update(forecast)
        canvas.addSubview(orb)
        canvas.addSubview(account)
        canvas.addSubview(badges)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            canvas.appearance = NSAppearance(named: appearance)
            canvas.layoutSubtreeIfNeeded()
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: "/tmp/codexorb-forecast-badges-\(name).png"))
        }
        window.close()
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
