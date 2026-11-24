---
name: agentbar-plugin
description: Build, debug, or validate an AgentBar plugin — a folder under ~/.config/agentbar/plugins/ (plugin.json plus a script that prints JSON) that shows an AI coding agent's plan, subscription status, expiry, and usage in the AgentBar macOS menu bar app. Use when the user wants AgentBar to show an agent it doesn't support built in, or is writing or fixing such a plugin.
---

# AgentBar 插件开发

AgentBar 是 macOS 状态栏应用，显示本机 AI coding agent 的套餐、订阅状态、到期时间和用量。内置不支持的 agent 可以写插件接入：一个文件夹，包含清单 `plugin.json` 和一个打印 JSON 的命令（任意语言）。

- 格式的完整说明：[references/schema.md](references/schema.md)（写代码前先读）
- 怎么找 agent 的数据、安全规则：[references/research.md](references/research.md)
- 可运行的示例：[examples/](examples/)
  - `example-json-file`：读本地 JSON 文件（macOS 自带的 JavaScript，`osascript -l JavaScript`）
  - `example-sqlite`：只读查询本地 SQLite（`/usr/bin/sqlite3 -readonly`）
  - `example-cli`：调用官方命令行工具的 JSON 输出（Python）

## 命令行工具

AgentBar 0.3.0 起自带：

```sh
agentbar plugin new <id> [--dir <父目录>]   # 生成骨架，默认放在 ~/.config/agentbar/plugins/<id>/
agentbar plugin check <插件文件夹>          # 校验清单、运行一次、校验输出，打印面板上会显示的内容
```

`agentbar` 是 Homebrew 安装的命令。没有这个命令时，用应用内的可执行文件：`/Applications/AgentBar.app/Contents/MacOS/AgentBar plugin …`（应用在别处时替换路径）。`check` 退出码 0 表示通过，失败时会指出出错的字段，并附上插件的原始输出。

## 工作流程

1. **问清需求**：要接入哪个 agent，想看到什么（套餐、到期、用量）。确认 `agentbar plugin help` 能运行。
2. **调研数据来源**：按 [references/research.md](references/research.md) 的优先级找：官方 CLI 的查询命令 → 本地配置/状态文件 → 日志里的快照 → 联网。把结论（已安装判断、各字段来自哪里、是否涉及凭据）告诉用户，确认后再写代码。
3. **生成骨架**：`agentbar plugin new <id>`。`id` 用小写字母、数字和 `-`，不能和内置 agent 重名。
4. **实现**：参考最接近的示例。要点：
   - 只解码需要的字段；文件不存在、格式不对、未登录都要处理。
   - 未登录输出 `"state": "signedOut"`；读取失败输出 `{"error": "给用户看的原因"}`。
   - 剩余比例要换算成已用比例（`usedPercent = 100 - remaining`）。
   - 时间转成带时区的 ISO 8601 字符串。
   - 不要往插件文件夹里写非隐藏文件（会触发重新确认）。
5. **校验**：反复运行 `agentbar plugin check <插件文件夹>` 直到通过。还要验证异常路径：临时改名数据文件、模拟未登录，确认输出的是 `error` 或 `signedOut`，而不是崩溃。
6. **交给用户开启**：告诉用户打开 AgentBar“设置 → 插件”，确认开启这个插件。**不要替用户确认**（不要修改 AgentBar 的设置或 `defaults`）：确认步骤是让用户看清要运行的命令。

## 必须遵守

- 不打印、不保存、不记录 token、API key、cookie；涉及凭据或钥匙串的探测命令让用户自己运行。
- 不刷新凭据，不伪造请求签名；数据库只读打开。
- 需要联网时先征得用户同意。
- 插件以用户身份运行、没有沙盒；只写用户要求的插件，不夹带别的行为。
