import AppKit
import OSLog
import CodexOrbCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings
    private var usageSource: CombinedUsageSource
    private let forecastSource = CodexResetForecastSource()
    private let panelController = OrbPanelController()
    private var settingsWindowController: SettingsWindowController?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var lastUsage: CodexUsage?
    private var forecastTask: Task<Void, Never>?
    private var forecastRefreshID: UUID?
    private var resetTask: Task<Void, Never>?
    private var automaticResetTimer: Timer?
    private var automaticResetTask: Task<Void, Never>?
    private var automaticResetGeneration = UUID()
    private var terminating = false
    private var sleeping = false
    private lazy var automaticResetConfirmation = AutomaticResetConfirmation()
    private let automaticResetDismissals = AutomaticResetDismissalStore()
    private let automaticResetLogger = Logger(subsystem: "CodexOrb", category: "AutomaticReset")

    override init() {
        let settings = AppSettings.load()
        self.settings = settings
        self.usageSource = CombinedUsageSource(accountHome: settings.accountHome)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
        self.settings.appearance.apply()
        self.panelController.onRefresh = { [weak self] in
            self?.refresh()
        }
        self.panelController.onSettings = { [weak self] in
            self?.showSettings()
        }
        self.panelController.onAccountListRefresh = { [weak self] in
            self?.updateAccountBadge()
        }
        self.panelController.onAccountSelected = { [weak self] identityKey in
            self?.selectAccount(identityKey: identityKey)
        }
        self.panelController.onConsumeReset = { [weak self] id in self?.consumeReset(id) }
        self.panelController.onDiscardDamagedReset = { [weak self] in self?.discardDamagedReset() }
        self.panelController.onQuit = {
            NSApp.terminate(nil)
        }
        CLIUpdateController.shared.onFinished = { [weak self] in self?.refresh() }
        self.panelController.updateDefaultExpansion(
            self.settings.capsuleExpandedByDefault,
            animated: false)
        self.updateAccountBadge()
        self.panelController.show()
        self.refresh()
        self.scheduleRefreshTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        self.scheduleAutomaticReset()
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = notification
        self.terminating = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        self.automaticResetTimer?.invalidate()
        self.automaticResetTask?.cancel()
        self.refreshTimer?.invalidate()
        self.refreshTask?.cancel()
        self.forecastTask?.cancel()
        self.resetTask?.cancel()
        self.settingsWindowController?.close()
        self.panelController.close()
    }

    private var selectedManagedAccount: CodexAccount? {
        guard let accountHome = self.settings.accountHome else { return nil }
        return CodexAccountStore().managedAccount(at: URL(fileURLWithPath: accountHome))
    }

    private func isCurrentAccount(_ account: CodexAccount) -> Bool {
        self.selectedManagedAccount?.identityKey == account.identityKey
    }

    private func refresh() {
        self.updateResetRecovery()
        self.updateAccountBadge()
        self.refreshForecast()
        guard !terminating, self.refreshID == nil, self.resetTask == nil, automaticResetTask == nil else { return }
        let account = self.selectedManagedAccount
        guard let account else {
            self.lastUsage = nil
            self.panelController.update(.empty)
            return
        }
        let refreshID = UUID()
        self.refreshID = refreshID
        self.panelController.update(.loading(previous: self.lastUsage))
        // Resolve the selected home through the managed-account root on every refresh.
        // This prevents a stale setting from ever falling back to the native Codex home.
        self.usageSource = CombinedUsageSource(accountHome: account.home)
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

    private func refreshForecast() {
        guard self.forecastRefreshID == nil else { return }
        let refreshID = UUID()
        self.forecastRefreshID = refreshID
        let source = self.forecastSource
        let timeZone = TimeZone.current.identifier
        self.forecastTask = Task { [weak self] in
            defer {
                if self?.forecastRefreshID == refreshID {
                    self?.forecastRefreshID = nil
                    self?.forecastTask = nil
                }
            }
            do {
                let forecast = try await source.fetch(timeZone: timeZone)
                guard !Task.isCancelled, self?.forecastRefreshID == refreshID else { return }
                self?.panelController.updateForecast(forecast)
            } catch {
                // Forecast is advisory and independent from account quota state.
                // Keep the last successful value without changing the quota status.
            }
        }
    }

    private func apply(_ update: IndependentUsageUpdate, errors: [String], isFinal: Bool) {
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
            self?.apply(settings)
        }
        self.settingsWindowController = controller
        controller.present()
    }

    private func updateAccountBadge() {
        self.panelController.updateAccounts(
            CodexAccountStore().managedAccounts(),
            selected: self.selectedManagedAccount)
    }

    private func selectAccount(identityKey: String) {
        guard self.resetTask == nil else { return }
        guard let account = CodexAccountStore().managedAccounts().first(where: { $0.identityKey == identityKey }) else {
            self.updateAccountBadge()
            return
        }
        guard account.identityKey != self.selectedManagedAccount?.identityKey else { return }
        var next = self.settings
        next.accountHome = account.home
        self.apply(next)
    }

    private func apply(_ settings: AppSettings) {
        var previousWithPresentation = self.settings
        previousWithPresentation.language = settings.language
        previousWithPresentation.appearance = settings.appearance
        if self.settings.appearance != settings.appearance {
            settings.appearance.apply()
        }
        if previousWithPresentation == settings {
            self.settings = settings
            settings.save()
            self.panelController.reloadLanguage()
            return
        }
        let accountChanged = settings.accountHome != self.settings.accountHome
        self.settings = settings
        settings.save()
        self.panelController.reloadLanguage()
        self.updateAccountBadge()
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
        self.scheduleAutomaticReset()
        self.refresh()
    }

    @objc private func willSleep(_ notification: Notification) {
        sleeping = true
        automaticResetGeneration = UUID()
        automaticResetTask?.cancel()
    }

    @objc private func didWake(_ notification: Notification) {
        sleeping = false
        checkAutomaticReset()
        refresh()
    }

    private func scheduleAutomaticReset() {
        automaticResetGeneration = UUID()
        automaticResetTask?.cancel()
        automaticResetTimer?.invalidate()
        automaticResetTimer = nil
        guard settings.automaticReset.enabled, !terminating else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomaticReset() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        automaticResetTimer = timer
        checkAutomaticReset()
    }

    private func checkAutomaticReset() {
        guard !terminating, !sleeping, settings.automaticReset.enabled,
              automaticResetTask == nil, resetTask == nil else { return }
        let policy = settings.automaticReset
        let accounts = policy.accounts(from: CodexAccountStore().managedAccounts(), selectedHome: settings.accountHome)
        guard !accounts.isEmpty else { return }
        let generation = automaticResetGeneration
        let oldRefresh = refreshTask
        oldRefresh?.cancel()
        refreshTask = nil
        refreshID = nil
        automaticResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.automaticResetTask = nil
                self.updateResetRecovery()
                if generation != self.automaticResetGeneration {
                    self.checkAutomaticReset()
                }
                self.refresh()
            }
            // Drain the cancelled quota process before taking the same account lock.
            await oldRefresh?.value
            var candidates: [(account: CodexAccount, creditID: String, expiration: Date)] = []
            for account in accounts {
                guard !Task.isCancelled, !self.terminating,
                      generation == self.automaticResetGeneration else { return }
                guard CodexAccountStore().managedAccount(at: URL(fileURLWithPath: account.home))?.identityKey == account.identityKey else { continue }
                do {
                    guard try await CodexAccountService.shared.pending(account: account) == nil else { continue }
                    let snapshot = try await CodexAccountService.shared.fetch(account: account)
                    try Task.checkCancellation()
                    guard let candidate = policy.candidate(in: snapshot), let creditID = candidate.id,
                          let expiration = candidate.expiresAt,
                          try !self.automaticResetDismissals.contains(identity: account.identityKey, creditID: creditID) else { continue }
                    candidates.append((account, creditID, expiration))
                } catch is CancellationError {
                    return
                } catch {
                    self.automaticResetLogger.error("Automatic reset check failed for account: \(account.identityKey, privacy: .private)")
                }
            }
            guard !candidates.isEmpty, !Task.isCancelled,
                  generation == self.automaticResetGeneration else { return }
            let decision = await self.automaticResetConfirmation.confirm(items: candidates.map {
                .init(account: $0.account.label, expiresAt: $0.expiration)
            })
            guard !Task.isCancelled, generation == self.automaticResetGeneration else { return }
            for candidate in candidates {
                guard !Task.isCancelled, generation == self.automaticResetGeneration else { return }
                let account = candidate.account
                do {
                    switch decision {
                    case .interrupted: return
                    case .cancel:
                        try self.automaticResetDismissals.dismiss(identity: account.identityKey, creditID: candidate.creditID,
                                                                 expiresAt: candidate.expiration)
                        continue
                    case .use: break
                    }
                    // The countdown authorizes only the listed cards, never replacement candidates.
                    let result = try await CodexAccountService.shared.consumeExpiring(
                        account: account, policy: policy, expectedCreditID: candidate.creditID)
                    if let result {
                        self.automaticResetLogger.info("Automatic reset result: \(result.outcome.rawValue, privacy: .public), account: \(account.identityKey, privacy: .private)")
                        if !Task.isCancelled, self.isCurrentAccount(account), let usage = result.usage {
                            self.apply(.quota(.success(usage)), errors: [], isFinal: true)
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Keep uncertain operations durable for the existing manual recovery UI.
                    // A failed account must not prevent checks for the remaining accounts.
                    self.automaticResetLogger.error("Automatic reset operation failed for account: \(account.identityKey, privacy: .private)")
                }
            }
        }
    }

    private func updateResetRecovery() {
        guard let account = self.selectedManagedAccount else {
            panelController.resetRecoveryAvailable = false
            panelController.resetRecoveryDamaged = false
            return
        }
        switch PendingResetStore().state(account.identityKey) {
        case .none:
            panelController.resetRecoveryAvailable = false
            panelController.resetRecoveryDamaged = false
        case .pending:
            panelController.resetRecoveryAvailable = true
            panelController.resetRecoveryDamaged = false
        case .unreadable:
            panelController.resetRecoveryAvailable = false
            panelController.resetRecoveryDamaged = true
        }
    }

    private func resetMessage(_ message: String, account: CodexAccount? = nil) {
        let alert = NSAlert()
        alert.messageText = L10n.text("重置卡")
        alert.informativeText = (account.map { $0.label + "\n" } ?? "") + message
        alert.addButton(withTitle: L10n.text("确定"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func discardDamagedReset() {
        guard resetTask == nil else { return }
        guard let account = self.selectedManagedAccount else {
            self.updateResetRecovery()
            return
        }
        guard PendingResetStore().state(account.identityKey) == .unreadable else {
            updateResetRecovery()
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("处理损坏的重置记录？")
        alert.informativeText = account.label + "\n" + L10n.text("无法安全恢复这条记录。移出后可以继续使用其他重置卡，原文件会保留。仅在确认没有待恢复操作时继续。")
        alert.addButton(withTitle: L10n.text("取消"))
        let discard = alert.addButton(withTitle: L10n.text("移出记录并继续"))
        discard.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            _ = try PendingResetStore().quarantineUnreadable(account.identityKey)
            updateResetRecovery()
            resetMessage(L10n.text("已移出损坏的重置记录。"), account: account)
        } catch {
            updateResetRecovery()
            resetMessage(L10n.text("无法处理损坏的重置记录。"), account: account)
        }
    }

    private func consumeReset(_ requestedID: String?) {
        guard resetTask == nil else { return }
        guard let account = self.selectedManagedAccount else {
            self.updateResetRecovery()
            return
        }
        let oldAutomaticReset = automaticResetTask
        oldAutomaticReset?.cancel()
        let oldRefresh = refreshTask
        oldRefresh?.cancel()
        refreshTask = nil
        refreshID = nil
        panelController.accountSwitchEnabled = false
        panelController.resetBusy = true
        resetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.resetTask = nil
                self.panelController.accountSwitchEnabled = true
                self.panelController.resetBusy = false
                self.updateResetRecovery()
                self.refresh()
            }
            await oldAutomaticReset?.value
            do {
                let pending = try PendingResetStore().read(account.identityKey)
                let target: String
                if let pending {
                    guard requestedID == nil else {
                        self.resetMessage(L10n.text("请先恢复上次重置操作，再使用其他卡片。"), account: account)
                        return
                    }
                    target = pending.creditID
                } else {
                    guard let requestedID else { return }
                    // The visible snapshot is sufficient to ask. The service validates live after confirmation.
                    guard self.lastUsage?.resetCredits?.availableCards.contains(where: { $0.id == requestedID && $0.isRedeemable() }) == true else {
                        throw AppServerError.cardUnavailable
                    }
                    target = requestedID
                }
                guard self.isCurrentAccount(account) else { throw AppServerError.accountChanged }
                try Task.checkCancellation()
                guard await self.panelController.confirmReset(account: account.label, recovering: pending != nil) else { return }
                guard self.isCurrentAccount(account) else { throw AppServerError.accountChanged }
                // Network and process waits happen only after explicit confirmation.
                await oldRefresh?.value
                try Task.checkCancellation()
                let result = try await CodexAccountService.shared.consume(account: account, creditID: target)
                if let usage = result.usage, self.isCurrentAccount(account),
                   CodexAccountStore().managedAccount(at: URL(fileURLWithPath: account.home))?.identityKey == account.identityKey {
                    self.apply(.quota(.success(usage)), errors: [], isFinal: true)
                }
                let message: String
                switch result.outcome {
                case .reset: message = L10n.text("已消费 1 张重置卡。")
                case .alreadyRedeemed: message = L10n.text("上次操作已成功，没有再次消费。")
                case .nothingToReset: message = L10n.text("当前没有符合条件的额度窗口，未执行重置。")
                case .noCredit: message = L10n.text("账号没有可用的重置卡。")
                }
                self.resetMessage(message + (result.usage == nil ? "\n" + L10n.text("额度刷新失败，请恢复操作以重新查询。") : ""), account: account)
            } catch is CancellationError {
                // A sent operation remains durable and can be recovered after restart.
            } catch {
                let pending = try? await CodexAccountService.shared.pending(account: account)
                let message = pending != nil
                    ? L10n.text("上次重置操作尚待确认，请使用“恢复上次重置操作”，不要重复消费。")
                    : (error as? AppServerError)?.localizedDescription ?? L10n.text("无法完成重置操作，请检查账号或稍后重试。")
                self.resetMessage(message, account: account)
            }
        }
    }
}
