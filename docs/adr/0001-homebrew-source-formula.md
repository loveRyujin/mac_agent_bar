# ADR-0001：通过自建 tap 的源码 formula 分发，不使用 Apple 开发者账号

- 状态：已接受
- 日期：2026-11-11

## 背景

AgentBar 计划通过 Homebrew 分发。项目没有付费的 Apple 开发者账号，因此无法做 Developer ID 签名，也无法公证（notarization）。

现有的分发渠道是 **GitHub Releases**：推送 `v*` tag 后，`.github/workflows/release.yml` 会打包一个 ad-hoc 签名的 zip，并附加到 Release 上。用户下载后需要自己执行 `xattr -dr com.apple.quarantine` 才能绕过 Gatekeeper，原因见下文。

macOS 会给从网上下载的文件打上隔离标记（`com.apple.quarantine`）。第一次打开带这个标记的 `.app` 时，Gatekeeper 会检查它有没有 Developer ID 签名、有没有经过公证。没有的话，新版 macOS 会直接阻止运行，用户只能去“系统设置 → 隐私与安全性”里手动放行。macOS 15 起，右键“打开”这种绕过方式也不再可用。

Homebrew 有两种安装方式：

| | Cask | 从源码构建的 Formula |
|---|---|---|
| 安装内容 | 预先编译好的 `.app` 压缩包 | 源码，在用户机器上编译 |
| 隔离标记 | 有（等同于从网上下载） | 无（本机编译的产物不带隔离标记） |
| Gatekeeper | 检查签名和公证 | 不检查，ad-hoc 签名即可运行 |
| 是否需要开发者账号 | 实际上需要（官方 cask 仓库也要求签名并公证） | 不需要 |

## 决策

采用**自建 tap（`loveRyujin/homebrew-agentbar`）+ 从源码构建的 formula** 作为推荐的安装方式：

- formula 从源码仓库 `loveRyujin/mac_agent_bar` 对应 tag 的源码包构建。用户执行 `brew install` 时，在本机运行 `swift build` 编译，然后打包成 `AgentBar.app`，安装到 Homebrew 的安装目录。
- 发版仍然由现有的 `release.yml` 负责：Release 创建成功后，新增一步更新 tap 仓库中 formula 的 `url` 和 `sha256`。
- GitHub Releases 上的预编译 zip **作为备选渠道保留**，适合不用 Homebrew 的用户。Gatekeeper 的放行说明继续写在 Release 说明里。
- 应用只使用 ad-hoc 签名。打包脚本的签名身份可以通过 `SIGN_IDENTITY` 环境变量替换，以后有了开发者账号可以直接切换。

## 后果

好处：

- 不需要开发者账号，没有费用，Gatekeeper 也不会拦截，用户不必手动执行 `xattr`。
- 安装和升级都走用户熟悉的 `brew install` / `brew upgrade`。
- 发版流程只有一个入口：推送 tag 后，`release.yml` 同时更新 Release 和 formula。

代价：

- 安装需要在本机编译，大约一两分钟。Homebrew 本身就要求 Command Line Tools，所以不算额外依赖。
- 应用位于 Homebrew 的安装目录，不在 `/Applications`。通过 `agentbar` 命令打开，或由用户自己链接到 `~/Applications`。
- **每次升级后，ad-hoc 签名都会变**。凡是绑定在代码签名上的系统授权都可能失效：
  - Keychain 访问：每次升级后会重新弹出授权提示。**因此功能设计上应尽量避免依赖 Keychain。**
  - 登录项和通知权限：是否受影响需要实际验证。
- 更新 tap 仓库需要一个对 tap 仓库有写权限的 token（存为源码仓库的 Actions secret）。
- 同时维护两个渠道：Releases 的 zip 和 Homebrew formula。两者都来自同一个 tag，内容一致。

## 何时重新评估

出现以下任一情况时，重新考虑改用 Developer ID 签名、公证，并通过 cask 或直接下载 `.app` 分发：

- 希望用户免编译、下载即用；
- 希望应用安装到 `/Applications`；
- 某个核心功能必须依赖 Keychain，升级后重复授权已经影响体验。
