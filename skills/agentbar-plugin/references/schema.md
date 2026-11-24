# AgentBar 插件格式（apiVersion 1）

一个插件是 `~/.config/agentbar/plugins/<id>/` 下的一个文件夹：

```
<id>/
  plugin.json   # 清单（必需）
  status        # 插件命令，任意语言
  icon.svg      # 可选：单色图标（也可以是 icon.pdf / icon.png）
```

AgentBar 每次刷新（默认 15 分钟，用户可调）运行一次插件命令，读取它打印到标准输出的 JSON。

## plugin.json

```json
{
  "apiVersion": 1,
  "id": "my-agent",
  "name": "My Agent",
  "command": ["./status"],
  "detect": ["~/.my-agent/config.json"],
  "timeoutSeconds": 20
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `apiVersion` | 是 | 固定为 `1` |
| `id` | 是 | 小写字母、数字和 `-`，不能以 `-` 开头或结尾。**必须和文件夹名一致**，也不能和内置 agent 重名（`claude-code`、`codex`、`cursor`、`gemini-cli`、`minimax-code`、`mmx`） |
| `name` | 是 | 面板和设置里显示的名称 |
| `command` | 是 | 命令和参数的数组。第一项含 `/` 时是路径：`./x` 相对插件文件夹，`~/x` 相对用户主目录，也可以是绝对路径，文件必须有执行权限。否则按名字在 PATH 中查找（例如 `["python3", "status.py"]`、`["node", "status.mjs"]`） |
| `detect` | 否 | 路径数组，任一存在即视为“已安装”；规则同上（`~/` 相对主目录，其他相对路径相对插件文件夹）。省略时总是视为已安装。未安装的插件不显示 |
| `timeoutSeconds` | 否 | 1–60，默认 20。超时后进程被结束，面板显示“插件运行超时” |

## 运行环境

- 工作目录是插件文件夹；标准输入为空。
- `PATH` 已补上常见安装位置：`~/.local/share/mise/shims`、`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/bin`、`~/.bun/bin`、`~/.volta/bin`、`~/.npm-global/bin` 和系统目录。从 Finder 启动的应用拿不到终端里的 PATH，别的位置的命令要写绝对路径。
- 环境变量：`HOME`、`AGENTBAR_PLUGIN_API=1`、`AGENTBAR_PLUGIN_DIR`（插件文件夹的绝对路径）。
- 标准输出上限 64 KB。
- 插件以用户身份运行，没有沙盒。

## 输出

退出码 0，标准输出是一个 JSON 对象：

```json
{
  "plan": "Pro",
  "planShortName": "Pro",
  "state": "active",
  "account": "you@example.com",
  "organization": null,
  "periodEnd": "2026-12-01T00:00:00Z",
  "usage": {
    "windows": [
      { "windowMinutes": 300, "usedPercent": 42, "resetsAt": "2026-11-25T03:00:00Z" },
      { "label": "每周（Opus）", "usedPercent": 10 }
    ],
    "capturedAt": "2026-11-24T08:00:00Z"
  }
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `plan` | 是 | 套餐名，非空字符串。拿不到时写 `"未知套餐"`，未登录时可以写 `"未登录"` |
| `planShortName` | 否 | 状态栏用的短名，默认同 `plan` |
| `state` | 是 | `active` / `trial` / `expired` / `signedOut` / `unknown`。**未登录不是错误**，用 `signedOut` |
| `account` | 否 | 账号（通常是邮箱）。用户开了“隐藏邮箱”时 AgentBar 会自动打码 |
| `organization` | 否 | 组织名 |
| `periodEnd` | 否 | 到期或下次续费时间。试用（`trial`）时表示试用结束时间。临近时 AgentBar 会提醒 |
| `usage` | 否 | 省略时面板显示“暂不支持” |
| `usage.windows` | 是（有 `usage` 时） | 额度窗口数组；空数组显示“暂无数据” |
| `usage.windows[].usedPercent` | 是 | 已用比例，0–100，不能为负；超额时可以超过 100 |
| `usage.windows[].windowMinutes` | 二选一 | 窗口长度（分钟，正整数），用来生成名称：300 → “5 小时”，1440 → “每天”，10080 → “每周” |
| `usage.windows[].label` | 二选一 | 自定义名称，优先于 `windowMinutes` |
| `usage.windows[].resetsAt` | 否 | 重置时间。过了这个时间而插件还没刷新时，面板推测为已重置（0%） |
| `usage.capturedAt` | 否 | 数据的快照时间 |
| `usage.unavailable` | — | 代替 `windows`：`{"unavailable": "原因"}`，面板显示“获取失败：原因” |

- 时间一律是 ISO 8601 字符串，带时区，例如 `"2026-12-01T00:00:00Z"` 或 `"2026-12-01T08:00:00+08:00"`，可以带小数秒。不接受时间戳数字。
- 可选字段没有值时省略或写 `null`，**不要写空字符串**。
- 未知字段被忽略，可以放调试信息。
- 额度用到用户设定的比例（默认 80%）时，AgentBar 会在状态栏提示并发通知。

## 读取失败

两种方式，面板都会显示原因并带红点：

1. 输出 `{"error": "给用户看的原因"}`，退出码 0。`error` 优先于其他字段。**推荐**：原因可控，`agentbar plugin check` 也视为格式正确。
2. 以非零退出码退出：AgentBar 取标准错误的最后一个非空行作为原因；标准错误为空时显示退出码。

原因要写给普通用户看，例如“找不到 ~/.my-agent/config.json”“登录已失效，请运行 my-agent login”，不要直接输出堆栈。

## 用户确认

新插件默认关闭，用户在 AgentBar“设置 → 插件”里看到要运行的命令后手动开启。AgentBar 记下确认时插件文件夹的内容指纹（所有非隐藏文件的路径和内容），**之后任何非隐藏文件改动都会让插件停用、等待重新确认**。所以：

- 插件运行时不要往自己的文件夹里写非隐藏文件；缓存写到隐藏文件（如 `.cache/`）或 `~/Library/Caches/` 下。
- 开发调试时每次改完都需要重新确认，属于正常现象；用 `agentbar plugin check` 调试不需要确认。
