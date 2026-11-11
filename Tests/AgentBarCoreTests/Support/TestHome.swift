import Foundation

/// 为测试构造一个临时的 home 目录。
///
/// 传入 `fixture` 时，把 `Tests/Fixtures/<fixture>/` 的内容（包括隐藏文件）复制进去；
/// 也可以用 `write(_:to:)` 在里面直接生成文件（例如测试代码生成的 JWT、SQLite）。
struct TestHome {
    let url: URL

    init(fixture: String? = nil) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBarTests-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        if let fixture {
            let source = Self.fixturesDirectory.appendingPathComponent(fixture, isDirectory: true)
            try fm.copyItem(at: source, to: url)
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// 仓库中的 `Tests/Fixtures/` 目录。
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // AgentBarCoreTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// 把 `contents` 写到 home 下的相对路径 `path`，自动创建中间目录。
    func write(_ contents: Data, to path: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file)
    }

    func write(_ contents: String, to path: String) throws {
        try write(Data(contents.utf8), to: path)
    }

    func path(_ relative: String) -> URL {
        url.appendingPathComponent(relative)
    }
}
