#!/bin/sh
# 运行测试。只装了 Command Line Tools（没有 Xcode）时，swift-testing 不在默认搜索路径上，
# 而且 SwiftPM 生成的测试 runner 也需要能 import Testing，所以必须用全局参数传给所有 target。
set -eu
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ ! -d /Applications/Xcode.app ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
    exec swift test \
        -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/usr/lib" \
        "$@"
fi
exec swift test "$@"
