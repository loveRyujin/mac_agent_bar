import AppKit
import SwiftUI

/// 加载 agent 的单色 logo（PDF 资源）。
enum AgentIcons {
    /// 按资源名加载 logo，设为 template image（随深浅色自动着色）；找不到时返回 nil。
    static func image(named name: String, size: CGFloat) -> NSImage? {
        guard let url = resourceBundle?.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    /// SwiftPM 生成的 `Bundle.module` 只在 .app 根目录和编译目录里找资源包，找不到会直接崩溃；
    /// 而资源包放在 .app 根目录会破坏签名。所以这里自己找：先找 `Contents/Resources`（打包后），
    /// 再找可执行文件旁边（`swift run`）。
    private static let resourceBundle: Bundle? = {
        let name = "AgentBar_AgentBar.bundle"
        let directories = [
            Bundle.main.resourceURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for case let directory? in directories {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) {
                return bundle
            }
        }
        return nil
    }()
}

/// agent 图标；没有图标资源时显示名称首字母。
struct AgentIconView: View {
    let iconName: String?
    let displayName: String
    var size: CGFloat = 16

    var body: some View {
        if let iconName, let image = AgentIcons.image(named: iconName, size: size) {
            Image(nsImage: image)
        } else {
            Text(displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.8, weight: .semibold))
                .frame(width: size, height: size)
        }
    }
}
