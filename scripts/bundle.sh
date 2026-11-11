#!/bin/sh
# 构建 release 版本并打包成 build/AgentBar.app（状态栏应用，不在 Dock 显示）。
# 签名身份通过环境变量 SIGN_IDENTITY 指定，默认 "-"（ad-hoc 签名）。
# 版本号只在 Sources/AgentBarCore/AgentBarCore.swift 里定义，这里从源码中读取。
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/AgentBarCore/AgentBarCore.swift)"
if [ -z "$VERSION" ]; then
    echo "无法从 AgentBarCore.swift 读取版本号" >&2
    exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/AgentBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AgentBar" "$APP/Contents/MacOS/AgentBar"
# SwiftPM 资源包（有资源时才会生成）
for BUNDLE in "$BIN_DIR"/*.bundle; do
    [ -e "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentBar</string>
    <key>CFBundleIdentifier</key><string>local.agentbar</string>
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
