import Foundation
import os
import Security

/// 获取 Cursor 用量失败的原因，`message` 显示在用量区。
public enum CursorUsageError: Error, Sendable, Equatable {
    case notSignedIn
    case keychainDenied
    case keychain(Int32)
    case tokenExpired
    case unauthorized
    case http(Int)
    case timedOut
    case network(String)
    case unexpectedFormat

    public var message: String {
        switch self {
        case .notSignedIn: "没有找到 cursor-agent 的登录，请安装并运行 cursor-agent login"
        case .keychainDenied: "钥匙串授权被拒绝；在设置中重新打开开关可再次请求授权"
        case .keychain(let status): "读取钥匙串失败（\(status)）"
        case .tokenExpired: "cursor-agent 登录已过期，请运行 cursor-agent login"
        case .unauthorized: "cursor-agent 登录已失效（401），请运行 cursor-agent login"
        case .http(let status): "接口返回 \(status)"
        case .timedOut: "请求超时"
        case .network(let reason): "网络错误：\(reason)"
        case .unexpectedFormat: "接口格式无法识别"
        }
    }
}

public struct CursorUsageResult: Sendable, Equatable {
    public let usage: Usage
    /// 本计费周期结束时间，即下次续费日。
    public let billingCycleEnd: Date?
}

/// 借用 `cursor-agent` 的登录获取 Cursor 用量（见工单 18）：
/// 从钥匙串读 `cursor-access-token`（只在内存中使用），以 Cursor CLI 的身份请求
/// `DashboardService/GetCurrentPeriodUsage`。不保存、不刷新凭据。
///
/// 与应用同生命周期（记住钥匙串被拒绝的时间、缓存 cursor-agent 的版本号），所以是一个带锁的类。
public final class CursorUsageFetcher: Sendable {
    static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    /// 钥匙串被拒绝后多久内不再请求授权，避免定时刷新反复弹窗。
    static let denialBackoff: TimeInterval = 30 * 60

    private let readToken: @Sendable () throws -> String
    private let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let clientVersion: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var deniedAt: Date?
        var version: String??
    }

    public convenience init() {
        self.init(
            readToken: { try Self.readKeychainToken() },
            send: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw CursorUsageError.unexpectedFormat }
                return (data, http)
            },
            clientVersion: { Self.cursorAgentVersion() },
            now: { Date() })
    }

    init(
        readToken: @escaping @Sendable () throws -> String,
        send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        clientVersion: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date
    ) {
        self.readToken = readToken
        self.send = send
        self.clientVersion = clientVersion
        self.now = now
    }

    /// 用户重新打开开关时调用：忘掉上次的拒绝，下次刷新会再次请求钥匙串授权。
    public func resetKeychainDenial() {
        state.withLock { $0.deniedAt = nil }
    }

    public func fetch() async throws -> CursorUsageResult {
        let now = now()
        if let deniedAt = state.withLock({ $0.deniedAt }), now.timeIntervalSince(deniedAt) < Self.denialBackoff {
            throw CursorUsageError.keychainDenied
        }

        let token: String
        do {
            token = try readToken()
        } catch let error as CursorUsageError {
            if error == .keychainDenied { state.withLock { $0.deniedAt = now } }
            throw error
        }
        state.withLock { $0.deniedAt = nil }

        if let expiry = JWT.decodePayload(TokenClaims.self, from: token)?.exp,
           Date(timeIntervalSince1970: expiry) <= now {
            throw CursorUsageError.tokenExpired
        }

        let (data, response) = try await perform(request(token: token))
        switch response.statusCode {
        case 200..<300: break
        case 401: throw CursorUsageError.unauthorized
        default: throw CursorUsageError.http(response.statusCode)
        }
        return try Self.parse(data, capturedAt: now)
    }

    private func request(token: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        if let version = cachedClientVersion() {
            request.setValue(version, forHTTPHeaderField: "x-cursor-client-version")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await send(request)
        } catch let error as CursorUsageError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw CursorUsageError.timedOut
        } catch {
            throw CursorUsageError.network(error.localizedDescription)
        }
    }

    private func cachedClientVersion() -> String? {
        if let cached = state.withLock({ $0.version }) { return cached }
        let version = clientVersion()
        state.withLock { $0.version = .some(version) }
        return version
    }

    static func parse(_ data: Data, capturedAt: Date) throws -> CursorUsageResult {
        guard let response = try? JSONDecoder().decode(UsageResponse.self, from: data),
              let total = response.planUsage?.totalPercentUsed
        else { throw CursorUsageError.unexpectedFormat }

        let end = response.billingCycleEnd?.date
        var windows = [UsageWindow(id: "total", windowMinutes: nil, usedPercent: total, resetsAt: end, label: "本计费周期")]
        if let auto = response.planUsage?.autoPercentUsed {
            windows.append(UsageWindow(id: "auto", windowMinutes: nil, usedPercent: auto, resetsAt: end, label: "Auto"))
        }
        if let api = response.planUsage?.apiPercentUsed {
            windows.append(UsageWindow(id: "api", windowMinutes: nil, usedPercent: api, resetsAt: end, label: "API"))
        }
        return CursorUsageResult(usage: Usage(windows: windows, capturedAt: capturedAt), billingCycleEnd: end)
    }

    // MARK: - 默认实现

    /// 读取 cursor-agent 存在钥匙串里的 token。第一次（以及 AgentBar 签名改变后）系统会弹窗请求授权。
    static func readKeychainToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cursor-access-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw CursorUsageError.notSignedIn
            }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        case errSecItemNotFound:
            throw CursorUsageError.notSignedIn
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw CursorUsageError.keychainDenied
        default:
            throw CursorUsageError.keychain(status)
        }
    }

    /// 从 Finder 启动的应用拿不到终端的 PATH，所以在常见位置找 cursor-agent。
    static func cursorAgentVersion() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/cursor-agent", "/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}

// MARK: - 响应格式（只建模用到的字段）

private struct TokenClaims: Decodable {
    let exp: Double?
}

private struct UsageResponse: Decodable {
    let billingCycleEnd: Milliseconds?
    let planUsage: PlanUsage?

    struct PlanUsage: Decodable {
        let totalPercentUsed: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
    }
}

/// protobuf 的 int64 在 JSON 里是字符串，也兼容数字。
private struct Milliseconds: Decodable {
    let date: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value: Double
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = Double(text) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不是时间戳")
        }
        date = Date(timeIntervalSince1970: value / 1000)
    }
}
