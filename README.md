# AgentBar

[![CI](https://github.com/loveRyujin/mac_agent_bar/actions/workflows/ci.yml/badge.svg)](https://github.com/loveRyujin/mac_agent_bar/actions/workflows/ci.yml)

一个 macOS 状态栏应用，用来查看本机 AI coding agent 当前登录账号的订阅信息：套餐、订阅状态、到期时间和账号邮箱。

## 功能

- 支持 **Claude Code**、**Codex**、**Cursor**，自动发现本机已安装的 agent
- 状态栏显示选中 agent 的图标和套餐名，在面板里点击图标切换
- 订阅 7 天内到期、已过期或读取失败时，在状态栏和面板中提示
- 只读本地文件，不联网，不读取任何 access token、refresh token 或 API key

## 安装

从 [Releases](https://github.com/loveRyujin/mac_agent_bar/releases) 下载 zip，解压后把 `AgentBar.app` 拖到“应用程序”文件夹。

应用没有经过 Apple 公证，第一次打开前需要运行：

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

| Agent | 读取的文件 |
|---|---|
| Claude Code | `~/.claude.json` 中的 `oauthAccount` |
| Codex | `~/.codex/auth.json`（在本地解码 `id_token` 中的订阅字段） |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`（只读打开） |

## 发布新版本

修改 `Sources/AgentBarCore/AgentBarCore.swift` 中的版本号并提交，然后推送对应的 tag（如 `v0.2.0`）。GitHub Actions 会自动测试、打包并创建 Release。

## 授权

代码以 [MIT](LICENSE) 授权。agent 的 logo 不在 MIT 授权范围内，见 [NOTICE](NOTICE.md)。
