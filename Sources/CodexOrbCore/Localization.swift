import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    public static let defaultsKey = "CodexOrb.language"
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .chinese
    }
    public var locale: Locale { Locale(identifier: self.rawValue) }
}

/// Keeps interpolation values separate so saved progress can be rendered in either language.
public enum L10n {
    public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
        public let key: String
        private let arguments: [Message]
        private var isVerbatim = false
        public init(stringLiteral value: String) { key = value; arguments = [] }
        private init(value: String) { key = value; arguments = []; isVerbatim = true }
        public init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key
            arguments = stringInterpolation.arguments
        }
        public struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [Message] = []
            public init(literalCapacity: Int, interpolationCount: Int) {}
            public mutating func appendLiteral(_ literal: String) { key += literal }
            public mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(Message(value: String(describing: value)))
            }
            public mutating func appendInterpolation(_ value: Message) {
                key += "{\(arguments.count)}"
                arguments.append(value)
            }
        }
        public func rendered(in language: AppLanguage = AppLanguage.load()) -> String {
            if isVerbatim { return key }
            let template = language == .english ? (L10n.english[key] ?? key) : key
            // Substitute only template placeholders, never placeholders inside argument values.
            var result = ""
            var remainder = template[...]
            while let open = remainder.firstIndex(of: "{"),
                  let close = remainder[open...].firstIndex(of: "}") {
                result += remainder[..<open]
                if let index = Int(remainder[remainder.index(after: open)..<close]), arguments.indices.contains(index) {
                    result += arguments[index].rendered(in: language)
                } else { result += remainder[open...close] }
                remainder = remainder[remainder.index(after: close)...]
            }
            return result + remainder
        }
    }
    public static func text(_ message: Message) -> String { message.rendered() }
    static let english: [String: String] = [
        "未找到兼容的 Codex，请安装或更新 Codex CLI / Codex App。": "No compatible Codex found. Install or update Codex CLI / Codex App.",
        "Codex 协议请求失败，请刷新或检查登录状态。": "Codex request failed. Refresh or check your sign-in.",
        "Codex 请求超时。": "Codex request timed out.",
        "Codex 连接已中断。": "Codex connection closed.",
        "账号身份已变化，请重新选择账号。": "Account identity changed. Select the account again.",
        "此重置卡已不可用，请刷新。": "This reset card is no longer available. Please refresh.",
        "此账号已有操作正在进行，请稍后重试。": "An operation is already running for this account. Try again shortly.",
        "恢复上次重置操作": "Recover previous reset",
        "长期": "No expiry",
        "无到期时间": "Does not expire",
        "重置卡": "Reset card",
        "确定": "OK",
        "请先恢复上次重置操作，再使用其他卡片。": "Recover the previous reset before using another card.",
        "将核实上次重置操作，复用原请求，不会发起新的独立消费。": "Check the previous reset using its original request. This will not start a separate redemption.",
        "上次操作已有结果，将重新读取额度和卡片。": "The previous outcome is known. Refresh quota and cards.",
        "将消耗 1 张重置卡，重置符合条件的额度窗口。": "Use 1 reset card to reset eligible quota windows.",
        "使用这张重置卡？": "Use this reset card?",
        "恢复上次重置操作？": "Recover the previous reset?",
        "使用 1 张": "Use 1 card",
        "恢复操作": "Recover",
        "已消费 1 张重置卡。": "Used 1 reset card.",
        "上次操作已成功，没有再次消费。": "The previous reset succeeded. No additional card was used.",
        "当前没有符合条件的额度窗口，未执行重置。": "No eligible quota window. No reset was applied.",
        "账号没有可用的重置卡。": "No reset cards available for this account.",
        "额度刷新失败，请恢复操作以重新查询。": "Quota refresh failed. Recover the operation to read it again.",
        "上次重置操作尚待确认，请使用“恢复上次重置操作”，不要重复消费。": "The previous reset needs verification. Use Recover previous reset instead of redeeming again.",
        "无法完成重置操作，请检查账号或稍后重试。": "Could not complete the reset. Check the account or try again later.",
        "Codex：未安装，请安装 Codex CLI 或 Codex App": "Codex: not installed. Install Codex CLI or Codex App.",
        "Codex：使用本机安装，兼容性在连接时检查": "Codex: local installation; compatibility checked on connection.",

        "额度详情": "Quota details",
        "5 小时剩余额度": "5 hour usage limit",
        "5 小时重置剩余时间": "5-hour reset countdown",
        "周剩余额度": "weekly usage limit",
        "周重置剩余时间": "Weekly reset countdown",
        "{0}天 {1}小时 {2}分": "{0}d {1}h {2}m",
        "{0}小时 {1}分": "{0}h {1}m",
        "不足 1 分钟": "Less than 1 minute",
        "等待重置": "Reset due",

        "{0}：{1}": "{0}: {1}",
        "打开系统登录项设置…": "Open Login Items Settings…",
        "添加账号…": "Add Account…",
        "刷新账号": "Reload",
        "默认展开胶囊": "Keep capsule expanded",
        "检查更新": "Check for Updates",
        "CodexOrb 设置": "CodexOrb Settings",
        "当前显示：": "Current account: ",
        "未登录或账号不可用": "Not signed in or account unavailable",
        "开机启动": "Launch at Login",
        "Codex 账号": "Codex Account",
        "刷新与记录": "Refresh & Recording",
        "自动刷新": "Auto-refresh",
        "胶囊显示": "Capsule",
        "工具更新": "Tool Updates",
        "取消": "Cancel",
        "保存": "Save",
        "已开启：登录 Mac 后自动启动。此开关立即生效。": "Enabled: launches when you log in. Changes take effect immediately.",
        "等待系统批准：请在系统登录项设置中允许 CodexOrb。": "Approval required: allow CodexOrb in Login Items settings.",
        "已关闭：登录 Mac 后不自动启动。此开关立即生效。": "Disabled: does not launch at login. Changes take effect immediately.",
        "尚未注册开机启动，可打开开关启用。此开关立即生效。": "Turn on to launch at login. Changes take effect immediately.",
        "无法读取登录项状态，请在系统设置中检查。": "Cannot read login status. Check System Settings.",
        "无法更改开机启动：{0}": "Cannot change login setting: {0}",
        "更新中…": "Updating…",
        "请先添加或登录一个 Codex 账号。": "Add or sign in to a Codex account first.",
        "无法更新后台任务，请重试。": "Cannot update background recording. Please try again.",
        "所选账号不可用，请选择或添加账号": "Account unavailable — select or add an account",
        "请在浏览器中登录要添加的账号…": "Sign in to the account in your browser…",
        "账号已添加，点击“保存” 在胶囊中显示。": "Account added. Click Save to show it in the capsule.",
        "登录未完成，请重试并在浏览器中授权。": "Sign-in incomplete. Try again and authorize in your browser.",
        "刷新": "Refresh",
        "设置…": "Settings…",
        "退出 CodexOrb": "Quit CodexOrb",
        "{0} % {1} 额度剩余": "{0}% {1} quota remaining",
        "{0} % 周用量超出预期": "Weekly usage {0}% above expected",
        "{0} % 周用量低于预期": "Weekly usage {0}% below expected",
        "周用量符合预期": "Weekly usage on track",
        "{0} 今日词元，包含缓存读取": "{0} tokens today, including cache reads",
        "模型：{0}": "Models: {0}",
        "{0} 次可用重置": "{0} resets available",
        "下次重置到期：{0}": "Next reset expires: {0}",
        "用量暂不可用": "Usage unavailable",
        "加载中": "Loading",
        "AI 额度与词元用量": "AI quota and token usage",
        "期限未知": "Unknown expiry",
        "已到期": "Expired",
        "不足1小时": "Expires in <1h",
        "{0}小时到期": "Expires in {0}h",
        "{0}天到期": "Expires in {0}d",
        "可用重置卡片": "Available resets",
        "{0}次可用重置": "{0} resets available",
        "重置信息暂不可用": "Reset information unavailable",
        "第{0}张重置卡，{1}": "Reset {0}, {1}",
        "<1时": "<1h",
        "{0}时": "{0}h",
        "{0}天": "{0}d",
        "未知": "—",
        "暂无": "None",
        "重置卡 · 剩余天数": "Resets · Days left",
        "{0} 次可用": "{0} available",
        "暂不可用": "Unavailable",
        "等待重置信息更新": "Waiting for reset information",
        "暂无可用重置": "No resets available",
        "最近到期": "Next expiry",
        "日期待更新": "Pending",
        "1 分钟": "1 minute",
        "5 分钟": "5 minutes",
        "10 分钟": "10 minutes",
        "15 分钟": "15 minutes",
        "30 分钟": "30 minutes",
        "1 小时": "1 hour",
        "当前版本 {0}": "Current version {0}",
        "检查更新…": "Checking for updates…",
        "另一个更新正在进行": "Another update is in progress",
        "无法写入更新目录": "Cannot write to the update directory",
        "更新版本信息无效": "Invalid update version",
        "无法确认官方更新渠道，请稍后重试": "Cannot verify the official update channel. Try again later",
        "下载文件校验失败": "Download checksum mismatch",
        "更新包内容不完整或不安全": "Update package is incomplete or unsafe",
        "新版运行或数据校验失败": "New version failed validation",
        "更新操作超时": "Update timed out",
        "更新命令输出异常": "Unexpected update command output",
        "{0} · 当前渠道暂无可用更新": "{0} · No updates available on this channel",
        "验证 {0}…": "Validating {0}…",
        "启用 {0}…": "Activating {0}…",
        "已更新：{0} → {1}": "Updated: {0} → {1}",
        "网络或文件操作失败，请重试": "Network or file operation failed. Please try again",
        "{0}；继续使用 {1}": "{0}; continuing with {1}",
        "下载 {0}…": "Downloading {0}…",
        "解压并检查资源…": "Extracting and checking resources…",
        "检查并更新临时副本…": "Checking and updating a temporary copy…",
        "账号登录已失效或尚未完成，请重新登录。": "Account sign-in expired or incomplete. Please sign in again.",
        "未找到 Codex CLI，请先安装 Codex。": "Codex CLI not found. Please install Codex first.",
        "登录未完成，请重试并在浏览器中完成授权。": "Sign-in incomplete. Try again and authorize in your browser.",
        "Codex 额度查询失败，请检查所选账号的登录状态。": "Cannot fetch Codex quota. Check the selected account's sign-in status.",
        "语言": "Language",
    ]
}
