# CodexOrb

一个原生 macOS 桌面悬浮窗，用于显示 Codex 剩余配额和今天本机 AI 工具的令牌用量。应用基于 macOS SDK 构建。
Codex 配额和重置卡片通过本机安装的 `codex app-server` 获取，并且只使用 CodexOrb 管理的账号。应用内置
OpenToken，用于统计整台机器的本地令牌用量。

## 下载安装（macOS）

1. 打开 [最新发布版本](https://github.com/NeoAgentman/CodexOrb/releases/latest)，下载 `CodexOrb-<版本>-macOS-arm64.zip`。该安装包适用于 **Apple Silicon（M 系列）Mac，macOS 14 或更新版本**；不适用于 Intel Mac。直接安装不需要 Swift 或 Xcode。
2. 双击 ZIP 解压，将 `CodexOrb.app` 拖到 Finder 的「应用程序」（`/Applications`）目录。更新时先从悬浮球右键菜单退出旧版，再替换应用；账号和设置保存在用户资料目录中。
3. 双击「应用程序」中的 CodexOrb。应用以桌面悬浮球运行，**不会显示 Dock 图标或普通主窗口**。

### 首次打开：未签名应用的放行

发布包只有本地 ad-hoc 签名，**没有 Apple Developer ID 签名，也未经 Apple 公证**。首次打开可能提示「无法验证开发者」或「Apple 无法检查其是否包含恶意软件」。确认下载自本仓库发布页后：

1. 尝试打开一次，在拦截提示中选择「完成」或「取消」。
2. 打开「系统设置 → 隐私与安全性」，向下找到 CodexOrb 被阻止的提示，点击「仍要打开」。
3. 按系统要求输入 Mac 登录密码或使用 Touch ID，再确认「打开」。之后可正常双击启动。

以上流程参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

若仍因下载隔离提示「已损坏，无法打开」，先重新下载并核对发布页中的 `SHA256SUMS.txt`。在终端切换到下载文件所在目录运行（将文件名换成实际版本）：

```sh
shasum -a 256 CodexOrb-0.1.1-macOS-arm64.zip
```

确认哈希与发布页一致、应用已放到「应用程序」且信任来源后，仅移除此应用的下载隔离标记，再启动：

```sh
xattr -dr com.apple.quarantine "/Applications/CodexOrb.app"
open "/Applications/CodexOrb.app"
```

如果提示没有权限，可在确认上述路径后为 `xattr` 命令加上 `sudo`，按提示输入 Mac 登录密码（输入时不会显示字符）。无需关闭系统 Gatekeeper 或 SIP。若 macOS 明确报告检测到恶意软件，请不要使用此方法绕过。

### 首次配置与正常使用

1. 确保本机已安装 Codex CLI，或带有兼容 Codex 运行时的 Codex/ChatGPT 桌面应用。CodexOrb 会自动查找并检查兼容性；Codex 运行时不包含在安装包内。
2. 右键悬浮球，打开「设置…」，点击「添加 Codex 账号」，在浏览器完成登录授权。
3. 在「胶囊显示账号」中选择刚添加的账号并保存，等待配额和用量刷新。即使系统中的 Codex 已登录，也需要添加 CodexOrb 自己管理的账号；没有选中账号时悬浮球显示为空。
4. 悬停可展开，拖动可移动，点击配额环查看限额详情，点击令牌数查看用量明细。右键菜单可刷新、打开设置或退出；需要随系统启动时在设置中开启「开机启动」。

配额查询需要联网。OpenToken 已随包附带，令牌统计来自本机 AI 工具日志，代表整台机器的用量，不是所选账号的单独用量。若配额为空或出现橙色状态点，检查网络、所选账号和 Codex 运行时；缺少本地日志时可能没有令牌用量数据。

## 运行要求

- macOS 14 或更高版本
- Swift 6.2 命令行工具（仅构建时需要）
- Codex CLI，或带兼容 Codex 运行时的 Codex/ChatGPT 应用（运行时会探测实际协议架构）
- 基于文件的 Codex OAuth 登录状态，以及查询配额所需的网络连接
- 用于令牌统计的本地 AI 工具用量日志

CodexOrb 会搜索 PATH、`~/.local/bin`、Homebrew 路径以及 Codex/ChatGPT 应用资源。
它会探测实际的 app-server 协议架构并跳过不兼容的候选项，绝不会更新外部 Codex 安装。
每次配额或重置操作都会使用所选托管账号的 `CODEX_HOME` 和 `cli_auth_credentials_store="file"`，
启动一个私有标准输入输出进程，完成后关闭并回收该进程。不会创建模型对话轮次。
读取配额前后都会检查账号身份，也会检查可选的后端账号 ID。
悬浮胶囊及其详情弹窗从不使用系统原生的 `~/.codex` 主目录。没有选中托管账号时，胶囊和弹窗保持为空，
不会回退到原生登录。

```sh
codex app-server --stdio -c 'cli_auth_credentials_store="file"'
opentoken preview --since <today> --json
```

## 源码检出

仓库包含固定版本的 OpenToken 0.3.27 和 SHA256SUMS。CodexBar 及其配套资源已不再打包。
外部 Codex 的 profile-home 配置不用于 CodexOrb 账号管理。`Scripts/import_cli_tools.sh /path/to/opentoken`
是可选的维护者工具。它会校验固定版本和签名并重新生成校验和，不会复制凭据或配置。

## 开发期间运行

```sh
cd CodexOrb
swift run CodexOrb
```

## 测试

```sh
cd CodexOrb
swift run CodexOrbCoreChecks
```

这些检查使用固定的 JSON 测试数据，不会调用真实账号。它们是一个小型可执行程序，而不是 XCTest 应用包，
因此可以在独立安装的命令行工具环境中运行。

要在不查询账号的情况下检查胶囊缩放和鼠标命中区域的缩放：

```sh
./Scripts/check_app_ui.sh
```

## 构建本地应用包

```sh
cd CodexOrb
./Scripts/build_app.sh
open CodexOrb.app
```

OpenToken 位于 `Sources/CodexOrbCore/Resources/Tools`。打包过程会校验校验和，将其复制到
`Contents/Helpers` 并为复制文件签名。已验证的托管更新优先于内置副本；无效的托管更新会回退到内置副本。
缺少内置副本会导致错误。来源信息请参见 `Sources/CodexOrbCore/Resources/Tools/NOTICE.md`。
OpenToken 是应仓库所有者明确要求而纳入的；其再分发条款尚未核实。

`swift run CodexOrbCoreChecks --live-gui-environment` 是使用 app-server 的**选择性实时配额查询**；
它不会消耗重置额度。常规检查只使用本地虚拟账号和虚拟协议对端。

应用包采用本地 ad-hoc 签名，没有 Developer ID 签名或 Apple 公证。下载的发布构建版本需要执行上面的首次打开步骤。
如果使用 Developer ID 签名并完成公证，就不需要手动批准。

应用图标源文件是 `Resources/AppIcon.png`。构建脚本会生成完整的 macOS `.icns` 尺寸集合。

## 操作方式

- 将鼠标悬停在悬浮球内部可展开胶囊，移开鼠标后折叠。可见圆角边缘沿线保留 6 点宽的缩放区域，悬停时会高亮。
- 点击配额环可打开 5 小时和每周剩余配额及重置时间详情。
- 点击重置卡片堆可打开可用的重置卡片。
- 在内部拖动可移动胶囊，拖动边缘可按比例从 100% 缩放到 150%。展开状态最大为 264 × 84 点，折叠状态最大为 90 × 84 点。下次启动时会恢复位置和尺寸。
- 点击令牌总量可打开令牌详情，其中包括全工具总量、缓存读取量和缓存命中率，以及按工具和按模型的明细；右键可刷新、打开设置或退出。
- 折叠状态：显示每周剩余配额和 5 小时剩余配额。配额环上仍保留节奏指示器；每周配额耗尽时隐藏该指示器。
- 展开状态：增加重置额度、包含缓存读取的今日全工具令牌总量和使用量最高的模型。点击令牌总量可查看按工具和按模型的明细。

## 设置

右键点击胶囊并选择**设置…**，可以修改：

- 语言：在中文和英文之间切换界面。
- 胶囊显示账号：只显示 CodexOrb 管理的账号，可选择其他账号并保存。目前只支持 Codex 配额。
- 添加 Codex 账号：通过已安装的 Codex CLI，在 `~/Library/Application Support/CodexOrb/Accounts/` 下的私有主目录中启动浏览器登录。在浏览器完成授权；现有系统登录会保留。登录会在三分钟后超时。
- 刷新账号：只发现 CodexOrb 在 `~/Library/Application Support/CodexOrb/Accounts/` 下创建的账号。这里不会管理或删除原生 `~/.codex` 登录和外部配置。账号标签显示邮箱和套餐；不会显示内部身份键。凭据绝不会复制到应用偏好设置中。
- 自动刷新：1、5、10、15 或 30 分钟，或 1 小时。默认值为 5 分钟。
- 默认展开胶囊：启动后以及鼠标移开时保持胶囊展开。关闭后，胶囊恢复原有的悬停展开行为。
- 开机启动：立即控制 macOS 登录项，独立于保存/取消和账号登录。每次设置页激活时都会读取系统状态；待批准时会显示进入系统登录项设置的链接。
- 更新 CLI：仅更新 OpenToken，失败时保留旧版本。操作会立即执行；关闭设置页也会保留进度。Codex 运行时的安装和更新由外部管理。

保存会在本地持久化账号选择并刷新胶囊。没有选中托管账号时，选择会保存为空。
即使选中了托管账号，OpenToken 总量仍是整台机器的全工具总量，不会归属于所选账号。

CLI 更新存放在 `~/Library/Application Support/CodexOrb/CLI/<tool>/` 下。每次更新都会使用新的暂存目录，
校验候选版本的签名、版本号和实际 JSON 报告，然后以原子方式将该工具的 `current.json` 切换到新的不可变发布目录。
下一次 OpenToken 刷新时会使用新版本。已经在运行的进程仍可使用已有的发布目录；临时暂存目录会移入废纸篓。
独立的文件锁可防止同一工具被并发更新。应用包、全局 CLI 安装和后台服务定义都不会被修改。

OpenToken 的 `self-update` 会在暂存的可执行文件上运行，写入范围限制为暂存目录、临时输出目录和
准确的 `~/.opentoken/update` 缓存目录。签名、版本号和令牌 JSON 校验必须通过后才能启用。
不会调用上传或守护进程操作。基准版本来自 `versions.json`。

Codex app-server 和 OpenToken 会并行刷新，但分别独立写入结果。每个来源先发起一次请求；失败后最多重试三次，
每次重试间隔五秒。某个来源成功后会立即更新界面，另一个来源则继续重试。如果某个来源最终仍然失败，
它会保留上次成功的值，胶囊显示琥珀色状态点。


## 重置卡片与确认

点击已知且可用的卡片后，会立即在胶囊旁打开紧凑的确认框，仅显示问题和账号。实时校验和进程等待会在确认后进行。
**只有“确认”才会授权执行变更。取消、关闭和默认回车键都不会消耗卡片。** 卡片排序时仍会保留卡片 ID。
详情未知、已过期、重置类型不受支持或没有 ID 的卡片都无法兑换。已知且不过期的卡片会与仅显示数量的占位卡片分开显示。

协议调用为 `account/rateLimits/read` 和 `account/rateLimitResetCredit/consume`。
在匹配 300/10080 分钟窗口之前，会先选取 `codex` 配额桶。缺失的数据不会按零用量处理。
账号操作按顺序执行，文件锁会防止多个应用实例之间发生重叠。普通刷新会等待界面的重置操作；
之前所选账号的结果会被丢弃。

发送请求前，会将待处理记录以原子方式保存到
`~/Library/Application Support/CodexOrb/ResetOperations/<identity-hash>/pending.json`.
记录只包含账号身份哈希、卡片 ID、请求 UUID、时间戳和可选结果，绝不包含令牌。关闭应用或丢失响应时会保留相同的 UUID。
“恢复上次重置”需要确认并复用该 UUID，不会创建单独的兑换请求。不要手动删除待处理记录来重试结果不确定的操作。

如果待处理记录无法读取，CodexOrb 会显示独立的损坏记录操作，而不会提供无法成功的恢复选项。
在用户明确确认将损坏记录移出活动路径之前，重置卡片会保持禁用。原始文件会保留在 `ResetOperations/Quarantine` 下；
CodexOrb 从不静默删除它，也不会把它当作已成功恢复的操作。

`reset` 和 `alreadyRedeemed` 是成功结果；`noCredit` 和 `nothingToReset` 不会执行重置。
每个结果之后都会重新读取配额。已知成功但刷新失败时，仍会保留已知成功状态；恢复这一已知结果时只会重新读取配额。
结果不确定时会保留待处理操作，并在确认后使用相同的 UUID 重试，而不是创建另一个兑换请求。
在恢复完成前，其他卡片的兑换会保持禁用。取消无法撤销已经发送的请求。

离线交互检查（不会执行真实兑换）：

```sh
./Scripts/check_app_ui.sh
```
