#!/bin/sh
# 构建 release 版本并打包成 AgentBar.app（状态栏应用，不在 Dock 显示）。
# 用法：scripts/bundle.sh [--disable-sandbox] [--output <目录>]
#   --disable-sandbox  关闭 SwiftPM 自己的沙盒（Homebrew 已在沙盒中构建，两者会冲突）
#   --output <目录>    .app 的输出目录，默认 build
# 签名身份通过环境变量 SIGN_IDENTITY 指定，默认 "-"（ad-hoc 签名）。
# 版本号只在 Sources/AgentBarCore/AgentBarCore.swift 里定义，这里从源码中读取。
set -eu
cd "$(dirname "$0")/.."

SWIFT_FLAGS=""
OUTPUT_DIR=build
while [ $# -gt 0 ]; do
    case "$1" in
        --disable-sandbox) SWIFT_FLAGS="--disable-sandbox"; shift ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/AgentBarCore/AgentBarCore.swift)"
if [ -z "$VERSION" ]; then
    echo "无法从 AgentBarCore.swift 读取版本号" >&2
    exit 1
fi

swift build -c release $SWIFT_FLAGS
BIN_DIR="$(swift build -c release $SWIFT_FLAGS --show-bin-path)"

APP="$OUTPUT_DIR/AgentBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBar" "$APP/Contents/MacOS/AgentBar"
# SwiftPM 资源包（有资源时才会生成）
for BUNDLE in "$BIN_DIR"/*.bundle; do
    [ -e "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"
done
# 应用图标（由 scripts/make-app-icon.swift 生成）
cp assets/logo/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>io.github.loveryujin.agentbar</string>
    <key>CFBundleName</key><string>AgentBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "已生成 ${APP}（版本 ${VERSION}）"
