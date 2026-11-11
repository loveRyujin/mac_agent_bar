// 把 SVG 转换成矢量 PDF（用 NSImage 自带的 SVG 解析，需要较新的 macOS；只在开发机上运行一次）。
// 用法：swift scripts/svg2pdf.swift <input.svg> <output.pdf>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("用法：swift scripts/svg2pdf.swift <input.svg> <output.pdf>\n".utf8))
    exit(2)
}

let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: input), image.size.width > 0 else {
    FileHandle.standardError.write(Data("无法读取 SVG：\(input.path)\n".utf8))
    exit(1)
}

var box = CGRect(origin: .zero, size: image.size)
guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else {
    FileHandle.standardError.write(Data("无法创建 PDF：\(output.path)\n".utf8))
    exit(1)
}

context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: box)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
