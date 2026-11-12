# AgentBar

[![CI](https://github.com/loveRyujin/mac_agent_bar/actions/workflows/ci.yml/badge.svg)](https://github.com/loveRyujin/mac_agent_bar/actions/workflows/ci.yml)

一个 macOS 状态栏应用，用来查看本机 AI coding agent 当前登录账号的订阅信息：套餐、订阅状态、到期时间和账号邮箱。

## 功能

- 支持 **Claude Code**、**Codex**、**Cursor**、**MiniMax Code**、**mmx**，自动发现本机已安装的 agent
- 显示套餐、订阅状态、到期时间，以及 5 小时、每周等额度窗口的用量和重置时间
- 状态栏显示 AgentBar 的 logo 和选中 agent 的套餐名、用量或警示；在面板里点击图标切换
- 快到期、额度快用完、读取失败时在状态栏和面板中提示，并发送系统通知
- 设置：开机自启、刷新间隔、显示哪些 agent、隐藏邮箱、提醒阈值、各类通知开关
- 不保存、不刷新任何 access token、refresh token 或 API key（见下文“数据来源”）

## 安装

### Homebrew（推荐）

```sh
brew tap loveRyujin/agentbar https://github.com/loveRyujin/mac_agent_bar
brew install agentbar
agentbar   # 打开应用
```

在本机从源码编译（大约一两分钟），需要 Command Line Tools（Swift 6）。应用安装在 Homebrew 的目录里；想在“应用程序”里看到它，可以按安装结束时的提示链接到 `~/Applications`。升级用 `brew update && brew upgrade agentbar`。

### 下载安装包

从 [Releases](https://github.com/loveRyujin/mac_agent_bar/releases) 下载 zip，解压后把 `AgentBar.app` 拖到“应用程序”文件夹。应用没有经过 Apple 公证，第一次打开前需要运行：

```sh
xattr -dr com.apple.quarantine /Applications/AgentBar.app
```

要求 macOS 13 或更高。Releases 中的安装包只支持 Apple Silicon。

## 从源码构建

需要 Xcode 或 Command Line Tools（Swift 6）。

```sh
swift build
scripts/test.sh      # 运行测试（只装 Command Line Tools 时，直接 swift test 会跳过测试）
scripts/bundle.sh    # 打包成 build/AgentBar.app
```

## 数据来源

| Agent | 订阅信息 | 用量 |
|---|---|---|
| Claude Code | `~/.claude.json` 中的 `oauthAccount` | 同一文件中 Claude Code 缓存的 `cachedUsageUtilization` |
| Codex | `~/.codex/auth.json`（在本地解码 `id_token` 中的订阅字段） | 会话日志 `~/.codex/sessions/` 中的额度快照 |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`（只读打开） | **默认关闭**。在设置中开启后，借用 `cursor-agent` 的登录（钥匙串）向 `api2.cursor.sh` 查询 |
| MiniMax Code | `~/.minimax/auth/…/auth-state.json` 中的登录状态 | 借用 mmx 查到的结果（同一账号） |
| mmx | `mmx auth status` | `mmx quota show`（由 mmx 自己联网查询） |

## 发布新版本

修改 `Sources/AgentBarCore/AgentBarCore.swift` 中的版本号并提交，然后推送对应的 tag（如 `v0.2.0`）。GitHub Actions 会自动测试、打包、创建 Release，并更新 `Formula/agentbar.rb`。

## 授权

代码以 [MIT](LICENSE) 授权。agent 的 logo 不在 MIT 授权范围内，见 [NOTICE](NOTICE.md)。
