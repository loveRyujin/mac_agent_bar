import Foundation

/// `agentbar plugin …` 命令：开发插件时生成骨架、校验插件（spec 第三版第 4 节）。
/// 校验与应用内用的是同一套解析和运行代码。
public struct PluginCLI: Sendable {
    /// 退出码：0 通过，1 校验失败，2 用法错误。
    public enum ExitCode {
        public static let success: Int32 = 0
        public static let failure: Int32 = 1
        public static let usage: Int32 = 2
    }

    public static let guideURL = "https://github.com/loveRyujin/mac_agent_bar/blob/main/docs/plugins.md"

    private let home: URL
    private let out: @Sendable (String) -> Void
    private let err: @Sendable (String) -> Void

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        out: @escaping @Sendable (String) -> Void = { print($0) },
        err: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.home = home
        self.out = out
        self.err = err
    }

    /// - Parameter arguments: `plugin` 之后的参数，例如 `["check", "./my-agent"]`。
    public func run(_ arguments: [String]) async -> Int32 {
        switch arguments.first {
        case "help", "-h", "--help":
            out(Self.usage)
            return ExitCode.success
        case "check" where arguments.count == 2:
            return await check(URL(fileURLWithPath: arguments[1]))
        case "new" where arguments.count == 2:
            return new(id: arguments[1], parent: PluginDiscovery.root(home: home))
        case "new" where arguments.count == 4 && arguments[2] == "--dir":
            return new(id: arguments[1], parent: URL(fileURLWithPath: arguments[3]))
        default:
            err(Self.usage)
            return ExitCode.usage
        }
    }

    static let usage = """
        用法：
          agentbar plugin new <id> [--dir <父目录>]   生成插件骨架（默认放在 ~/.config/agentbar/plugins/）
          agentbar plugin check <插件文件夹>          校验清单、运行一次插件、校验输出
          agentbar plugin help                        显示本说明

        插件格式见 \(guideURL)
        """

    // MARK: - check

    private func check(_ directory: URL) async -> Int32 {
        let manifest: PluginManifest
        switch PluginDiscovery.load(directory, reservedIDs: ProviderRegistry.builtInIDs) {
        case .failure(let error):
            err("✗ plugin.json：\(error.message)")
            return ExitCode.failure
        case .success(let value):
            manifest = value
        }

        let provider = PluginProvider(manifest: manifest, directory: directory, home: home)
        out("插件 \(manifest.name)（\(manifest.id)）")
        out("  位置：\(display(directory))")
        out("  命令：\(manifest.command.joined(separator: " "))（超时 \(manifest.timeoutSeconds) 秒）")
        if manifest.detect.isEmpty {
            out("  安装检测：没有 detect，总是视为已安装")
        } else {
            let state = provider.isInstalled() ? "已安装" : "未安装（AgentBar 不会显示它）"
            out("  安装检测：\(manifest.detect.joined(separator: "、")) → \(state)")
        }

        let start = Date()
        let run = await provider.execute()
        out("")
        out(String(format: "运行（%.2f 秒）：", Date().timeIntervalSince(start)))

        switch run.result {
        case .success(let status):
            describe(status)
            showStderr(run.stderr)
            out("")
            out("✓ 通过")
            return ExitCode.success
        case .failure(let error) where run.isReportedError:
            out("  插件报告读取失败：\(error.message)")
            out("  （面板会显示这个原因并带红点）")
            showStderr(run.stderr)
            out("")
            out("✓ 通过（输出格式正确）")
            return ExitCode.success
        case .failure(let error):
            err("✗ \(error.message)")
            if !run.stdout.isEmpty {
                err("标准输出：")
                err(excerpt(run.stdout))
            }
            if !run.stderr.isEmpty {
                err("标准错误：")
                err(excerpt(run.stderr))
            }
            return ExitCode.failure
        }
    }

    private func describe(_ status: SubscriptionStatus) {
        let plan = status.plan
        out("  套餐：\(plan.displayName)" + (plan.shortName == plan.displayName ? "" : "（状态栏：\(plan.shortName)）"))
        out("  状态：\(Self.label(status.state))")
        if let account = status.account { out("  账号：\(account)") }
        if let organization = status.organization { out("  组织：\(organization)") }
        if let periodEnd = status.periodEnd { out("  到期/续费：\(format(periodEnd))") }
        if let usage = status.usage.usage {
            out("  用量：")
            for window in usage.windows {
                let reset = window.resetsAt.map { "  重置于 \(format($0))" } ?? ""
                out("    \(window.name)  \(String(format: "%g", window.usedPercent))%\(reset)")
            }
        } else if let reason = status.usage.unavailableReason {
            out("  用量：\(reason)")
        }
    }

    private func showStderr(_ stderr: Data) {
        guard !stderr.isEmpty else { return }
        out("  标准错误（AgentBar 不显示，仅供调试）：")
        out(excerpt(stderr))
    }

    private static func label(_ state: SubscriptionStatus.State) -> String {
        switch state {
        case .active: "有效"
        case .trial: "试用中"
        case .expired: "已过期"
        case .signedOut: "未登录"
        case .unknown: "未知"
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 输出摘录：最多 2000 个字符，每行缩进。
    private func excerpt(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 2000 { text = String(text.prefix(2000)) + "…" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    private func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: - new

    private func new(id: String, parent: URL) -> Int32 {
        let manifest = PluginManifest(id: id, name: id, command: ["./status"])
        // 借用清单校验来检查 id
        let json = #"{"apiVersion":1,"id":"\#(id)","name":"x","command":["x"]}"#
        do {
            _ = try PluginManifest.parse(Data(json.utf8), reservedIDs: ProviderRegistry.builtInIDs)
        } catch {
            err("✗ \(error.message)")
            return ExitCode.failure
        }

        let directory = parent.appendingPathComponent(id, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: directory.path) else {
            err("✗ \(display(directory)) 已存在")
            return ExitCode.failure
        }

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.manifestTemplate(manifest).write(to: directory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
            let script = directory.appendingPathComponent("status")
            try Self.scriptTemplate(id: id).write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            err("✗ 无法创建 \(display(directory))：\(error.localizedDescription)")
            return ExitCode.failure
        }

        let inPluginFolder = parent.standardizedFileURL.path == PluginDiscovery.root(home: home).standardizedFileURL.path
        out("已创建 \(directory.path)")
        out("  plugin.json  清单（名称、命令、安装检测）")
        out("  status       插件脚本：把订阅信息以 JSON 打印到标准输出")
        out("")
        out("下一步：")
        out("  1. 编辑 status，输出真实的数据（格式见 \(Self.guideURL)）")
        out("  2. agentbar plugin check \(directory.path)")
        if inPluginFolder {
            out("  3. 在 AgentBar 设置 → 插件 中确认开启")
        } else {
            out("  3. 把文件夹放进 ~/.config/agentbar/plugins/，在 AgentBar 设置 → 插件 中确认开启")
        }
        return ExitCode.success
    }

    private static func manifestTemplate(_ manifest: PluginManifest) -> String {
        """
        {
          "apiVersion": 1,
          "id": "\(manifest.id)",
          "name": "\(manifest.name)",
          "command": ["./status"],
          "detect": [],
          "timeoutSeconds": \(manifest.timeoutSeconds)
        }

        """
    }

    private static func scriptTemplate(id: String) -> String {
        #"""
        #!/bin/sh
        # AgentBar 插件：\#(id)
        #
        # 把订阅信息以 JSON 打印到标准输出，格式见：
        #   \#(guideURL)
        # 读取失败时输出 {"error": "给用户看的原因"}。
        # 调试：agentbar plugin check <本文件夹>
        #
        # 不要在本文件夹里写缓存等非隐藏文件：内容一变，插件就需要用户重新确认。

        cat <<'JSON'
        {
          "plan": "Free",
          "state": "unknown"
        }
        JSON

        """#
    }
}
