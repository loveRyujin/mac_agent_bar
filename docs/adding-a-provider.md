# 新增一个 agent

每个 agent 对应一个 provider：实现 `Provider` 协议，加入注册表，界面不用改。

## 1. 先调研，再写代码

新增 agent 前先弄清楚以下几点，结论交给维护者审核：

- **怎么判断已安装**：最好是检查某个文件是否存在，开销小，不需要运行命令。
- **订阅信息存在哪里**：套餐、状态、账号、到期时间。
- **用量能不能拿到**：来自本地缓存、官方 CLI 的命令，还是需要联网。
- **是否会接触凭据**：token、API key、刷新 token、钥匙串。

接触凭据的规则（spec 第 2 节）：

- 不读取、不保存、不记录任何 token 或 API key，只读非敏感字段。
- **不刷新凭据**。有的服务刷新 token 只能用一次，刷新后会把原来的客户端踢下线（例如 MiniMax）。
- 不伪造客户端校验或请求签名，例如 Cursor IDE 的 `x-cursor-checksum`、MiniMax Code 的 `x-signature`。
- 如果官方 CLI 自带查询命令（例如 `mmx quota show --output json`），优先调用它。CLI 自己负责凭据和联网，AgentBar 只读命令输出。
- 需要联网时，默认关闭，在设置里由用户手动开启（借用用户官方 CLI 的情况可以讨论例外）。
- 读取别的应用的数据库时只能只读打开（例如 SQLite 的 `SQLITE_OPEN_READONLY`）。

## 2. 实现 provider

在 `Sources/AgentBarCore/` 下新建 `<Name>Provider.swift`：

```swift
public struct ExampleProvider: Provider {
    public let id = "example"              // 稳定标识，会存进设置，不要改
    public let displayName = "Example"
    public let iconName: String? = "example"  // 资源名，没有图标时界面用首字母

    private let file: HomeFile

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        file = HomeFile(home: home, relativePath: ".example/state.json")
    }

    public func isInstalled() -> Bool { file.exists }

    public func fetchStatus() async throws -> SubscriptionStatus {
        let data = try file.read()   // 文件不存在时抛出 ProviderError.fileNotFound
        // 只解码需要的字段；格式不对时抛出 ProviderError.unreadable("… 格式无法解析")
        …
    }
}
```

约定：

- 构造函数接受 `home: URL`，测试时指向临时目录。
- **未登录**不是错误，返回 `state: .signedOut`。**读取失败**才抛出 `ProviderError`，界面会显示原因并带红点。
- 认不出的套餐原样显示：`Plan.unrecognized(raw)`。状态栏用的短名可以另外设 `shortName`。
- 本地拿不到的字段留空，例如没有到期时间就不设 `periodEnd`，面板不会显示这一行。
- 用量放在 `usage` 里：
  - 拿到了：`.available(Usage(windows:capturedAt:))`，每个额度窗口一个 `UsageWindow`。窗口名由分钟数推出（300 → “5 小时”，10080 → “每周”），也可以用 `label` 自定义。
  - 拿不到：用 `.unsupported` / `.networkDisabled` / `.noData` / `.failed(原因)` 说明原因。
  - 借用别的工具的数据时设置 `Usage.source`，面板会注明“数据来自 …”。
  - 用量出错只影响用量区，不要因此让整个 `fetchStatus` 失败。
- 需要运行外部命令时：从 Finder 启动的应用拿不到终端的 PATH，要在常见安装位置查找可执行文件（参考 `MmxClient.executableURL()`），并设置超时。

## 3. 测试

在 `Tests/AgentBarCoreTests/` 下写测试，统一用 `scripts/test.sh` 运行。

- 测试数据放在 `Tests/Fixtures/<case>/`，用 `TestHome(fixture:)` 复制到临时目录。也可以用 `TestHome().write(_:to:)` 直接生成。
- 至少覆盖这几种情况：正常、未登录、字段缺失、认不出的套餐值、文件损坏。用量还要覆盖：没有数据、格式变化、重置时间已过。
- JWT、SQLite 文件等测试数据由测试代码生成，**不要提交真实凭据**。
- 外部命令、网络请求、钥匙串都通过闭包注入，测试中换成假的实现（参考 `MmxClient`、`CursorUsageFetcher`）。
- 需要 `UserDefaults` 时用 `TestDefaults`，测试结束会自动清理。

## 4. 图标

1. 优先从 [Simple Icons](https://simpleicons.org) 获取单色 SVG，放进 `assets/icons/<name>.svg`。
2. 转成 PDF 资源：`swift scripts/svg2pdf.swift assets/icons/<name>.svg Sources/AgentBar/Resources/<name>.pdf`
3. 在 `NOTICE.md` 里写明来源版本和授权。Simple Icons 的图标不一定都是 CC0，要查 `data/simple-icons.json` 中的 `license` 字段。

## 5. 注册

把 provider 加进 `ProviderRegistry.standard(settings:cursorUsage:mmx:)`（`Sources/AgentBarCore/Provider.swift`）。列表顺序就是面板页签的顺序，也是状态栏回退显示时的查找顺序。如果用量需要设置开关，就在 `AppSettings` 中加一个字段（缺失时取默认值，见 `init(from:)`），并在设置窗口的“用量”分组里加对应的开关。

## 6. 验收

- `swift build` 和 `scripts/test.sh` 都能通过。
- 用 `scripts/bundle.sh` 打包后，在本机核对面板显示的内容和数据源是否一致。所有时间都按系统时区（北京时间）显示。
- 把数据文件暂时改名，确认对应的页签消失或显示错误，应用不会崩溃。
