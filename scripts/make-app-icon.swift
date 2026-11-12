// 由单色 logo SVG 生成应用图标 .icns：石墨灰圆角方块底 + 白色 logo，按 macOS 图标网格排版
// （1024 画布上 824 的圆角方块）。用系统自带的 iconutil 打包，不依赖 Xcode；只在开发机上运行。
// 用法：swift scripts/make-app-icon.swift <logo.svg> <output.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("用法：swift scripts/make-app-icon.swift <logo.svg> <output.icns>\n".utf8))
    exit(2)
}
guard let logo = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write(Data("无法读取 SVG：\(args[1])\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: args[2])

/// 画一张 `pixels` × `pixels` 的图标。
func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024

    // 圆角方块（带轻微投影）
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        .applying(CGAffineTransform(scaleX: scale, y: scale))
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.shadowBlurRadius = 20 * scale
    shadow.set()
    NSColor(srgbRed: 0x1b / 255.0, green: 0x1e / 255.0, blue: 0x23 / 255.0, alpha: 1).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(
        starting: NSColor(srgbRed: 0x3a / 255.0, green: 0x40 / 255.0, blue: 0x49 / 255.0, alpha: 1),
        ending: NSColor(srgbRed: 0x1b / 255.0, green: 0x1e / 255.0, blue: 0x23 / 255.0, alpha: 1)
    )!.draw(in: tilePath, angle: -90)

    // 白色 logo，占方块的 62%，居中
    let side = tile.width * 0.62
    let glyphRect = NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    let white = NSImage(size: logo.size, flipped: false) { rect in
        logo.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    white.draw(in: glyphRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try! render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try! render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
