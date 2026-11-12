import Foundation

/// 一个 AI coding agent 的订阅信息来源。新增 agent 只需实现此协议并加入 `ProviderRegistry`。
///
/// 实现者的构造函数应接受 `home: URL` 参数（默认是用户主目录），测试时指向 fixture 目录。
public protocol Provider: Sendable {
    /// 稳定标识，例如 "claude-code" / "codex" / "cursor"。
    var id: String { get }
    var displayName: String { get }
    /// 图标资源名（界面层据此加载单色 logo）；为 nil 时界面用名称首字母代替。
    var iconName: String? { get }
    func isInstalled() -> Bool
    func fetchStatus() async throws -> SubscriptionStatus
}

extension Provider {
    public var iconName: String? { nil }
}

/// provider 读取失败的原因，`message` 可以直接显示在界面上。
public enum ProviderError: Error, Sendable, Equatable {
    /// 数据文件不存在，参数是给用户看的路径（例如 "~/.codex/auth.json"）。
    case fileNotFound(String)
    /// 文件存在但无法读取或解析，参数是可读的原因。
    case unreadable(String)

    public var message: String {
        switch self {
        case .fileNotFound(let path): "找不到 \(path)"
        case .unreadable(let reason): reason
        }
    }
}

/// 一次刷新中某个 provider 的结果。
public struct ProviderResult: Sendable {
    public let provider: any Provider
    public let outcome: Result<SubscriptionStatus, ProviderError>
}

/// 持有所有 provider，负责并发刷新。
public struct ProviderRegistry: Sendable {
    public let providers: [any Provider]

    public init(providers: [any Provider]) {
        self.providers = providers
    }

    /// 默认注册表：所有已支持的 agent。新增 agent 只需加在这里。
    public static let standard = ProviderRegistry(providers: [
        ClaudeCodeProvider(),
        CodexProvider(),
        CursorProvider(),
    ])

    /// 对已安装的 provider 并发调用 `fetchStatus()`。每个 provider 的错误单独捕获，互不影响；
    /// 结果按注册顺序返回，未安装的 provider 不出现在结果里。
    public func refreshAll() async -> [ProviderResult] {
        let installed = providers.filter { $0.isInstalled() }
        return await withTaskGroup(of: (Int, ProviderResult).self) { group in
            for (index, provider) in installed.enumerated() {
                group.addTask {
                    (index, ProviderResult(provider: provider, outcome: await Self.fetch(provider)))
                }
            }
            var results: [(Int, ProviderResult)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func fetch(_ provider: any Provider) async -> Result<SubscriptionStatus, ProviderError> {
        do {
            return .success(try await provider.fetchStatus())
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreadable("读取失败：\(error)"))
        }
    }
}
