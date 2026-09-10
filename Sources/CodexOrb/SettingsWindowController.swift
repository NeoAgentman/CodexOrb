import AppKit
import CodexOrbCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: L10n.text("打开系统登录项设置…"), target: nil, action: nil)
    private let providerField = NSPopUpButton()
    private let currentAccountLabel = NSTextField(wrappingLabelWithString: "")
    private let addAccountButton = NSButton(title: L10n.text("添加账号…"), target: nil, action: nil)
    private let deleteAccountButton = NSButton(title: L10n.text("删除账号…"), target: nil, action: nil)
    private let reloadAccountsButton = NSButton(title: L10n.text("刷新账号"), target: nil, action: nil)
    private var accounts: [CodexAccount] = []
    private var pendingAccountRemovals: [CodexAccount] = []
    private var isAddingAccount = false
    private let defaultExpandedToggle = NSButton(checkboxWithTitle: L10n.text("默认展开胶囊"), target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let appearancePopup = NSPopUpButton()
    private let refreshPopup = NSPopUpButton()
    private let validationLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: L10n.text("检查更新"), target: nil, action: nil)
    private let updateSpinner = NSProgressIndicator()
    private let openTokenUpdateLabel = NSTextField(wrappingLabelWithString: "")
    private let updateController = CLIUpdateController.shared
    private let savedAccountHome: String?
    private let onApply: (AppSettings) -> Void

    init(settings: AppSettings, onApply: @escaping (AppSettings) -> Void) {
        self.onApply = onApply
        self.savedAccountHome = settings.accountHome
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 754),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.text("CodexOrb 设置")
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        self.buildContent(settings: settings)
        self.updateController.onChange = { [weak self] in self?.renderCLIUpdates() }
        self.renderCLIUpdates()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        self.renderLaunchAtLogin()
        self.window?.center()
        self.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent(settings: AppSettings) {
        guard let contentView = self.window?.contentView else { return }

        self.languagePopup.addItems(withTitles: ["中文", "English"])
        self.languagePopup.selectItem(at: settings.language == .chinese ? 0 : 1)
        for appearance in AppAppearance.allCases {
            self.appearancePopup.addItem(withTitle: appearance.title)
            self.appearancePopup.lastItem?.representedObject = appearance.rawValue
        }
        self.appearancePopup.selectItem(at: AppAppearance.allCases.firstIndex(of: settings.appearance) ?? 0)
        self.appearancePopup.setAccessibilityLabel(L10n.text("外观"))
        self.currentAccountLabel.font = .systemFont(ofSize: 11)
        self.currentAccountLabel.textColor = .secondaryLabelColor
        self.currentAccountLabel.maximumNumberOfLines = 2
        self.reloadAccounts(selectedHome: settings.accountHome)
        self.addAccountButton.target = self
        self.addAccountButton.action = #selector(self.addAccount(_:))
        self.deleteAccountButton.target = self
        self.deleteAccountButton.action = #selector(self.deleteAccount(_:))
        self.reloadAccountsButton.target = self
        self.reloadAccountsButton.action = #selector(self.reloadAccountsClicked(_:))
        self.providerField.target = self
        self.providerField.action = #selector(self.accountSelectionChanged(_:))
        self.providerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for choice in AppSettings.refreshChoices {
            self.refreshPopup.addItem(withTitle: choice.title)
            self.refreshPopup.lastItem?.representedObject = choice.seconds
        }
        if let index = AppSettings.refreshChoices.firstIndex(where: { $0.seconds == settings.refreshInterval }) {
            self.refreshPopup.selectItem(at: index)
        }
        self.defaultExpandedToggle.state = settings.capsuleExpandedByDefault ? .on : .off
        self.validationLabel.font = .systemFont(ofSize: 11)
        self.validationLabel.textColor = .systemRed
        self.validationLabel.maximumNumberOfLines = 2
        self.updateButton.target = self
        self.updateButton.action = #selector(self.updateCLIs(_:))
        self.updateSpinner.style = .spinning
        self.updateSpinner.controlSize = .small
        self.updateSpinner.isDisplayedWhenStopped = false
        self.openTokenUpdateLabel.font = .systemFont(ofSize: 12)
        self.openTokenUpdateLabel.maximumNumberOfLines = 2

        func text(_ value: String, heading: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = .systemFont(ofSize: heading ? 13 : 11, weight: heading ? .semibold : .regular)
            label.textColor = heading ? .labelColor : .secondaryLabelColor
            return label
        }
        func row(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return stack
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return view
        }
        func section(_ views: [NSView]) -> NSBox {
            let box = NSBox()
            box.boxType = .custom
            box.borderColor = .separatorColor.withAlphaComponent(0.4)
            box.borderWidth = 1
            box.cornerRadius = 10
            box.fillColor = .controlBackgroundColor
            box.contentViewMargins = .zero
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            let container = box.contentView!
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            ])
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return box
        }
        self.launchAtLoginSwitch.target = self
        self.launchAtLoginSwitch.action = #selector(self.toggleLaunchAtLogin(_:))
        self.launchAtLoginSwitch.setAccessibilityLabel(L10n.text("开机启动"))
        self.launchAtLoginStatus.font = .systemFont(ofSize: 11)
        self.launchAtLoginStatus.maximumNumberOfLines = 2
        self.loginSettingsButton.target = self
        self.loginSettingsButton.action = #selector(self.openLoginSettings(_:))
        self.renderLaunchAtLogin()
        let startupSection = section([
            row([text(L10n.text("开机启动"), heading: true), spacer(), self.launchAtLoginSwitch]),
            self.launchAtLoginStatus,
            self.loginSettingsButton,
        ])
        let accountSection = section([
            row([text(L10n.text("Codex 账号"), heading: true), spacer(), self.addAccountButton, self.deleteAccountButton, self.reloadAccountsButton]),
            self.currentAccountLabel,
            self.providerField,
        ])
        let refreshSection = section([
            text(L10n.text("刷新与记录"), heading: true),
            row([NSTextField(labelWithString: L10n.text("自动刷新")), spacer(), self.refreshPopup]),
        ])
        let capsuleSection = section([
            text(L10n.text("胶囊显示"), heading: true),
            row([text(L10n.text("语言"), heading: true), spacer(), self.languagePopup]),
            row([text(L10n.text("外观"), heading: true), spacer(), self.appearancePopup]),
            self.defaultExpandedToggle,
        ])
        let toolsSection = section([
            row([text(L10n.text("工具更新"), heading: true), spacer(), self.updateSpinner, self.updateButton]),
            self.openTokenUpdateLabel,
        ])
        let sections = NSStackView(views: [startupSection, accountSection, capsuleSection, refreshSection, toolsSection])
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 12
        sections.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(sections)
        for section in [startupSection, accountSection, capsuleSection, refreshSection, toolsSection] {
            section.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        }
        let cancelButton = NSButton(title: L10n.text("取消"), target: self, action: #selector(self.cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: L10n.text("保存"), target: self, action: #selector(self.save(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        let buttons = row([cancelButton, saveButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        self.validationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)
        contentView.addSubview(self.validationLabel)
        NSLayoutConstraint.activate([
            sections.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            sections.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            sections.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.widthAnchor.constraint(equalToConstant: 132),
            cancelButton.widthAnchor.constraint(equalToConstant: 62),
            saveButton.widthAnchor.constraint(equalToConstant: 62),
            buttons.topAnchor.constraint(equalTo: sections.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: sections.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            self.validationLabel.leadingAnchor.constraint(equalTo: sections.leadingAnchor),
            self.validationLabel.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -16),
            self.validationLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            self.refreshPopup.widthAnchor.constraint(equalToConstant: 120),
            self.updateSpinner.widthAnchor.constraint(equalToConstant: 16),
            self.updateSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])
        self.fitWindowToContent()
    }

    /// Fit the fixed-width window to the visible rows instead of stretching the first card.
    private func fitWindowToContent() {
        guard let window = self.window, let contentView = window.contentView,
              !contentView.subviews.isEmpty else { return }
        contentView.layoutSubtreeIfNeeded()
        let height = contentView.fittingSize.height
        guard height > 0 else { return }
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: 600, height: height))
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }

    func windowDidBecomeKey(_ notification: Notification) {
        self.renderLaunchAtLogin()
    }

    private func renderLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        self.launchAtLoginSwitch.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        self.loginSettingsButton.isHidden = status != .requiresApproval
        self.launchAtLoginStatus.isHidden = status != .requiresApproval
        self.launchAtLoginStatus.textColor = .secondaryLabelColor
        switch status {
        case .enabled:
            self.launchAtLoginStatus.stringValue = L10n.text("已开启：登录 Mac 后自动启动。此开关立即生效。")
        case .requiresApproval:
            self.launchAtLoginStatus.stringValue = L10n.text("等待系统批准：请在系统登录项设置中允许 CodexOrb。")
        case .notRegistered:
            self.launchAtLoginStatus.stringValue = L10n.text("已关闭：登录 Mac 后不自动启动。此开关立即生效。")
        case .notFound:
            self.launchAtLoginStatus.stringValue = L10n.text("尚未注册开机启动，可打开开关启用。此开关立即生效。")
        @unknown default:
            self.launchAtLoginStatus.stringValue = L10n.text("无法读取登录项状态，请在系统设置中检查。")
        }
        self.fitWindowToContent()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            self.renderLaunchAtLogin()
        } catch {
            self.renderLaunchAtLogin()
            if SMAppService.mainApp.status != .requiresApproval {
                self.launchAtLoginStatus.isHidden = false
                self.launchAtLoginStatus.textColor = .systemRed
                self.launchAtLoginStatus.stringValue = L10n.text("无法更改开机启动：\(error.localizedDescription)")
                self.fitWindowToContent()
            }
        }
    }

    @objc private func openLoginSettings(_ sender: Any?) {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func renderCLIUpdates() {
        self.updateButton.isEnabled = !self.updateController.isRunning
        self.updateButton.title = self.updateController.isRunning ? L10n.text("更新中…") : L10n.text("检查更新")
        if self.updateController.isRunning { self.updateSpinner.startAnimation(nil) }
        else { self.updateSpinner.stopAnimation(nil) }
        for (tool, label) in [(CLITool.opentoken, self.openTokenUpdateLabel)] {
            label.stringValue = L10n.text("\(tool.title)：\(self.updateController.messages[tool] ?? "")")
            label.textColor = self.updateController.failed.contains(tool) ? .systemRed : .secondaryLabelColor
            label.toolTip = label.stringValue
        }
        self.fitWindowToContent()
    }

    @objc private func updateCLIs(_ sender: Any?) {
        self.updateController.start(accountHome: self.savedAccountHome)
    }

    @objc private func save(_ sender: Any?) {
        _ = sender
        let accountHome: String?
        if let selectedHome = self.providerField.selectedItem?.representedObject as? String {
            guard self.accounts.contains(where: { self.normalizedPath($0.home) == self.normalizedPath(selectedHome) }) else {
                self.validationLabel.stringValue = L10n.text("请先添加或登录一个 Codex 账号。")
                return
            }
            accountHome = selectedHome
        } else {
            accountHome = nil
        }
        guard let interval = self.refreshPopup.selectedItem?.representedObject as? TimeInterval else { return }
        guard let appearanceValue = self.appearancePopup.selectedItem?.representedObject as? String,
              let appearance = AppAppearance(rawValue: appearanceValue) else { return }
        let settings = AppSettings(language: self.languagePopup.indexOfSelectedItem == 1 ? .english : .chinese,
                                   appearance: appearance,
                                   accountHome: accountHome,
                                   capsuleExpandedByDefault: self.defaultExpandedToggle.state == .on,
                                   refreshInterval: interval)
        do {
            let store = CodexAccountStore()
            for account in self.pendingAccountRemovals {
                try store.delete(account: account)
            }
        } catch {
            self.validationLabel.textColor = .systemRed
            self.validationLabel.stringValue = L10n.text("删除账号失败，请重试。")
            return
        }
        self.onApply(settings)
        self.close()
    }

    private func reloadAccounts(selectedHome: String?) {
        let removed = Set(self.pendingAccountRemovals.map { self.normalizedPath($0.home) })
        self.accounts = CodexAccountStore().managedAccounts()
            .filter { !removed.contains(self.normalizedPath($0.home)) }
        self.providerField.removeAllItems()
        for account in self.accounts {
            let item = NSMenuItem(title: account.label, action: nil, keyEquivalent: "")
            item.representedObject = account.home
            self.providerField.menu?.addItem(item)
        }
        if let selectedHome,
           let index = self.accounts.firstIndex(where: { self.normalizedPath($0.home) == self.normalizedPath(selectedHome) }) {
            self.providerField.selectItem(at: index)
        } else if !self.accounts.isEmpty {
            self.providerField.insertItem(withTitle: L10n.text("所选账号不可用，请选择或添加账号"), at: 0)
            self.providerField.selectItem(at: 0)
        }
        self.updateAccountSelectionUI()
    }

    @objc private func reloadAccountsClicked(_ sender: Any?) {
        if let selectedHome = self.providerField.selectedItem?.representedObject as? String {
            self.reloadAccounts(selectedHome: selectedHome)
        } else {
            self.reloadAccounts(selectedHome: self.savedAccountHome)
        }
    }

    @objc private func accountSelectionChanged(_ sender: Any?) {
        _ = sender
        self.updateAccountSelectionUI()
    }

    @objc private func deleteAccount(_ sender: Any?) {
        _ = sender
        guard let account = self.selectedAccount() else {
            self.validationLabel.textColor = .systemRed
            self.validationLabel.stringValue = L10n.text("请先选择一个可用账号。")
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.text("删除这个账号？")
        alert.informativeText = account.label + "\n" + L10n.text("将清理该账号的 OAuth 凭据、账号文件和本地重置记录。点击“保存”后完成。")
        alert.addButton(withTitle: L10n.text("取消"))
        let delete = alert.addButton(withTitle: L10n.text("删除账号"))
        delete.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        self.pendingAccountRemovals.removeAll { self.normalizedPath($0.home) == self.normalizedPath(account.home) }
        self.pendingAccountRemovals.append(account)
        let fallback = self.accounts.first { self.normalizedPath($0.home) != self.normalizedPath(account.home) }?.home
        self.reloadAccounts(selectedHome: fallback)
        self.validationLabel.textColor = .secondaryLabelColor
        self.validationLabel.stringValue = L10n.text("账号已移除，点击“保存”完成清理。")
    }

    private func selectedAccount() -> CodexAccount? {
        guard let home = self.providerField.selectedItem?.representedObject as? String else { return nil }
        return self.accounts.first { self.normalizedPath($0.home) == self.normalizedPath(home) }
    }

    private func updateAccountSelectionUI() {
        let account = self.selectedAccount()
        let fallback = self.accounts.isEmpty
            ? L10n.text("暂无 CodexOrb 管理的账号")
            : L10n.text("未登录或账号不可用")
        self.currentAccountLabel.stringValue = L10n.text("当前显示：") + (account?.label ?? fallback)
        self.deleteAccountButton.isEnabled = account != nil && !self.isAddingAccount
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    @objc private func addAccount(_ sender: Any?) {
        guard !self.isAddingAccount else { return }
        guard let executable = CodexRuntime.candidates().first else {
            self.validationLabel.stringValue = CodexAccountError.missingCLI.localizedDescription
            return
        }
        self.isAddingAccount = true
        self.addAccountButton.isEnabled = false
        self.updateAccountSelectionUI()
        self.validationLabel.textColor = .secondaryLabelColor
        self.validationLabel.stringValue = L10n.text("请在浏览器中登录要添加的账号…")
        Task { @MainActor in
            var loginHome: URL?
            defer {
                self.isAddingAccount = false
                self.addAccountButton.isEnabled = true
                self.updateAccountSelectionUI()
            }
            do {
                let home = try CodexAccountStore().createLoginHome()
                loginHome = home
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = home.path
                let result = try await CLIUpdateProcess.run(executable,
                    arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""], timeout: 180,
                    environment: environment)
                guard result.status == 0 else { throw CodexAccountError.loginFailed }
                _ = try CodexAccountStore.read(home: home)
                self.reloadAccounts(selectedHome: home.path)
                self.validationLabel.textColor = .secondaryLabelColor
                self.validationLabel.stringValue = L10n.text("账号已添加，点击“保存” 在胶囊中显示。")
            } catch {
                if let loginHome { try? FileManager.default.trashItem(at: loginHome, resultingItemURL: nil) }
                self.validationLabel.textColor = .systemRed
                self.validationLabel.stringValue = L10n.text("登录未完成，请重试并在浏览器中授权。")
            }
        }
    }

    @objc private func cancel(_ sender: Any?) {
        _ = sender
        self.close()
    }
}
