import Foundation

/// 插件清单或输出的格式错误。`field` 是出错字段的路径（如 "usage.windows[0].usedPercent"），
/// 整体无法解析时为 nil。
public struct PluginFormatError: Error, Sendable, Equatable {
    public var field: String?
    public var reason: String

    public init(field: String?, _ reason: String) {
        self.field = field
        self.reason = reason
    }

    /// 给用户和 coding agent 看的说明，例如 “state：应为 active / trial / … 之一，实际是 "paid"”。
    public var message: String {
        field.map { "\($0)：\(reason)" } ?? reason
    }
}

/// 插件的 `plugin.json`（apiVersion 1）。
public struct PluginManifest: Sendable, Equatable {
    public static let apiVersion = 1
    public static let defaultTimeoutSeconds = 20
    public static let maxTimeoutSeconds = 60

    /// 只能用小写字母、数字和 `-`，作为设置里的稳定标识。
    public var id: String
    public var name: String
    /// 要执行的命令和参数；相对路径以插件目录为准。
    public var command: [String]
    /// 任一路径存在即视为已安装；为空时总是视为已安装。
    public var detect: [String]
    public var timeoutSeconds: Int

    public init(id: String, name: String, command: [String], detect: [String] = [],
                timeoutSeconds: Int = PluginManifest.defaultTimeoutSeconds) {
        self.id = id
        self.name = name
        self.command = command
        self.detect = detect
        self.timeoutSeconds = timeoutSeconds
    }

    /// 解析并校验清单。
    /// - Parameter reservedIDs: 不能使用的 id（内置 agent 的 id）。
    public static func parse(_ data: Data, reservedIDs: Set<String> = []) throws(PluginFormatError) -> PluginManifest {
        let json = try JSONObject(data, what: "plugin.json")

        guard let version = json.integer("apiVersion") else {
            throw PluginFormatError(field: "apiVersion", json.has("apiVersion") ? "应为整数" : "缺少该字段")
        }
        guard version == apiVersion else {
            throw PluginFormatError(field: "apiVersion", "不支持的版本 \(version)，当前支持 \(apiVersion)")
        }

        let id = try json.requiredString("id")
        guard id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil else {
            throw PluginFormatError(field: "id", "只能用小写字母、数字和 -（不能以 - 开头或结尾），实际是 \"\(id)\"")
        }
        guard !reservedIDs.contains(id) else {
            throw PluginFormatError(field: "id", "\"\(id)\" 与内置 agent 重名")
        }

        let name = try json.requiredString("name")
        guard let command = try json.stringArray("command"), !command.isEmpty else {
            throw PluginFormatError(field: "command", json.has("command") ? "至少要有一项" : "缺少该字段")
        }
        let detect = try json.stringArray("detect") ?? []

        var timeout = defaultTimeoutSeconds
        if json.has("timeoutSeconds") {
            guard let value = json.integer("timeoutSeconds"), (1...maxTimeoutSeconds).contains(value) else {
                throw PluginFormatError(field: "timeoutSeconds", "应为 1–\(maxTimeoutSeconds) 的整数")
            }
            timeout = value
        }

        return PluginManifest(id: id, name: name, command: command, detect: detect, timeoutSeconds: timeout)
    }
}

/// 插件一次运行的输出：订阅信息，或插件自己报告的错误。
public enum PluginOutput: Sendable, Equatable {
    case status(SubscriptionStatus)
    /// 插件输出了 `{"error": "原因"}`。
    case error(String)

    private static let states: [(String, SubscriptionStatus.State)] = [
        ("active", .active), ("trial", .trial), ("expired", .expired), ("signedOut", .signedOut), ("unknown", .unknown),
    ]

    /// 解析并校验插件打印到 stdout 的 JSON（apiVersion 1）。未知字段忽略。
    public static func parse(_ data: Data) throws(PluginFormatError) -> PluginOutput {
        let json = try JSONObject(data, what: "输出")

        if let error = try json.optionalString("error") {
            return .error(error)
        }

        let planName = try json.requiredString("plan")
        let plan = Plan(rawValue: planName, displayName: planName, shortName: try json.optionalString("planShortName"))

        let rawState = try json.requiredString("state")
        guard let state = states.first(where: { $0.0 == rawState })?.1 else {
            let allowed = states.map(\.0).joined(separator: " / ")
            throw PluginFormatError(field: "state", "应为 \(allowed) 之一，实际是 \"\(rawState)\"")
        }

        return .status(SubscriptionStatus(
            plan: plan,
            state: state,
            account: try json.optionalString("account"),
            organization: try json.optionalString("organization"),
            periodEnd: try json.optionalDate("periodEnd"),
            usage: try usage(json)))
    }

    private static func usage(_ json: JSONObject) throws(PluginFormatError) -> UsageAvailability {
        guard let usage = try json.optionalObject("usage") else { return .unsupported }

        if let reason = try usage.optionalString("unavailable") {
            return .failed(reason)
        }
        guard let items = usage.value("windows") as? [Any] else {
            throw PluginFormatError(field: usage.path("windows"), usage.has("windows") ? "应为数组" : "缺少该字段")
        }
        let capturedAt = try usage.optionalDate("capturedAt")
        guard !items.isEmpty else { return .noData }

        var windows: [UsageWindow] = []
        for (index, item) in items.enumerated() {
            let path = usage.path("windows") + "[\(index)]"
            guard let dict = item as? [String: Any] else {
                throw PluginFormatError(field: path, "应为对象")
            }
            let window = JSONObject(dict, path: path)

            let label = try window.optionalString("label")
            var minutes: Int?
            if window.has("windowMinutes") {
                guard let value = window.integer("windowMinutes"), value > 0 else {
                    throw PluginFormatError(field: window.path("windowMinutes"), "应为正整数（分钟）")
                }
                minutes = value
            }
            guard label != nil || minutes != nil else {
                throw PluginFormatError(field: path, "需要 label 或 windowMinutes 来命名这个窗口")
            }
            guard let percent = window.number("usedPercent"), percent >= 0 else {
                throw PluginFormatError(
                    field: window.path("usedPercent"),
                    window.has("usedPercent") ? "应为不小于 0 的数字（0–100）" : "缺少该字段")
            }
            windows.append(UsageWindow(
                id: String(index), windowMinutes: minutes, usedPercent: percent,
                resetsAt: try window.optionalDate("resetsAt"), label: label))
        }
        return .available(Usage(windows: windows, capturedAt: capturedAt))
    }
}

/// 带路径的 JSON 对象读取器，出错时报告字段路径。
private struct JSONObject {
    let dict: [String: Any]
    /// 本对象在整个文档中的路径；顶层为空。
    let prefix: String

    init(_ dict: [String: Any], path: String) {
        self.dict = dict
        prefix = path
    }

    init(_ data: Data, what: String) throws(PluginFormatError) {
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            throw PluginFormatError(field: nil, "\(what)不是合法的 JSON")
        }
        guard let dict = any as? [String: Any] else {
            throw PluginFormatError(field: nil, "\(what)应为 JSON 对象（{ … }）")
        }
        self.init(dict, path: "")
    }

    func path(_ key: String) -> String { prefix.isEmpty ? key : "\(prefix).\(key)" }

    /// 字段存在且不为 null。
    func has(_ key: String) -> Bool { value(key) != nil }

    /// 字段值；缺失或为 null 时为 nil。
    func value(_ key: String) -> Any? {
        guard let value = dict[key], !(value is NSNull) else { return nil }
        return value
    }

    /// 数字（不含 true / false）。
    func number(_ key: String) -> Double? {
        guard let number = value(key) as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    func integer(_ key: String) -> Int? {
        guard let number = number(key), number == number.rounded(), abs(number) < 1e15 else { return nil }
        return Int(number)
    }

    /// 可选的非空字符串；缺失或为 null 时为 nil。
    func optionalString(_ key: String) throws(PluginFormatError) -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value as? String else {
            throw PluginFormatError(field: path(key), "应为字符串")
        }
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginFormatError(field: path(key), "不能为空字符串（没有值时省略该字段或写 null）")
        }
        return string
    }

    func requiredString(_ key: String) throws(PluginFormatError) -> String {
        guard let string = try optionalString(key) else {
            throw PluginFormatError(field: path(key), "缺少该字段")
        }
        return string
    }

    func optionalDate(_ key: String) throws(PluginFormatError) -> Date? {
        guard let value = value(key) else { return nil }
        guard let string = value as? String, let date = DateParsing.iso8601(string) else {
            throw PluginFormatError(field: path(key), "应为 ISO 8601 时间字符串，例如 \"2026-12-01T00:00:00Z\"")
        }
        return date
    }

    func optionalObject(_ key: String) throws(PluginFormatError) -> JSONObject? {
        guard let value = value(key) else { return nil }
        guard let dict = value as? [String: Any] else {
            throw PluginFormatError(field: path(key), "应为对象")
        }
        return JSONObject(dict, path: path(key))
    }

    /// 可选的非空字符串数组；缺失或为 null 时为 nil。
    func stringArray(_ key: String) throws(PluginFormatError) -> [String]? {
        guard let value = value(key) else { return nil }
        guard let items = value as? [Any] else {
            throw PluginFormatError(field: path(key), "应为字符串数组")
        }
        return try items.enumerated().map { (index, item) throws(PluginFormatError) -> String in
            guard let string = item as? String, !string.isEmpty else {
                throw PluginFormatError(field: path(key) + "[\(index)]", "应为非空字符串")
            }
            return string
        }
    }
}
