import Foundation
import os

/// 获取 Gemini 套餐和额度失败的原因，`message` 显示在用量区。
public enum GeminiUsageError: Error, Sendable, Equatable {
    case notSignedIn
    /// refresh token 被拒绝（已撤销或过期）。
    case refreshRejected
    /// access token 已过期，本机找不到 Gemini CLI 的 OAuth 客户端信息，无法刷新。
    case cannotRefresh
    case unauthorized
    case http(Int)
    case network(String)
    case unexpectedFormat

    public var message: String {
        switch self {
        case .notSignedIn: "没有找到 Gemini CLI 的登录，请运行 gemini 登录"
        case .refreshRejected: "Gemini CLI 登录已失效，请运行 gemini 重新登录"
        case .cannotRefresh: "Gemini CLI 的登录已过期，运行一次 gemini 后可恢复"
        case .unauthorized: "Gemini CLI 登录已失效（401），请运行 gemini 重新登录"
        case .http(let status): "接口返回 \(status)"
        case .network(let reason): "网络错误：\(reason)"
        case .unexpectedFormat: "接口格式无法识别"
        }
    }
}

public struct GeminiAccountInfo: Sendable, Equatable {
    public let plan: Plan
    public let usage: UsageAvailability
}

/// 借用 Gemini CLI 的登录获取套餐和各模型额度（参考 Magpie 和 Gemini CLI 开源代码
/// `packages/core/src/code_assist/`）：
///
/// 1. 读 `~/.gemini/oauth_creds.json` 的 access token；快过期时用 refresh token 向 Google 换新的。
///    刷新要用 Gemini CLI 的 OAuth 客户端信息，从本机安装的 Gemini CLI 包里读取（见 `GeminiOAuthClient`）。
///    新 token **只保存在内存里**，不写回文件，不影响 Gemini CLI 自己的登录（Google 的 refresh token 可以重复使用）。
///    刷新是 2026-11-24 用户为 Gemini 单独放宽的规则，其他 agent 仍然不刷新凭据。
/// 2. `loadCodeAssist` → 套餐档位和 Cloud 项目；`retrieveUserQuota` → 各模型的剩余比例和重置时间。
///
/// 凭据不写日志、不保存、不显示。
public final class GeminiUsageFetcher: Sendable {
    static let credentialsPath = ".gemini/oauth_creds.json"
    static let endpoint = "https://cloudcode-pa.googleapis.com/v1internal"
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// access token 剩余时间少于这个值时视为已过期。
    static let expiryMargin: TimeInterval = 60

    private let credentialsFile: HomeFile
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let locateClient: @Sendable () -> GeminiOAuthClient?
    private let now: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        /// 刷新得到的 access token，只在内存中。
        var token: (value: String, expiresAt: Date)?
        /// 找到的 OAuth 客户端信息（找到一次后不再扫描）。
        var client: GeminiOAuthClient?
    }

    public convenience init() {
        self.init(
            home: FileManager.default.homeDirectoryForCurrentUser,
            send: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw GeminiUsageError.unexpectedFormat }
                return (data, http)
            },
            locateClient: { GeminiOAuthClient.locate() },
            now: { Date() })
    }

    init(
        home: URL,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        locateClient: @escaping @Sendable () -> GeminiOAuthClient?,
        now: @escaping @Sendable () -> Date
    ) {
        credentialsFile = HomeFile(home: home, relativePath: Self.credentialsPath)
        self.send = send
        self.locateClient = locateClient
        self.now = now
    }

    public func fetch() async -> Result<GeminiAccountInfo, GeminiUsageError> {
        do {
            var token = try await accessToken()
            let load: LoadResponse
            do {
                load = try await post("loadCodeAssist", body: Self.loadRequest, token: token)
            } catch GeminiUsageError.unauthorized {
                // 文件里的 token 可能已被撤销：刷新一次再试
                token = try await accessToken(forceRefresh: true)
                load = try await post("loadCodeAssist", body: Self.loadRequest, token: token)
            }

            let tier = load.paidTier ?? load.currentTier
            let plan = Self.plan(id: tier?.id, name: tier?.name)
            guard let project = load.cloudaicompanionProject, !project.isEmpty else {
                return .success(GeminiAccountInfo(plan: plan, usage: .failed("没有可用的 Google Cloud 项目")))
            }

            let usage: UsageAvailability
            do {
                let quota: QuotaResponse = try await post("retrieveUserQuota", body: ["project": project], token: token)
                usage = .available(Usage(windows: Self.windows(quota.buckets ?? []), capturedAt: now()))
            } catch let error as GeminiUsageError {
                usage = .failed(error.message)
            }
            return .success(GeminiAccountInfo(plan: plan, usage: usage))
        } catch let error as GeminiUsageError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    // MARK: - 套餐和额度

    /// 优先用接口给的套餐名（如 “Google AI Pro”）；没有时按档位 id 显示。
    static func plan(id: String?, name: String?) -> Plan {
        let raw = id ?? ""
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return Plan(rawValue: raw, displayName: name)
        }
        let displayName = switch raw {
        case "free-tier": "Free"
        case "standard-tier": "Standard"
        case "legacy-tier": "Legacy"
        case "": "未知套餐"
        default: raw
        }
        return Plan(rawValue: raw, displayName: displayName)
    }

    /// 每个模型一个窗口；同一模型有多种计量方式时在名称后注明。没有剩余比例的跳过。
    static func windows(_ buckets: [Bucket]) -> [UsageWindow] {
        let valid = buckets.filter { $0.modelId?.isEmpty == false && $0.remainingFraction != nil }
        var counts: [String: Int] = [:]
        for bucket in valid { counts[bucket.modelId!, default: 0] += 1 }
        return valid.map { bucket in
            let model = bucket.modelId!
            let name = counts[model]! > 1 ? "\(model) · \(bucket.tokenType ?? "?")" : model
            return UsageWindow(
                id: name, windowMinutes: nil,
                usedPercent: max(0, (1 - bucket.remainingFraction!) * 100),
                resetsAt: bucket.resetTime.flatMap(DateParsing.iso8601), label: name)
        }
    }

    // MARK: - 凭据

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        let current = now()
        if !forceRefresh, let cached = state.withLock({ $0.token }), cached.expiresAt > current.addingTimeInterval(Self.expiryMargin) {
            return cached.value
        }
        guard let data = try? credentialsFile.read(),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        else { throw GeminiUsageError.notSignedIn }

        if !forceRefresh, let token = credentials.accessToken, let expiry = credentials.expiryDate,
           Date(timeIntervalSince1970: expiry / 1000) > current.addingTimeInterval(Self.expiryMargin) {
            return token
        }
        guard let refreshToken = credentials.refreshToken else { throw GeminiUsageError.notSignedIn }
        return try await refresh(refreshToken)
    }

    private func refresh(_ refreshToken: String) async throws -> String {
        guard let client = state.withLock({ $0.client }) ?? locateClient() else {
            throw GeminiUsageError.cannotRefresh
        }
        state.withLock { $0.client = client }

        var request = URLRequest(url: Self.tokenEndpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode([
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ]).utf8)

        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200: break
        case 400, 401: throw GeminiUsageError.refreshRejected
        default: throw GeminiUsageError.http(response.statusCode)
        }
        guard let reply = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GeminiUsageError.unexpectedFormat
        }
        let expiresAt = now().addingTimeInterval(TimeInterval(reply.expiresIn ?? 3600))
        state.withLock { $0.token = (reply.accessToken, expiresAt) }
        return reply.accessToken
    }

    private static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&")
    }

    // MARK: - 请求

    private static var loadRequest: [String: Any] {
        ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
    }

    private func post<Response: Decodable>(_ method: String, body: [String: Any], token: String) async throws -> Response {
        var request = URLRequest(url: URL(string: "\(Self.endpoint):\(method)")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AgentBar/\(AgentBarCore.version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch let error as GeminiUsageError {
            throw error
        } catch {
            throw GeminiUsageError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200: break
        case 401: throw GeminiUsageError.unauthorized
        default: throw GeminiUsageError.http(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw GeminiUsageError.unexpectedFormat
        }
        return decoded
    }

    // MARK: - 格式（只建模用到的字段）

    private struct Credentials: Decodable {
        let accessToken: String?
        let refreshToken: String?
        /// 毫秒时间戳。
        let expiryDate: Double?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiryDate = "expiry_date"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct LoadResponse: Decodable {
        let currentTier: Tier?
        let paidTier: Tier?
        let cloudaicompanionProject: String?

        struct Tier: Decodable {
            let id: String?
            let name: String?
        }
    }

    private struct QuotaResponse: Decodable {
        let buckets: [Bucket]?
    }

    struct Bucket: Decodable {
        let modelId: String?
        let tokenType: String?
        let remainingFraction: Double?
        let resetTime: String?
    }
}
