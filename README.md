# CodexOrb

A small native macOS floating window that displays Codex quota remaining and today's local AI token usage. It is
built with the macOS SDK. Codex quota and reset cards use a locally installed `codex app-server` and only a
CodexOrb-managed account. OpenToken is bundled for machine-wide local token statistics.

## 下载安装（macOS）

1. 打开 [最新 Release](https://github.com/NeoAgentman/CodexOrb/releases/latest)，下载 `CodexOrb-<版本>-macOS-arm64.zip`。该安装包适用于 **Apple Silicon（M 系列）Mac，macOS 14 或更新版本**；不适用于 Intel Mac。直接安装不需要 Swift 或 Xcode。
2. 双击 ZIP 解压，将 `CodexOrb.app` 拖到 Finder 的「应用程序」（`/Applications`）目录。更新时先从悬浮球右键菜单退出旧版，再替换应用；账号和设置保存在用户资料目录中。
3. 双击「应用程序」中的 CodexOrb。应用以桌面悬浮球运行，**不会显示 Dock 图标或普通主窗口**。

### 首次打开：未签名应用的放行

发布包只有本地 ad-hoc 签名，**没有 Apple Developer ID 签名，也未经 Apple 公证**。首次打开可能提示「无法验证开发者」或「Apple 无法检查其是否包含恶意软件」。确认下载自本仓库 Release 后：

1. 尝试打开一次，在拦截提示中选择「完成」或「取消」。
2. 打开「系统设置 → 隐私与安全性」，向下找到 CodexOrb 被阻止的提示，点击「仍要打开」（Open Anyway）。
3. 按系统要求输入 Mac 登录密码或使用 Touch ID，再确认「打开」。之后可正常双击启动。

以上流程参见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

若仍因下载隔离提示「已损坏，无法打开」，先重新下载并核对 Release 中的 `SHA256SUMS.txt`。在终端切换到下载文件所在目录运行（将文件名换成实际版本）：

```sh
shasum -a 256 CodexOrb-0.1.0-macOS-arm64.zip
```

确认哈希与 Release 一致、应用已放到「应用程序」且信任来源后，仅移除此应用的下载隔离标记，再启动：

```sh
xattr -dr com.apple.quarantine "/Applications/CodexOrb.app"
open "/Applications/CodexOrb.app"
```

如果提示没有权限，可在确认上述路径后为 `xattr` 命令加上 `sudo`，按提示输入 Mac 登录密码（输入时不会显示字符）。无需关闭系统 Gatekeeper 或 SIP。若 macOS 明确报告检测到恶意软件，请不要使用此方法绕过。

### 首次配置与正常使用

1. 确保本机已安装 Codex CLI，或带有兼容 Codex runtime 的 Codex/ChatGPT 桌面应用。CodexOrb 会自动查找并检查兼容性；Codex runtime 不包含在安装包内。
2. 右键悬浮球，打开「设置 / Settings…」，点击「添加 Codex 账号」，在浏览器完成登录授权。
3. 在「胶囊显示账号」中选择刚添加的账号并保存，等待配额和用量刷新。即使系统中的 Codex 已登录，也需要添加 CodexOrb 自己管理的账号；没有选中账号时悬浮球显示为空。
4. 悬停可展开，拖动可移动，点击配额环查看限额详情，点击 token 数查看用量明细。右键菜单可刷新、打开设置或退出；需要随系统启动时在设置中开启「开机启动」。

配额查询需要联网。OpenToken 已随包附带，token 统计来自本机 AI 工具日志，代表整台机器的用量，不是所选账号的单独用量。若配额为空或出现橙色状态点，检查网络、所选账号和 Codex runtime；缺少本地日志时可能没有 token 用量数据。

## Requirements

- macOS 14 or newer
- Swift 6.2 Command Line Tools (building only)
- Codex CLI or Codex/ChatGPT App with a compatible Codex runtime (schema-probed at runtime)
- File-based Codex OAuth login state and network access for quota queries
- Local AI tool usage logs for token statistics

CodexOrb searches PATH, `~/.local/bin`, Homebrew locations, and Codex/ChatGPT application resources.
It probes the actual app-server schema and skips incompatible candidates. It never updates the external
Codex installation. Each quota or reset operation starts a private stdio process with the selected managed account's `CODEX_HOME`
and `cli_auth_credentials_store="file"`, then closes and reaps that process. No model turn is created.
Account identity is checked before and after quota reads; optional backend account IDs are also checked.
The native `~/.codex` home is never used by the capsule or its detail popovers. With no managed account selected,
the capsule and popovers remain empty instead of falling back to the native login.

```sh
codex app-server --stdio -c 'cli_auth_credentials_store="file"'
opentoken preview --since <today> --json
```

## Source checkout

The repository includes pinned OpenToken 0.3.27 and SHA256SUMS. CodexBar and its companion resources
are no longer bundled. External Codex profile-home configuration is not used for CodexOrb account management.
`Scripts/import_cli_tools.sh /path/to/opentoken` is an optional maintainer tool. It verifies the pinned
version/signature and regenerates checksums, without copying credentials or configuration.

## Run during development

```sh
cd CodexOrb
swift run CodexOrb
```

## Test

```sh
cd CodexOrb
swift run CodexOrbCoreChecks
```

The checks use fixed JSON fixtures and do not call a real account. They are a small executable instead of an XCTest
bundle so they work with the standalone Command Line Tools installation.

To check capsule resizing and scaled mouse hit areas without querying an account:

```sh
./Scripts/check_app_ui.sh
```

## Build a local app bundle

```sh
cd CodexOrb
./Scripts/build_app.sh
open CodexOrb.app
```

OpenToken lives in `Sources/CodexOrbCore/Resources/Tools`. Packaging validates checksums, copies it
into `Contents/Helpers`, and signs the copy. A validated managed update takes precedence over the bundled
copy; an invalid managed update falls back to the bundle. A missing bundled copy is an error.
See `Sources/CodexOrbCore/Resources/Tools/NOTICE.md` for provenance. OpenToken is included at the
repository owner's explicit request; its redistribution terms remain unverified.

`swift run CodexOrbCoreChecks --live-gui-environment` is an **opt-in live quota read** using app-server;
it never consumes a reset. Normal checks use only local fake accounts and a fake protocol peer.

The bundle is ad-hoc signed, without Developer ID signing or Apple notarization. Downloaded release builds
require the first-launch steps above. Developer ID signing and notarization would remove the need for this manual approval.

The app icon source is `Resources/AppIcon.png`. The build script generates the complete macOS `.icns` size set.

## Controls

- Hover inside the orb to expand the capsule; move away to collapse it. A 6-point band along the visible rounded edge is reserved for resizing and highlights on hover.
- Click the quota ring to open 5-hour and weekly remaining-quota and reset-time details.
- Click the reset-card stack to open the available reset cards.
- Drag inside to move, or drag an edge to resize proportionally from 100% to 150%. The expanded maximum is 264 × 84 points; the collapsed maximum is 90 × 84 points. Position and size are restored on the next launch.
- Click the token total to open token details with the all-tool total, cached-read amount and cache hit rate,
  plus per-tool and per-model breakdowns; right-click to refresh, open Settings, or quit.
- Collapsed orb: weekly remaining quota and 5-hour remaining quota. The pace indicator remains on the quota ring and is hidden when weekly quota is exhausted.
- Expanded capsule: adds reset credits, today's all-tool token total including cached reads, and the top model. Click the token total for per-tool and per-model breakdowns.

## Settings

Right-click the capsule and choose **Settings…** to change:

- 语言: switches the interface between 中文 and English.
- 胶囊显示账号: shows only CodexOrb-managed accounts and lets you select another account, then Save. Only Codex quota is supported.
- 添加 Codex 账号: starts browser login through the installed Codex CLI in a private home under `~/Library/Application Support/CodexOrb/Accounts/`. Complete authorization in the browser; the existing system login is preserved. Login times out after three minutes.
- 刷新账号: discovers only accounts created by CodexOrb under `~/Library/Application Support/CodexOrb/Accounts/`. The native `~/.codex` login and external profiles are not managed or deleted here. Account labels show email and plan; internal identity keys are not displayed. Credentials are never copied into app preferences.
- Automatic refresh: 1, 5, 10, 15, or 30 minutes, or 1 hour. The default is 5 minutes.
- 默认展开胶囊: keep the capsule expanded after launch and when the pointer leaves it. When disabled, the capsule retains its existing hover-to-expand behavior.
- 开机启动: controls the macOS login item immediately, independently of Save/Cancel and account login. Reads the system status each time settings becomes active; pending approval includes a link to system login item settings.
- 更新 CLI: updates only OpenToken, retaining its previous version on failure. The action runs immediately,
  and closing Settings preserves progress. Codex runtime installation/update is managed externally.

Save persists the selection locally and refreshes the capsule. With no managed account selected, the selection is stored empty.
The OpenToken total remains a machine-wide all-tool total when a managed account is selected; it is not attributed to the selected account.

CLI updates live under `~/Library/Application Support/CodexOrb/CLI/<tool>/`. Each update uses a new staging
directory, validates the candidate's signature, version and actual JSON report, then atomically switches
that tool's `current.json` to a new immutable release directory. The next OpenToken refresh uses the new version.
Existing release directories remain available to already-running processes; temporary staging directories are moved
to Trash. Separate file locks prevent concurrent updates of the same tool.
The application bundle, global CLI installations and background service definitions are not modified.

OpenToken's `self-update` runs on a staged executable with writes restricted to staging, temporary
output, and its exact `~/.opentoken/update` cache directory. Signature, version and token JSON
validation must pass before activation. No upload or daemon operation is invoked. The base version
comes from `versions.json`.

Codex app-server and OpenToken refresh concurrently but commit their results independently. Each source makes an initial
request and, after a failure, retries up to three times with five seconds between attempts. A successful source updates
the UI immediately while the other continues retrying. If one source still fails, it keeps its last successful value
and the capsule shows an amber status dot.


## Reset cards and confirmation

Clicking a known, available card immediately opens a compact confirmation beside the capsule, showing
only the question and account. Live validation and process waits happen after confirmation.
**Only “Confirm” authorizes the mutation. Cancel, dismiss and the default
Return key do not consume a card.** Card IDs stay attached when cards are sorted. Unknown details,
expired cards, unsupported reset types and cards with no ID cannot be redeemed. Non-expiring known cards
are shown separately from count-only placeholders.

The protocol calls are `account/rateLimits/read` and `account/rateLimitResetCredit/consume`.
The `codex` bucket is selected before matching 300/10080-minute windows. Missing data is not treated as
zero usage. Account operations are serialized, with a file lock preventing overlap across app instances.
Ordinary refreshes wait for the UI's reset operation; results from a previous selected account are discarded.

Before a send, a pending record is atomically saved in
`~/Library/Application Support/CodexOrb/ResetOperations/<identity-hash>/pending.json`.
It contains only the account identity hash, card ID, request UUID, timestamp and optional outcome, never
a token. Closing the app or losing the response preserves the same UUID. “Recover previous reset” requires
confirmation and reuses that UUID; it does not create a separate redemption. Do not manually delete pending
records to retry an uncertain operation.

If a pending record is unreadable, CodexOrb shows a separate damaged-record action instead of offering a
recovery that cannot succeed. Reset cards remain disabled until the user explicitly confirms moving the damaged
record out of the active path. The original file is preserved under `ResetOperations/Quarantine`; CodexOrb never
silently deletes it or treats it as a successfully recovered operation.

`reset` and `alreadyRedeemed` are successful outcomes; `noCredit` and `nothingToReset` do not apply a reset.
Every outcome is followed by a fresh quota read. A known success plus failed refresh remains a known success;
recovering that known outcome only rereads quota. An uncertain response retains its pending operation and, after
confirmation, retries with the same UUID rather than creating another redemption. Other card consumption stays
disabled until recovery completes. Cancellation cannot undo a request already sent.

Offline interaction checks (no real redemption):

```sh
./Scripts/check_app_ui.sh
```
