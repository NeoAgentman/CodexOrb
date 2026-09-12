import AppKit
import CodexOrbCore

@main
struct QuotaForecastChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: AppLanguage.chinese.rawValue],
                                               forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain) }

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
        var openedURLs: [URL] = []
        let view = QuotaDetailsView(usage: usage, forecast: forecast, openURL: { openedURLs.append($0) })
        view.appearance = NSAppearance(named: .aqua)
        let labels = Self.descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
            + Self.descendants(of: view).compactMap { ($0 as? NSButton)?.title }
        for expected in ["额度详情", "全局重置预测", "25%", "模型预测", "Tibo承诺", "未知"] {
            precondition(labels.contains(expected), "Missing forecast UI label: \(expected)")
        }
        for forbidden in ["更新时间", "来源", "非个人额度", "实验性", "48 小时内", "45%", "置信度：future-value"] {
            precondition(!labels.contains(forbidden), "Unexpected forecast explanation in compact card: \(forbidden)")
        }
        precondition(view.frame.height > 227.2, "Forecast card did not make room for the compact section")
        let bars = Self.descendants(of: view).filter { !($0 is NSTextField) && !($0 is NSBox) }
        precondition(bars.count >= 6, "Expected two forecast bars in addition to four quota bars")
        let originalHeight = view.frame.height
        let signalURL = URL(string: "https://x.com/thsottiaux/status/2098612714704891959")!
        let committed = CodexResetForecast(probability24h: 45, probability48h: 70, confidence: "low",
                                          updatedAt: Date(), commitmentPercent: 83, officialSignalURL: signalURL)
        for language in AppLanguage.allCases {
            UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: language.rawValue],
                                                   forName: UserDefaults.argumentDomain)
            view.update(usage, forecast: committed)
            view.layoutSubtreeIfNeeded()
            let fields = view.subviews.compactMap { $0 as? NSTextField }
            let buttons = Self.descendants(of: view).compactMap { $0 as? NSButton }
            let translated = fields.map(\.stringValue) + buttons.map(\.title)
            precondition(buttons.count == 2, "Forecast heading and Tibo commitment should open links")
            let heading = buttons.first { $0.title == L10n.text("全局重置预测") }!
            heading.performClick(nil)
            precondition(openedURLs.last == URL(string: "https://codex-reset.com/"),
                         "Forecast heading must open the forecast website")
            let commitment = buttons.first { $0.title == L10n.text("Tibo承诺") }!
            commitment.performClick(nil)
            precondition(openedURLs.last == signalURL, "Commitment click must open official_signal.url")
            for button in buttons {
                precondition(button.intrinsicContentSize.width <= button.frame.width + 1,
                             "Clipped forecast link: \(button.title)")
            }
            for expected in [L10n.text("Tibo承诺"), L10n.text("模型预测"), "83%", "45%"] {
                precondition(translated.contains(expected), "Missing commitment label: \(expected)")
            }
            for forbidden in [L10n.text("48 小时内"), L10n.text("置信度：\("low")"), "70%"] {
                precondition(!translated.contains(forbidden), "Removed forecast label: \(forbidden)")
            }
            precondition(view.frame.height == originalHeight, "Compact forecast height must remain unchanged")
            for field in fields {
                precondition(view.bounds.contains(field.frame), "Label outside card: \(field.stringValue)")
                precondition(field.intrinsicContentSize.width <= field.frame.width + 1,
                             "Clipped label: \(field.stringValue)")
            }
            let preview = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            preview.isReleasedWhenClosed = false
            let canvas = NSView(frame: view.frame)
            canvas.wantsLayer = true
            canvas.layer?.backgroundColor = NSColor.white.cgColor
            preview.contentView = canvas
            let previewContent = QuotaDetailsView(usage: usage, forecast: committed)
            previewContent.appearance = NSAppearance(named: .aqua)
            canvas.addSubview(previewContent)
            preview.orderFront(nil)
            for child in Self.descendants(of: canvas) { child.needsDisplay = true }
            preview.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: "/tmp/orb-forecast-\(language.rawValue).png"))
            preview.close()
        }
        UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: AppLanguage.chinese.rawValue],
                                               forName: UserDefaults.argumentDomain)
        view.update(usage, forecast: forecast)
        let remainingButtons = Self.descendants(of: view).compactMap { $0 as? NSButton }
        precondition(remainingButtons.count == 1 && remainingButtons[0].title == L10n.text("全局重置预测"),
                     "Missing official link must retain only the website heading link")
        remainingButtons[0].performClick(nil)
        precondition(openedURLs.last == URL(string: "https://codex-reset.com/"))
        precondition(view.frame.height == originalHeight, "Missing commitment must preserve compact layout")
        precondition(!Self.descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }.contains("83%"),
                     "Expired commitment left a stale value")

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
        print("Quota forecast UI checks passed: bilingual model and commitment, official link click, missing link fallback, no clipping, fixed height")
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(Self.descendants)
    }
}
