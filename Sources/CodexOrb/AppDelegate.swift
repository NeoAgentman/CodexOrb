import AppKit
import CodexOrbCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings
    private var usageSource: CombinedUsageSource
    private let panelController = OrbPanelController()
    private var settingsWindowController: SettingsWindowController?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var lastUsage: CodexUsage?

    override init() {
        let settings = AppSettings.load()
        self.settings = settings
        self.usageSource = CombinedUsageSource(accountHome: settings.accountHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        self.panelController.onRefresh = { [weak self] in
            self?.refresh()
        }
        self.panelController.onSettings = { [weak self] in
            self?.showSettings()
        }
        self.panelController.onQuit = {
            NSApp.terminate(nil)
        }
        CLIUpdateController.shared.onFinished = { [weak self] in self?.refresh() }
        self.panelController.updateDefaultExpansion(
            self.settings.capsuleExpandedByDefault,
            animated: false)
        self.panelController.updateDailyQuota(nil, enabled: self.settings.dailyQuotaEnabled)
        self.panelController.show()
        self.refresh()
        self.scheduleRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        self.refreshTimer?.invalidate()
        self.refreshTask?.cancel()
        self.settingsWindowController?.close()
        self.panelController.close()
    }

    private func refresh() {
        guard self.refreshID == nil else { return }
        let refreshID = UUID()
        self.refreshID = refreshID
        self.panelController.update(.loading(previous: self.lastUsage))
        let usageSource = self.usageSource
        self.refreshTask = Task { [weak self] in
            defer {
                if self?.refreshID == refreshID {
                    self?.refreshID = nil
                    self?.refreshTask = nil
                }
            }
            await withTaskGroup(of: IndependentUsageUpdate.self) { group in
                group.addTask {
                    .quota(await usageSource.fetchQuota())
                }
                group.addTask {
                    .tokens(await usageSource.fetchTokens())
                }

                var errors: [String] = []
                var remainingSources = 2
                for await update in group {
                    guard !Task.isCancelled, self?.refreshID == refreshID else {
                        group.cancelAll()
                        return
                    }
                    remainingSources -= 1
                    switch update {
                    case let .quota(.failure(message)), let .tokens(.failure(message)):
                        errors.append(message)
                    case .quota(.success), .tokens(.success):
                        break
                    }
                    self?.apply(update, errors: errors, isFinal: remainingSources == 0)
                }
            }
        }
    }

    private func apply(_ update: IndependentUsageUpdate, errors: [String], isFinal: Bool) {
        if case let .quota(.success(quota)) = update, self.settings.dailyQuotaEnabled {
            do {
                let daily = try DailyQuotaStore().record(quota)
                self.panelController.updateDailyQuota(
                    Calendar.current.isDateInToday(quota.updatedAt) ? daily : nil, enabled: true)
            } catch {
                self.panelController.updateDailyQuota(nil, enabled: true)
                NSLog("Daily quota recording failed: %@", error.localizedDescription)
            }
        }
        let usage = update.applying(to: self.lastUsage, fallbackProvider: self.settings.provider)

        let errorMessage = errors.joined(separator: "\n")
        guard let usage else {
            if isFinal {
                self.panelController.update(.failed(previous: nil, message: errorMessage))
            }
            return
        }
        self.lastUsage = usage
        if errors.isEmpty {
            self.panelController.update(.available(usage))
        } else {
            self.panelController.update(.partial(usage, message: errorMessage))
        }
    }

    private func scheduleRefreshTimer() {
        self.refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: self.settings.refreshInterval,
            repeats: true)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = min(30, self.settings.refreshInterval * 0.1)
        self.refreshTimer = timer
    }

    private func showSettings() {
        if let settingsWindowController, settingsWindowController.window?.isVisible == true {
            settingsWindowController.present()
            return
        }
        let controller = SettingsWindowController(settings: self.settings) { [weak self] settings in
            try self?.apply(settings)
        }
        self.settingsWindowController = controller
        controller.present()
    }

    private func apply(_ settings: AppSettings) throws {
        try DailyQuotaLaunchAgent.setEnabled(settings.dailyQuotaEnabled, accountHome: settings.accountHome)
        let accountChanged = settings.accountHome != self.settings.accountHome
        if accountChanged || settings.dailyQuotaEnabled != self.settings.dailyQuotaEnabled {
            self.panelController.updateDailyQuota(nil, enabled: settings.dailyQuotaEnabled)
        }
        self.settings = settings
        settings.save()
        self.panelController.updateDefaultExpansion(settings.capsuleExpandedByDefault)
        self.usageSource = CombinedUsageSource(accountHome: settings.accountHome)
        self.scheduleRefreshTimer()

        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.refreshID = nil
        if accountChanged {
            self.lastUsage = nil
            self.panelController.update(.loading(previous: nil))
        }
        self.refresh()
    }
}
