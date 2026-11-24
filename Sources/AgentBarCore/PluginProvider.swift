import Foundation

/// 用户插件：运行插件命令，把输出的 JSON 转成订阅信息（见 spec 第三版第 1 节）。
public struct PluginProvider: Provider {
    /// 标准输出的字节上限。
    public static let outputLimit = 64 * 1024

    public let manifest: PluginManifest
    /// 插件文件夹，也是命令的工作目录。
    public let directory: URL
    private let home: URL

    public var id: String { manifest.id }
    public var displayName: String { manifest.name }

    /// 插件文件夹里的 `icon.svg` / `icon.pdf` / `icon.png`（按此顺序）。
    public var iconURL: URL? { Self.iconURL(in: directory) }

    static func iconURL(in directory: URL) -> URL? {
        ["svg", "pdf", "png"]
            .map { directory.appendingPathComponent("icon.\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public init(manifest: PluginManifest, directory: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.manifest = manifest
        self.directory = directory
        self.home = home
    }

    /// `detect` 中任一路径存在即为已安装；没有 `detect` 时总是已安装。
    public func isInstalled() -> Bool {
        manifest.detect.isEmpty
            || manifest.detect.contains { FileManager.default.fileExists(atPath: resolve($0).path) }
    }

    public func fetchStatus() async throws -> SubscriptionStatus {
        var command = manifest.command
        if command[0].contains("/") {
            let executable = resolve(command[0])
            guard FileManager.default.fileExists(atPath: executable.path) else {
                throw ProviderError.unreadable("找不到插件命令 \(command[0])")
            }
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw ProviderError.unreadable("\(command[0]) 没有可执行权限（运行 chmod +x）")
            }
            command[0] = executable.path
        }

        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                command, in: directory, environment: environment(),
                timeout: TimeInterval(manifest.timeoutSeconds), outputLimit: Self.outputLimit)
        } catch let failure as ProcessRunner.Failure {
            switch failure {
            case .launchFailed(let reason): throw ProviderError.unreadable("插件无法启动：\(reason)")
            case .timedOut: throw ProviderError.unreadable("插件运行超时（\(manifest.timeoutSeconds) 秒）")
            case .outputTooLarge: throw ProviderError.unreadable("插件输出超过 \(Self.outputLimit / 1024) KB")
            }
        }

        guard output.exitCode == 0 else {
            let lastLine = String(decoding: output.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            throw ProviderError.unreadable(lastLine ?? "插件异常退出（退出码 \(output.exitCode)）")
        }

        do {
            switch try PluginOutput.parse(output.stdout) {
            case .status(let status): return status
            case .error(let reason): throw ProviderError.unreadable(reason)
            }
        } catch let error as PluginFormatError {
            throw ProviderError.unreadable("插件输出格式错误：\(error.message)")
        }
    }

    /// `~/` 开头的相对 home，其他相对路径相对插件文件夹。
    private func resolve(_ path: String) -> URL {
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return directory.appendingPathComponent(path).standardizedFileURL
    }

    /// 从 Finder 启动的应用拿不到终端的 PATH，补上常见的安装位置。
    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let common = [
            "\(home.path)/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home.path)/.local/bin", "\(home.path)/.bun/bin", "\(home.path)/.volta/bin",
            "\(home.path)/.npm-global/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        environment["PATH"] = (common + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        environment["AGENTBAR_PLUGIN_API"] = String(PluginManifest.apiVersion)
        environment["AGENTBAR_PLUGIN_DIR"] = directory.path
        return environment
    }
}

/// 在 `~/.config/agentbar/plugins/` 下发现插件。
public enum PluginDiscovery {
    /// 一个插件文件夹：清单解析成功，或出错原因。
    public struct Entry: Sendable {
        public let directory: URL
        public let result: Result<PluginManifest, PluginFormatError>

        public var manifest: PluginManifest? { try? result.get() }
        public var error: PluginFormatError? {
            if case .failure(let error) = result { return error }
            return nil
        }
    }

    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".config/agentbar/plugins", isDirectory: true)
    }

    /// 插件文件夹（不含隐藏文件夹），按文件夹名排序。文件夹名必须与清单里的 `id` 一致。
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, reservedIDs: Set<String>
    ) -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root(home: home), includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }

        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { directory in
                Entry(directory: directory, result: Result { () throws(PluginFormatError) -> PluginManifest in
                    let file = directory.appendingPathComponent("plugin.json")
                    guard let data = try? Data(contentsOf: file) else {
                        throw PluginFormatError(field: nil, "缺少 plugin.json")
                    }
                    let manifest = try PluginManifest.parse(data, reservedIDs: reservedIDs)
                    let folder = directory.lastPathComponent
                    guard manifest.id == folder else {
                        throw PluginFormatError(field: "id", "应与文件夹名 \"\(folder)\" 一致，实际是 \"\(manifest.id)\"")
                    }
                    return manifest
                })
            }
    }
}
