# 插件

AgentBar 内置支持的 agent 之外，可以用插件接入任意 agent。插件是 `~/.config/agentbar/plugins/` 下的一个文件夹：一份清单 `plugin.json`，加一个把订阅信息以 JSON 打印出来的命令，任何语言都可以。接入后和内置 agent 一样显示在状态栏和面板里，到期、额度提醒和通知也都照常工作。

## 用 coding agent 写插件（推荐）

仓库里带了一个 Agent Skill：[`skills/agentbar-plugin`](../skills/agentbar-plugin/SKILL.md)。装好后，对 Claude Code、Codex 等 coding agent 说“给 AgentBar 写一个 xxx 的插件”，它会调研 xxx 把数据存在哪里、生成插件、反复校验直到通过。

安装（二选一）：

```sh
# 用 skills 命令安装，按提示选择要装到哪些 agent
npx skills add loveRyujin/mac_agent_bar

# 或者手动复制，例如装给 Claude Code
git clone https://github.com/loveRyujin/mac_agent_bar
cp -R mac_agent_bar/skills/agentbar-plugin ~/.claude/skills/
```

## 手动写插件

```sh
agentbar plugin new my-agent                              # 生成 ~/.config/agentbar/plugins/my-agent/
$EDITOR ~/.config/agentbar/plugins/my-agent/status        # 改成输出真实数据
agentbar plugin check ~/.config/agentbar/plugins/my-agent # 校验，直到显示“✓ 通过”
```

然后打开 AgentBar“设置 → 插件”，确认开启。

- 清单和输出的格式：[skills/agentbar-plugin/references/schema.md](../skills/agentbar-plugin/references/schema.md)
- 示例：[skills/agentbar-plugin/examples](../skills/agentbar-plugin/examples)（读 JSON 文件、只读查询 SQLite、调用官方命令行工具）
- `agentbar` 是 Homebrew 安装的命令；用安装包安装时，换成 `/Applications/AgentBar.app/Contents/MacOS/AgentBar plugin …`。

最小的插件：

```sh
#!/bin/sh
echo '{"plan": "Pro", "state": "active", "usage": {"windows": [{"windowMinutes": 300, "usedPercent": 42}]}}'
```

## 安全

插件以你的身份运行，可以读你的文件、访问网络，AgentBar 没法限制它。所以：

- **新插件默认关闭。** 在“设置 → 插件”里能看到每个插件要运行的命令，确认后才会运行。
- **插件文件夹的内容一变，插件就停用**，等你重新确认。这样插件被改动（不管是你自己改的还是别的程序改的）都不会悄悄生效。
- 只开启你信任来源的插件；拿到别人的插件，先看一遍它的代码。

写插件时请遵守和内置 agent 一样的规则：不打印、不保存 token 和 API key，不刷新凭据，不伪造请求签名，数据库只读打开。详见 [references/research.md](../skills/agentbar-plugin/references/research.md)。

## 常见问题

**设置里看不到我的插件**：检查文件夹是否在 `~/.config/agentbar/plugins/` 下、文件夹名是否和 `plugin.json` 里的 `id` 一致。清单有错的插件也会列出来，并显示出错原因。

**开启后面板里没有它**：`detect` 里的路径都不存在时视为未安装，不会显示。`agentbar plugin check` 会显示安装检测的结果。

**每次改完都要重新确认**：这是预期行为。调试时用 `agentbar plugin check`，不需要确认。

**插件在终端能运行，在 AgentBar 里找不到命令**：从 Finder 启动的应用拿不到终端的 PATH。AgentBar 已经补上了 Homebrew、mise、`~/.local/bin` 等常见位置，其他位置的命令请在插件里写绝对路径。
