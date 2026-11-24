import Foundation

/// Gemini CLI 的 OAuth 客户端 ID 和密钥，刷新登录时需要。
///
/// 不内置在本仓库里，而是从本机安装的 Gemini CLI 包中读取（它写在 Gemini CLI 的代码里，
/// 见其 `packages/core/src/code_assist/oauth2.ts`）。找不到时不刷新。
public struct GeminiOAuthClient: Sendable, Equatable {
    public let id: String
    public let secret: String

    /// 单个文件超过这个大小就不扫描。
    static let maxFileSize = 40 * 1024 * 1024
    /// 兜底扫描时最多看多少个文件。
    static let maxScannedFiles = 400

    /// 在常见安装位置找 Gemini CLI 的包，从中读出客户端信息。
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> GeminiOAuthClient? {
        for root in packageRoots(home: home) {
            if let client = find(inPackage: root) { return client }
        }
        return nil
    }

    /// 可能的 `@google/gemini-cli` 包目录（已确认 package.json 的 name），去重并保持顺序。
    static func packageRoots(home: URL) -> [URL] {
        let fm = FileManager.default
        let h = home.path
        let package = "lib/node_modules/@google/gemini-cli"
        var candidates: [URL] = []

        // 1. 顺着 gemini 可执行文件的符号链接往上找（npm、Homebrew）
        let binaries = [
            "/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "\(h)/.local/bin/gemini",
            "\(h)/.npm-global/bin/gemini", "\(h)/.bun/bin/gemini",
        ]
        for binary in binaries where fm.fileExists(atPath: binary) {
            var directory = URL(fileURLWithPath: binary).resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(directory)
                directory.deleteLastPathComponent()
            }
        }

        // 2. 全局 node_modules 的常见位置
        candidates += [
            "/opt/homebrew/\(package)", "/usr/local/\(package)", "/opt/homebrew/opt/gemini-cli/libexec/\(package)",
            "/usr/local/opt/gemini-cli/libexec/\(package)", "\(h)/.npm-global/\(package)",
            "\(h)/.bun/install/global/node_modules/@google/gemini-cli",
            "\(h)/.volta/tools/image/packages/@google/gemini-cli/\(package)",
        ].map(URL.init(fileURLWithPath:))

        // 3. 按 Node 版本分目录的安装（mise、nvm）
        for (parent, depth) in [("\(h)/.local/share/mise/installs", 2), ("\(h)/.nvm/versions/node", 1)] {
            for directory in subdirectories(of: URL(fileURLWithPath: parent), depth: depth) {
                candidates.append(directory.appendingPathComponent(package))
            }
        }

        var seen = Set<String>()
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted && isGeminiPackage(url)
        }
    }

    /// 在包里找同时含有客户端 ID 和密钥的 JS 文件：先看已知位置，再有限地扫描其他 JS 文件。
    static func find(inPackage root: URL) -> GeminiOAuthClient? {
        let known = [
            "bundle/gemini.js",
            "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "../gemini-cli-core/dist/src/code_assist/oauth2.js",
        ].map { root.appendingPathComponent($0).standardizedFileURL }
        for file in known {
            if let client = extract(from: file) { return client }
        }

        let fm = FileManager.default
        var scanned = 0
        for directory in ["bundle", "dist", "node_modules/@google/gemini-cli-core/dist"] {
            let enumerator = fm.enumerator(
                at: root.appendingPathComponent(directory), includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
            while let file = enumerator?.nextObject() as? URL {
                guard ["js", "mjs", "cjs"].contains(file.pathExtension) else { continue }
                // 跳过这些目录里再嵌套的其他依赖
                if file.pathComponents.dropFirst(root.pathComponents.count + 1).contains("node_modules") { continue }
                scanned += 1
                if scanned > maxScannedFiles { return nil }
                if let client = extract(from: file) { return client }
            }
        }
        return nil
    }

    /// 从一个文件里取出客户端 ID 和密钥；两者都在才算找到。
    static func extract(from file: URL) -> GeminiOAuthClient? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maxFileSize,
              let data = try? Data(contentsOf: file)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let id = text.firstMatch(of: /[0-9]{6,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com/),
              let secret = text.firstMatch(of: /GOCSPX-[A-Za-z0-9_\-]{20,}/)
        else { return nil }
        return GeminiOAuthClient(id: String(id.output), secret: String(secret.output))
    }

    private static func isGeminiPackage(_ directory: URL) -> Bool {
        struct Package: Decodable { let name: String? }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")) else { return false }
        return (try? JSONDecoder().decode(Package.self, from: data))?.name == "@google/gemini-cli"
    }

    private static func subdirectories(of directory: URL, depth: Int) -> [URL] {
        guard depth > 0,
              let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        else { return [] }
        let directories = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return depth == 1 ? directories : directories.flatMap { subdirectories(of: $0, depth: depth - 1) }
    }
}
