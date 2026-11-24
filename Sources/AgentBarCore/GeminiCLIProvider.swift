import Foundation

/// Gemini CLI（见 spec 第三版第 6 节）。
///
/// 本地只读 `~/.gemini/settings.json`（登录方式）和 `google_accounts.json`（账号）；
/// 用户开启联网后，再由 `GeminiUsageFetcher` 获取套餐和各模型的额度。
/// 本机没有安装 Gemini CLI，按其开源代码中的数据格式实现，没有实际验收。
public struct GeminiCLIProvider: Provider {
    public let id = "gemini-cli"
    public let displayName = "Gemini CLI"
    public let iconName: String? = "gemini"

    private let settingsFile: HomeFile
    private let accountsFile: HomeFile
    private let credentialsFile: HomeFile
    private let usageFetcher: GeminiUsageFetcher?

    /// - Parameter usageFetcher: 为 nil 时不联网（用户没有开启）。
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, usageFetcher: GeminiUsageFetcher? = nil) {
        settingsFile = HomeFile(home: home, relativePath: ".gemini/settings.json")
        accountsFile = HomeFile(home: home, relativePath: ".gemini/google_accounts.json")
        credentialsFile = HomeFile(home: home, relativePath: GeminiUsageFetcher.credentialsPath)
        self.usageFetcher = usageFetcher
    }

    /// 只看 Gemini CLI 自己的文件；Antigravity 等也会创建 `~/.gemini/` 目录。
    public func isInstalled() -> Bool {
        settingsFile.exists || accountsFile.exists || credentialsFile.exists
    }

    public func fetchStatus() async throws -> SubscriptionStatus {
        let authType = selectedAuthType()
        if let authType, authType != Self.googleLogin {
            // API key、Vertex AI 等方式没有订阅和额度可查
            return SubscriptionStatus(plan: Self.plan(authType: authType), state: .active)
        }

        let account = activeAccount()
        guard account != nil || credentialsFile.exists else {
            return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
        }

        var status = SubscriptionStatus(
            plan: Plan(rawValue: Self.googleLogin, displayName: "Google 账号"),
            state: .active,
            account: account,
            usage: .networkDisabled)
        if let usageFetcher {
            switch await usageFetcher.fetch() {
            case .success(let info):
                status.plan = info.plan
                status.usage = info.usage
            case .failure(let error):
                status.usage = .failed(error.message)
            }
        }
        return status
    }

    static let googleLogin = "oauth-personal"

    static func plan(authType: String) -> Plan {
        let name = switch authType {
        case "gemini-api-key": "API key"
        case "vertex-ai": "Vertex AI"
        case "compute-default-credentials": "Google Cloud 凭据"
        case "cloud-shell": "Cloud Shell"
        case "gateway": "Gateway"
        default: authType
        }
        return Plan(rawValue: authType, displayName: name)
    }

    /// `security.auth.selectedType`（旧版本是顶层的 `selectedAuthType`）。settings.json 允许注释，按 JSON5 解析；
    /// 读不了时返回 nil，按 Google 账号登录处理。
    private func selectedAuthType() -> String? {
        guard let data = try? settingsFile.read(),
              let json = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any]
        else { return nil }
        let security = json["security"] as? [String: Any]
        let auth = security?["auth"] as? [String: Any]
        return (auth?["selectedType"] as? String) ?? (json["selectedAuthType"] as? String)
    }

    private func activeAccount() -> String? {
        struct Accounts: Decodable { let active: String? }
        guard let data = try? accountsFile.read() else { return nil }
        return (try? JSONDecoder().decode(Accounts.self, from: data))?.active
    }
}
