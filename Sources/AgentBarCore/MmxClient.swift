import Foundation

/// 调用 mmx（MiniMax 官方 CLI）失败的原因，`message` 可直接显示。
public enum MmxError: Error, Sendable, Equatable {
    case notInstalled
    case timedOut
    case unexpectedFormat
    case failed(String)

    public var message: String {
        switch self {
        case .notInstalled: "没有找到 mmx，请先安装并运行 mmx auth login"
        case .timedOut: "mmx 响应超时"
        case .unexpectedFormat: "mmx 输出格式无法识别"
        case .failed(let reason): reason
        }
    }
}

/// `mmx auth status` 的结果。
public enum MmxAuthStatus: Sendable, Equatable {
    case signedIn(method: String, tokenExpires: String?)
    case signedOut
    case failed(String)
}

/// 通过 mmx 获取 MiniMax 账号的登录状态和 Token Plan 用量（见工单 13）。
///
/// AgentBar 不接触 MiniMax 的凭据：凭据由 mmx 自己保存和续期，网络请求也由 mmx 发出，这里只读命令输出。
/// mmx 和 MiniMax Code 两个 provider 共用一个实例：同时到来的查询只运行一次命令，结果短时间缓存。
public actor MmxClient {
    static let quotaCacheDuration: TimeInterval = 60
    static let timeout: TimeInterval = 20

    private let run: @Sendable ([String]) async throws -> Data
    private let now: @Sendable () -> Date
    private var cachedQuota: (at: Date, value: UsageAvailability)?
    private var quotaInFlight: Task<UsageAvailability, Never>?

    public init() {
        self.init(run: { try await Self.runInstalledMmx($0) }, now: { Date() })
    }

    init(run: @escaping @Sendable ([String]) async throws -> Data, now: @escaping @Sendable () -> Date) {
        self.run = run
        self.now = now
    }

    // MARK: - 用量

    public func quota() async -> UsageAvailability {
        if let cached = cachedQuota, now().timeIntervalSince(cached.at) < Self.quotaCacheDuration {
            return cached.value
        }
        if let inFlight = quotaInFlight {
            return await inFlight.value
        }
        let run = run, capturedAt = now()
        let task = Task { await Self.fetchQuota(run: run, capturedAt: capturedAt) }
        quotaInFlight = task
        let value = await task.value
        quotaInFlight = nil
        cachedQuota = (now(), value)
        return value
    }

    private static func fetchQuota(
        run: @Sendable ([String]) async throws -> Data, capturedAt: Date
    ) async -> UsageAvailability {
        do {
            let data = try await run(["quota", "show", "--output", "json", "--non-interactive", "--no-color"])
            return try parseQuota(data, capturedAt: capturedAt)
        } catch let error as MmxError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// `model_remains[]` 中取 `general`（没有就取第一项）：当前周期（end - start，本机为 5 小时）和每周两个窗口。
    /// `*_status == 3` 表示不限量，跳过该窗口。已用 = 100 - 剩余。
    static func parseQuota(_ data: Data, capturedAt: Date) throws -> UsageAvailability {
        guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
            throw MmxError.unexpectedFormat
        }
        if let base = response.baseResp, base.statusCode != 0 {
            return .failed("mmx：\(base.statusMsg ?? "错误码 \(base.statusCode)")")
        }
        let remains = response.modelRemains ?? []
        guard let entry = remains.first(where: { $0.modelName == "general" }) ?? remains.first else {
            return .noData
        }

        var windows: [UsageWindow] = []
        func add(id: String, start: Double?, end: Double?, remaining: Double?, status: Int?) {
            guard status != 3, let remaining else { return }
            let minutes = (start != nil && end != nil) ? Int(((end! - start!) / 60_000).rounded()) : nil
            windows.append(UsageWindow(
                id: id, windowMinutes: minutes, usedPercent: max(0, 100 - remaining),
                resetsAt: end.map { Date(timeIntervalSince1970: $0 / 1000) }))
        }
        add(id: "interval", start: entry.startTime, end: entry.endTime,
            remaining: entry.currentIntervalRemainingPercent, status: entry.currentIntervalStatus)
        add(id: "weekly", start: entry.weeklyStartTime, end: entry.weeklyEndTime,
            remaining: entry.currentWeeklyRemainingPercent, status: entry.currentWeeklyStatus)
        guard !windows.isEmpty else { return .noData }
        return .available(Usage(windows: windows, capturedAt: capturedAt, source: "mmx"))
    }

    // MARK: - 登录状态

    public func authStatus() async -> MmxAuthStatus {
        let data: Data
        do {
            data = try await run(["auth", "status", "--output", "json", "--non-interactive", "--no-color"])
        } catch let error as MmxError {
            return .failed(error.message)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let response = try? JSONDecoder().decode(AuthResponse.self, from: data) else {
            return .failed(MmxError.unexpectedFormat.message)
        }
        if let method = response.method {
            return .signedIn(method: method, tokenExpires: response.tokenExpires)
        }
        let message = response.error?.message ?? ""
        if message.range(of: "log", options: .caseInsensitive) != nil {
            return .signedOut
        }
        return .failed("mmx：\(message.isEmpty ? "未知错误" : message)")
    }

    // MARK: - 运行 mmx

    /// 从 Finder 启动的应用拿不到终端的 PATH，所以在常见安装位置查找 mmx。
    public static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/share/mise/shims/mmx",
            "/opt/homebrew/bin/mmx",
            "/usr/local/bin/mmx",
            "\(home)/.local/bin/mmx",
            "\(home)/.npm-global/bin/mmx",
            "\(home)/.bun/bin/mmx",
            "\(home)/.volta/bin/mmx",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public static func isInstalled() -> Bool { executableURL() != nil }

    /// 运行 mmx，返回标准输出和标准错误的合并内容（mmx 的 JSON 错误也可能出现在其中），超时则结束进程。
    static func runInstalledMmx(_ arguments: [String]) async throws -> Data {
        guard let executable = executableURL() else { throw MmxError.notInstalled }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // mmx 是 Node 脚本（#!/usr/bin/env node），需要在 PATH 里找到 node
        let path = [
            executable.deletingLastPathComponent().path, "\(home)/.local/share/mise/shims",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        ].joined(separator: ":")
        let environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = environment
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: MmxError.notInstalled)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: MmxError.timedOut)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

// MARK: - 输出格式（只建模用到的字段）

private struct QuotaResponse: Decodable {
    let modelRemains: [Remain]?
    let baseResp: BaseResp?

    struct Remain: Decodable {
        let modelName: String?
        let startTime: Double?
        let endTime: Double?
        let currentIntervalRemainingPercent: Double?
        let currentIntervalStatus: Int?
        let weeklyStartTime: Double?
        let weeklyEndTime: Double?
        let currentWeeklyRemainingPercent: Double?
        let currentWeeklyStatus: Int?

        private enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case startTime = "start_time"
            case endTime = "end_time"
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case currentIntervalStatus = "current_interval_status"
            case weeklyStartTime = "weekly_start_time"
            case weeklyEndTime = "weekly_end_time"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
            case currentWeeklyStatus = "current_weekly_status"
        }
    }

    struct BaseResp: Decodable {
        let statusCode: Int
        let statusMsg: String?

        private enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}

private struct AuthResponse: Decodable {
    let method: String?
    let tokenExpires: String?
    let error: ErrorBody?

    struct ErrorBody: Decodable {
        let message: String?
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case tokenExpires = "token_expires"
        case error
    }
}
