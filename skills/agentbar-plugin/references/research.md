# 调研一个 agent 的本地数据

目标：弄清楚四件事，再决定插件怎么写。

1. **怎么判断已安装** → `detect`
2. **订阅信息在哪**：套餐、状态、账号、到期时间 → `plan` / `state` / `account` / `periodEnd`
3. **用量能不能拿到**：额度窗口、已用比例、重置时间 → `usage`
4. **是否涉及凭据**：token、API key、refresh token、钥匙串

## 按优先级找数据来源

1. **官方命令行工具的查询命令**。例如 `xxx status --json`、`xxx quota show --output json`、`xxx whoami`。先看 `xxx --help` 和子命令的帮助，找带 `--json` / `--output json` 的。官方工具自己处理凭据和联网，插件只读输出，最安全，也最不容易因为版本升级失效。
2. **本地配置和状态文件**。常见位置：
   - `~/.<agent>/`、`~/.config/<agent>/`、`~/.local/share/<agent>/`
   - `~/Library/Application Support/<App>/`（桌面应用；Electron / VS Code 系的状态常在 `User/globalStorage/state.vscdb`，是 SQLite）
   - `~/Library/Preferences/<bundle id>.plist`（用 `defaults read <bundle id>` 查看）
   - 只看文件结构和非敏感字段的键名，例如用 `jq 'keys'`、`jq 'paths | join(".")'`、`sqlite3 -readonly <db> '.tables'`、`sqlite3 -readonly <db> "SELECT key FROM ItemTable"`。
3. **日志或会话记录**里的额度快照（例如每次请求后记录的剩余额度）。读最新的一条即可，注意文件可能很大，从尾部读。
4. **联网查询**：只有前面都拿不到时才考虑，而且通常要用到凭据，见下文。

## 安全规则

AgentBar 内置的 agent 都遵守这些规则，插件也应该遵守：

- **不打印、不保存、不记录任何 token、API key、cookie、refresh token。** 调研时只看键名和非敏感字段；需要确认凭据文件格式时，用 `jq 'keys'` 或 `jq 'map_values(type)'` 这类只显示结构的命令。
- **涉及凭据或钥匙串的探测命令，让用户自己运行**，你只看用户转述的结论（例如“HTTP 200”、“字段名是 xxx”），不要在对话里看到凭据本身。
- **不刷新凭据。** 有的服务的 refresh token 只能用一次，刷新后会把官方客户端踢下线。
- **不伪造客户端校验或请求签名**（例如私有的 checksum、signature 请求头）。
- **数据库只读打开**：`sqlite3 -readonly`，Python 里用 `sqlite3.connect("file:...?mode=ro", uri=True)`。
- **需要联网时先问用户**，说明会向哪个地址发什么请求、用的是哪份凭据。
- 不写别的应用的文件；插件自己的缓存放到隐藏文件或 `~/Library/Caches/`。

## 调研记录

把结论整理给用户确认后再写代码，例如：

```
已安装：~/.my-agent/config.json 存在
订阅：~/.my-agent/config.json 的 account.plan（free / pro / team）、account.email
到期：无本地数据
用量：`my-agent usage --json`（官方 CLI，自己联网），字段 limits[].remaining / limit / reset_at
凭据：不涉及（由 my-agent 自己处理）
```
