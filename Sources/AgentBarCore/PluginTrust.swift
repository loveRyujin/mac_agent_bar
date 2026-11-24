import CryptoKit
import Foundation

/// 插件文件夹内容的指纹：用户确认开启时记下，内容一变就需要重新确认（spec 第三版第 2 节）。
public enum PluginFingerprint {
    /// 超过这个大小的文件只计入大小和修改时间，不读内容。
    static let contentLimit = 4 * 1024 * 1024

    /// 所有非隐藏文件的相对路径和内容的 SHA-256（十六进制）。隐藏文件（如 `.DS_Store`）不计入。
    public static func compute(_ directory: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var hasher = SHA256()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: keys, options: .skipsHiddenFiles)

        var files: [(path: String, url: URL)] = []
        while let url = enumerator?.nextObject() as? URL {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            files.append((relative, url))
        }

        for (path, url) in files.sorted(by: { $0.path < $1.path }) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                hasher.update(data: Data("link\0\(path)\0\(target)\0".utf8))
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            hasher.update(data: Data("file\0\(path)\0\(size)\0".utf8))
            if size <= contentLimit, let data = try? Data(contentsOf: url) {
                hasher.update(data: data)
            } else {
                let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                hasher.update(data: Data("\(modified)\0".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 一个插件文件夹在设置里的状态。
public struct PluginItem: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// 已确认，内容没变，会运行。
        case enabled
        /// 需要用户确认后才会运行。`changed` 为 true 表示确认过，但之后内容有变化。
        case needsApproval(changed: Bool)
        /// 清单有错，参数是给用户看的原因。
        case invalid(String)
    }

    /// 清单里的 id；清单无法解析时是文件夹名。
    public let id: String
    public let directory: URL
    public let manifest: PluginManifest?
    /// 清单有效时的内容指纹。
    public let fingerprint: String?
    public let state: State

    /// 设置里显示的名称。
    public var displayName: String { manifest?.name ?? directory.lastPathComponent }

    public var iconURL: URL? { PluginProvider.iconURL(in: directory) }
}

/// 把发现的插件和用户确认记录合在一起。
public enum PluginCatalog {
    /// - Parameter trusted: 用户确认过的插件 id → 确认时的指纹（`AppSettings.trustedPlugins`）。
    public static func load(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        reservedIDs: Set<String> = ProviderRegistry.builtInIDs,
        trusted: [String: String]
    ) -> [PluginItem] {
        PluginDiscovery.discover(home: home, reservedIDs: reservedIDs).map { entry in
            switch entry.result {
            case .failure(let error):
                return PluginItem(
                    id: entry.directory.lastPathComponent, directory: entry.directory,
                    manifest: nil, fingerprint: nil, state: .invalid(error.message))
            case .success(let manifest):
                let fingerprint = PluginFingerprint.compute(entry.directory)
                let state: PluginItem.State = switch trusted[manifest.id] {
                case fingerprint: .enabled
                case nil: .needsApproval(changed: false)
                default: .needsApproval(changed: true)
                }
                return PluginItem(
                    id: manifest.id, directory: entry.directory,
                    manifest: manifest, fingerprint: fingerprint, state: state)
            }
        }
    }

    /// 已确认且内容未变的插件对应的 provider。
    public static func enabledProviders(
        _ items: [PluginItem], home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [PluginProvider] {
        items.compactMap { item in
            guard item.state == .enabled, let manifest = item.manifest else { return nil }
            return PluginProvider(manifest: manifest, directory: item.directory, home: home)
        }
    }
}
