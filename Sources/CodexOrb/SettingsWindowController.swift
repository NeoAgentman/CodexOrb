import AppKit
import CodexOrbCore
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let launchAtLoginSwitch = NSSwitch()
    private let launchAtLoginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginSettingsButton = NSButton(title: L10n.text("打开系统登录项设置…"), target: nil, action: nil)
    private let dailyQuotaToggle = NSButton(checkboxWithTitle: L10n.text("每天 00:00 记录所有 Codex 账号周额度"), target: nil, action: nil)
    private let providerField = NSPopUpButton()
    private let currentAccountLabel = NSTextField(wrappingLabelWithString: "")
    private let addAccountButton = NSButton(title: L10n.text("添加账号…"), target: nil, action: nil)
    private let reloadAccountsButton = NSButton(title: L10n.text("刷新账号"), target: nil, action: nil)
    private var accounts: [CodexAccount] = []
    private var isAddingAccount = false
    private let defaultExpandedToggle = NSButton(checkboxWithTitle: L10n.text("默认展开胶囊"), target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let refreshPopup = NSPopUpButton()
    private let validationLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: L10n.text("检查更新"), target: nil, action: nil)
    private let updateSpinner = NSProgressIndicator()
    private let codexBarUpdateLabel = NSTextField(wrappingLabelWithString: "")
    private let openTokenUpdateLabel = NSTextField(wrappingLabelWithString: "")
    private let updateController = CLIUpdateController.shared
    private let savedAccountHome: String
    private let onApply: (AppSettings) throws -> Void

    init(settings: AppSettings, onApply: @escaping (AppSettings) throws -> Void) {
        self.onApply = onApply
        self.savedAccountHome = settings.accountHome
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 720),
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
        self.reloadAccounts(selectedHome: settings.accountHome)
        let current = self.accounts.first { $0.home == settings.accountHome }
        self.currentAccountLabel.stringValue = L10n.text("当前显示：") + (current?.label ?? L10n.text("未登录或账号不可用"))
        self.currentAccountLabel.font = .systemFont(ofSize: 11)
        self.currentAccountLabel.textColor = .secondaryLabelColor
        self.currentAccountLabel.maximumNumberOfLines = 2
        self.addAccountButton.target = self
        self.addAccountButton.action = #selector(self.addAccount(_:))
        self.reloadAccountsButton.target = self
        self.reloadAccountsButton.action = #selector(self.reloadAccountsClicked(_:))
        self.providerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for choice in AppSettings.refreshChoices {
            self.refreshPopup.addItem(withTitle: choice.title)
            self.refreshPopup.lastItem?.representedObject = choice.seconds
        }
        if let index = AppSettings.refreshChoices.firstIndex(where: { $0.seconds == settings.refreshInterval }) {
            self.refreshPopup.selectItem(at: index)
        }
        self.dailyQuotaToggle.state = settings.dailyQuotaEnabled ? .on : .off
        self.defaultExpandedToggle.state = settings.capsuleExpandedByDefault ? .on : .off
        self.validationLabel.font = .systemFont(ofSize: 11)
        self.validationLabel.textColor = .systemRed
        self.validationLabel.maximumNumberOfLines = 2
        self.updateButton.target = self
        self.updateButton.action = #selector(self.updateCLIs(_:))
        self.updateSpinner.style = .spinning
        self.updateSpinner.controlSize = .small
        self.updateSpinner.isDisplayedWhenStopped = false
        for label in [self.codexBarUpdateLabel, self.openTokenUpdateLabel] {
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 2
        }

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
            row([text(L10n.text("Codex 账号"), heading: true), spacer(), self.addAccountButton, self.reloadAccountsButton]),
            self.currentAccountLabel,
            self.providerField,
        ])
        let refreshSection = section([
            text(L10n.text("刷新与记录"), heading: true),
            row([NSTextField(labelWithString: L10n.text("自动刷新")), spacer(), self.refreshPopup]),
            self.dailyQuotaToggle,
        ])
        let capsuleSection = section([
            text(L10n.text("胶囊显示"), heading: true),
            row([text(L10n.text("语言"), heading: true), spacer(), self.languagePopup]),
            self.defaultExpandedToggle,
        ])
        let toolsSection = section([
            row([text(L10n.text("工具更新"), heading: true), spacer(), self.updateSpinner, self.updateButton]),
            self.codexBarUpdateLabel,
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
        for (tool, label) in [(CLITool.codexbar, self.codexBarUpdateLabel), (.opentoken, self.openTokenUpdateLabel)] {
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
        let accountHome = self.providerField.selectedItem?.representedObject as? String ?? self.savedAccountHome
        if accountHome != self.savedAccountHome,
           (try? CodexAccountStore.read(home: URL(fileURLWithPath: accountHome))) == nil {
            self.validationLabel.stringValue = L10n.text("请先添加或登录一个 Codex 账号。")
            return
        }
        guard let interval = self.refreshPopup.selectedItem?.representedObject as? TimeInterval else { return }
        let settings = AppSettings(language: self.languagePopup.indexOfSelectedItem == 1 ? .english : .chinese,
                                   dailyQuotaEnabled: self.dailyQuotaToggle.state == .on,
                                   accountHome: accountHome,
                                   capsuleExpandedByDefault: self.defaultExpandedToggle.state == .on,
                                   refreshInterval: interval)
        do {
            try self.onApply(settings)
            self.close()
        } catch {
            self.validationLabel.stringValue = L10n.text("无法更新后台任务，请重试。")
            self.validationLabel.toolTip = error.localizedDescription
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func reloadAccounts(selectedHome: String) {
        self.accounts = CodexAccountStore().accounts(additionalHomes: CodexAccountStore.configuredHomes() + [selectedHome])
        self.providerField.removeAllItems()
        for account in self.accounts {
            let item = NSMenuItem(title: account.label, action: nil, keyEquivalent: "")
            item.representedObject = account.home
            self.providerField.menu?.addItem(item)
        }
        if let index = self.accounts.firstIndex(where: { $0.home == selectedHome }) {
            self.providerField.selectItem(at: index)
        } else {
            self.providerField.insertItem(withTitle: L10n.text("所选账号不可用，请选择或添加账号"), at: 0)
            self.providerField.selectItem(at: 0)
        }
    }

    @objc private func reloadAccountsClicked(_ sender: Any?) {
        self.reloadAccounts(selectedHome: self.providerField.selectedItem?.representedObject as? String ?? self.savedAccountHome)
    }

    @objc private func addAccount(_ sender: Any?) {
        guard !self.isAddingAccount else { return }
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex"]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        guard let executable = (pathCandidates + candidates).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            self.validationLabel.stringValue = CodexAccountError.missingCLI.localizedDescription
            return
        }
        self.isAddingAccount = true
        self.addAccountButton.isEnabled = false
        self.validationLabel.textColor = .secondaryLabelColor
        self.validationLabel.stringValue = L10n.text("请在浏览器中登录要添加的账号…")
        Task { @MainActor in
            var loginHome: URL?
            defer {
                self.isAddingAccount = false
                self.addAccountButton.isEnabled = true
            }
            do {
                let home = try CodexAccountStore().createLoginHome()
                loginHome = home
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = home.path
                let result = try await CLIUpdateProcess.run(URL(fileURLWithPath: executable),
                    arguments: ["login", "-c", "cli_auth_credentials_store=\"file\""], timeout: 180,
                    environment: environment)
                guard result.status == 0 else { throw CodexAccountError.loginFailed }
                _ = try CodexAccountStore.read(home: home)
                self.reloadAccounts(selectedHome: home.path)
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
