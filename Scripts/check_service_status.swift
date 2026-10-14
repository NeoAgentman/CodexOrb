import AppKit
import CodexOrbCore

private actor StatusSequence {
    var count = 0
    let healthy: OpenAIServiceStatus
    let issue: OpenAIServiceStatus
    init(healthy: OpenAIServiceStatus, issue: OpenAIServiceStatus) { self.healthy = healthy; self.issue = issue }
    func fetch() throws -> OpenAIServiceStatus {
        count += 1
        if count == 2 { throw URLError(.notConnectedToInternet) }
        return count == 1 ? issue : healthy
    }
}

@main
struct ServiceStatusChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("Service status checks passed: visibility, failure/recovery, lifecycle, positioning, bilingual details"); exit(0) }
            catch { fatalError("Service status checks failed: \(error)") }
        }
        NSApp.run()
    }

    static func fixture(indicator: String = "minor", stage: String = "identified", component: String = "degraded_performance") throws -> OpenAIServiceStatus {
        let data = Data("""
        {"status":{"indicator":"\(indicator)","description":"Partial System Degradation"},
         "components":[{"name":"Codex in ChatGPT Desktop","status":"\(component)"}],
         "incidents":[{"id":"fixture-1","name":"Codex elevated errors","status":"\(stage)","impact":"\(indicator)",
          "updated_at":"2026-10-14T07:05:44Z","incident_updates":[
           {"body":"We are implementing a mitigation. This is a long update that should wrap within the details card without truncation or horizontal scrolling.","created_at":"2026-10-14T07:05:44Z"},
           {"body":"Older update","created_at":"2026-10-14T06:05:44Z"}]}]}
        """.utf8)
        return try JSONDecoder().decode(OpenAIServiceStatus.self, from: data)
    }

    @MainActor static func run() async throws {
        let issue = try fixture()
        // Captured from the operational public endpoint: no incidents key at all.
        let healthyData = try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/openai-status-operational.json"))
        let healthy = try JSONDecoder().decode(OpenAIServiceStatus.self, from: healthyData)
        precondition(healthy.incidents.isEmpty)
        var healthyPayload = try JSONSerialization.jsonObject(with: healthyData) as! [String: Any]
        for emptyIncidents: Any in [NSNull(), [Any]()] {
            healthyPayload["incidents"] = emptyIncidents
            let decoded = try JSONDecoder().decode(OpenAIServiceStatus.self, from: JSONSerialization.data(withJSONObject: healthyPayload))
            precondition(!decoded.hasIssues && decoded.incidents.isEmpty)
        }
        healthyPayload["incidents"] = "invalid"
        do {
            _ = try JSONDecoder().decode(OpenAIServiceStatus.self, from: JSONSerialization.data(withJSONObject: healthyPayload))
            fatalError("Malformed incident lists must not confirm recovery")
        } catch is DecodingError {}
        precondition(issue.hasIssues && !issue.isSevere && !healthy.hasIssues)
        let monitoring = try fixture(indicator: "none", stage: "monitoring", component: "operational")
        precondition(monitoring.hasIssues, "Monitoring must remain visible even if component status has recovered")
        let severe = try fixture(indicator: "major")
        precondition(severe.isSevere)
        precondition(issue.activeIncidents[0].latestUpdate?.body != "Older update")
        do {
            _ = try JSONDecoder().decode(OpenAIServiceStatus.self, from: Data("{\"status\":{\"indicator\":\"none\",\"description\":\"OK\"}}".utf8))
            fatalError("Incomplete responses must not be treated as recovered")
        } catch is DecodingError {}
        let sequence = StatusSequence(healthy: healthy, issue: issue)
        let monitor = ServiceStatusMonitor(interval: .milliseconds(30), fetch: { try await sequence.fetch() })
        var states: [OpenAIServiceStatusState] = []
        monitor.onUpdate = { state in states.append(state) }
        monitor.start()
        for _ in 0..<100 {
            if states.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        monitor.stop()
        precondition(states.count >= 3)
        precondition(states[0].snapshot?.hasIssues == true && !states[0].refreshFailed)
        precondition(states[1].snapshot?.hasIssues == true && states[1].isStale())
        precondition(states[2].snapshot?.hasIssues == false && !states[2].refreshFailed)
        let count = states.count
        try await Task.sleep(for: .milliseconds(70))
        precondition(states.count == count, "Stopped monitor must not publish")
        monitor.start()
        try await Task.sleep(for: .milliseconds(20))
        monitor.stop()
        precondition(states.count > count, "Wake/restart must fetch immediately")
        let slow = ServiceStatusMonitor(fetch: {
            try? await Task.sleep(for: .seconds(5))
            return issue // Even a fetch that ignores cancellation cannot publish late.
        })
        var lateUpdate = false
        slow.onUpdate = { _ in lateUpdate = true }
        slow.start()
        try await Task.sleep(for: .milliseconds(20))
        slow.stop()
        try await Task.sleep(for: .milliseconds(30))
        precondition(!lateUpdate)

        let suite = "CodexOrb.ServiceStatusChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        let controller = OrbPanelController(defaults: defaults)
        controller.show()
        defer { controller.close() }
        let orb = NSApp.windows.compactMap { $0.contentView as? OrbView }.first!
        let badge = NSApp.windows.compactMap { $0 as? ServiceStatusPanel }.first!
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var state = OpenAIServiceStatusState()
        controller.updateServiceStatus(state)
        precondition(!badge.isVisible, "Unknown initial status has no service outage badge")
        state.received(healthy)
        controller.updateServiceStatus(state)
        precondition(!badge.isVisible, "Healthy state must occupy no space")
        state.received(issue)
        controller.updateServiceStatus(state)
        precondition(badge.isVisible && !badge.canBecomeKey && !badge.canBecomeMain)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Badge must not steal focus")
        for expanded in [false, true] {
            controller.updateDefaultExpansion(expanded, animated: false)
            precondition(badge.isVisible && !badge.frame.intersects(orb.window!.frame))
        }
        state.failed()
        controller.updateServiceStatus(state)
        precondition(badge.isVisible && badge.state.isStale())
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain([AppLanguage.defaultsKey: language], forName: UserDefaults.argumentDomain)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                badge.appearance = NSAppearance(named: appearance)
                badge.showDetails()
                precondition(badge.isShowingDetails)
                let details = NSApp.windows.compactMap { $0.contentViewController?.view as? ServiceStatusDetailsView }.first { $0.window?.isVisible == true }!
                let labels = details.documentView!.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                precondition(labels.contains("Codex elevated errors"))
                precondition(labels.contains(language == "en" ? "Identified" : "已定位问题"))
                precondition(labels.contains(language == "en" ? "Status not updated. Showing the last known result." : "信息未更新，以下为上次查询结果"))
                precondition(details.frame.height <= 420 && !details.hasHorizontalScroller)
                let bitmap = details.bitmapImageRepForCachingDisplay(in: details.bounds)!
                details.cacheDisplay(in: details.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/codexorb-status-\(language)-\(appearance.rawValue).png"))
                badge.dismissDetails()
            }
        }
        badge.showDetails()
        state.received(healthy)
        controller.updateServiceStatus(state)
        precondition(!badge.isVisible && !badge.isShowingDetails, "Recovery hides both badge and details")
        let screen = NSRect(x: 0, y: 0, width: 1400, height: 900)
        for scale in [1.0, 1.5] {
            for origin in [NSPoint(x: 10, y: 10), NSPoint(x: 10, y: 800), NSPoint(x: 1100, y: 10), NSPoint(x: 1100, y: 800)] {
                let anchor = NSRect(origin: origin, size: NSSize(width: 176 * scale, height: 56 * scale))
                let account = AccountBadgeLayout.frame(capsuleFrame: anchor, visibleFrame: screen, scale: scale).frame
                let notice = NSRect(x: anchor.midX - 70, y: anchor.maxY + 4, width: 140, height: 38)
                let frame = ServiceStatusPanel.badgeFrame(anchor: anchor, visible: screen, avoiding: [account, notice])
                precondition(screen.contains(frame) && !frame.intersects(anchor) && !frame.intersects(account) && !frame.intersects(notice))
            }
        }
        // Exercise the real source separately only when explicitly requested.
        if CommandLine.arguments.contains("--live-status") {
            let live = try await OpenAIServiceStatusSource().fetch()
            print("Live status: \(live.status.indicator), \(live.activeIncidents.count) active incident(s)")
        }
    }
}
