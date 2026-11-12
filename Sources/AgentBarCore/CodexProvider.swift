import Foundation

/// 读取 `~/.codex/auth.json`。ChatGPT 登录时，在内存里解码 `id_token` 的 payload（不校验签名）读取订阅信息。
/// 不读取、不保存 `access_token`、`refresh_token`、`OPENAI_API_KEY`。
public struct CodexProvider: Provider {
    public let id = "codex"
    public let displayName = "Codex"
    public let iconName: String? = "openai"

    private let file: HomeFile
    private let now: @Sendable () -> Date

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        file = HomeFile(home: home, relativePath: ".codex/auth.json")
        self.now = now
    }

    public func isInstalled() -> Bool { file.exists }

    public func fetchStatus() async throws -> SubscriptionStatus {
        let auth: AuthFile
        do {
            auth = try JSONDecoder().decode(AuthFile.self, from: try file.read())
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unreadable("\(file.displayPath) 格式无法解析")
        }

        // 旧版文件没有 auth_mode，有 tokens 就是 ChatGPT 登录。
        let isChatGPT = auth.authMode == "chatgpt" || (auth.authMode == nil && auth.idToken != nil)
        if isChatGPT {
            guard let idToken = auth.idToken else {
                return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
            }
            return try status(fromIDToken: idToken)
        }
        if auth.authMode != nil || auth.hasAPIKey {
            return SubscriptionStatus(
                plan: Plan(rawValue: "api_key", displayName: "API key"),
                state: .active,
                details: auth.authMode.map { [Detail("auth_mode", $0)] } ?? [])
        }
        return SubscriptionStatus(plan: Plan(rawValue: "", displayName: "未登录"), state: .signedOut)
    }

    private func status(fromIDToken idToken: String) throws -> SubscriptionStatus {
        guard let claims = JWT.decodePayload(IDTokenClaims.self, from: idToken) else {
            throw ProviderError.unreadable("\(file.displayPath) 中的 id_token 无法解析")
        }
        let auth = claims.auth
        let plan = auth?.planType.map(Self.plan)
        let periodEnd = auth?.activeUntil.flatMap(DateParsing.iso8601)

        let state: SubscriptionStatus.State
        if plan == nil {
            state = .unknown
        } else if let periodEnd, periodEnd <= now() {
            state = .expired
        } else {
            state = .active
        }

        var details = [Detail("auth_mode", "chatgpt")]
        if let start = auth?.activeStart {
            details.append(Detail("chatgpt_subscription_active_start", start))
        }

        return SubscriptionStatus(
            plan: plan ?? Plan(rawValue: "", displayName: "未知套餐"),
            state: state,
            account: claims.email,
            periodEnd: periodEnd,
            details: details,
            sourceUpdatedAt: auth?.lastChecked.flatMap(DateParsing.iso8601)
        )
    }

    /// `plus` → “ChatGPT Plus”（状态栏短名称 “Plus”），以此类推；未知值原样显示。
    static func plan(_ planType: String) -> Plan {
        let names = [
            "free": "ChatGPT Free",
            "go": "ChatGPT Go",
            "plus": "ChatGPT Plus",
            "pro": "ChatGPT Pro",
            "team": "ChatGPT Team",
            "business": "ChatGPT Business",
            "enterprise": "ChatGPT Enterprise",
            "edu": "ChatGPT Edu",
        ]
        guard let name = names[planType] else { return .unrecognized(planType) }
        return Plan(rawValue: planType, displayName: name, shortName: String(name.dropFirst("ChatGPT ".count)))
    }
}

// MARK: - 文件格式

/// `auth.json` 里只取需要的字段：`OPENAI_API_KEY` 只判断有没有值，tokens 里只取 `id_token`。
private struct AuthFile: Decodable {
    let authMode: String?
    let hasAPIKey: Bool
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case apiKey = "OPENAI_API_KEY"
        case tokens
    }

    private enum TokenKeys: String, CodingKey {
        case idToken = "id_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authMode = try container.decodeIfPresent(String.self, forKey: .authMode)
        hasAPIKey = container.contains(.apiKey) ? !(try container.decodeNil(forKey: .apiKey)) : false
        if container.contains(.tokens), !(try container.decodeNil(forKey: .tokens)) {
            let tokens = try container.nestedContainer(keyedBy: TokenKeys.self, forKey: .tokens)
            idToken = try tokens.decodeIfPresent(String.self, forKey: .idToken)
        } else {
            idToken = nil
        }
    }
}

private struct IDTokenClaims: Decodable {
    let email: String?
    let auth: AuthClaim?

    private enum CodingKeys: String, CodingKey {
        case email
        case auth = "https://api.openai.com/auth"
    }
}

private struct AuthClaim: Decodable {
    let planType: String?
    let activeStart: String?
    let activeUntil: String?
    let lastChecked: String?

    private enum CodingKeys: String, CodingKey {
        case planType = "chatgpt_plan_type"
        case activeStart = "chatgpt_subscription_active_start"
        case activeUntil = "chatgpt_subscription_active_until"
        case lastChecked = "chatgpt_subscription_last_checked"
    }
}

enum JWT {
    /// 按 `.` 切分后对第二段做 base64url 解码（补齐 padding），再按 JSON 解码。不校验签名。
    static func decodePayload<T: Decodable>(_ type: T.Type, from token: String) -> T? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var base64 = segments[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
