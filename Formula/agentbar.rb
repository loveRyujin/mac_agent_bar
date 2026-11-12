# 由 release.yml 根据 packaging/homebrew/agentbar.rb.template 自动生成，请勿手动修改。
class Agentbar < Formula
  desc "Menu bar app showing subscription and usage of local AI coding agents"
  homepage "https://github.com/loveRyujin/mac_agent_bar"
  url "https://github.com/loveRyujin/mac_agent_bar/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "01016c10aac356ca62cad82f06c84a0f35a620370a5e46f8f0f1baf4a02c1a73"
  license "MIT"

  depends_on macos: :ventura

  def install
    # Homebrew 已在沙盒中构建，SwiftPM 自己的沙盒会和它冲突，需要关闭
    system "scripts/bundle.sh", "--disable-sandbox", "--output", buildpath/"out"
    prefix.install buildpath/"out/AgentBar.app"
    (bin/"agentbar").write <<~SH
      #!/bin/sh
      exec open "#{opt_prefix}/AgentBar.app" "$@"
    SH
  end

  def caveats
    <<~EOS
      用 `agentbar` 命令打开 AgentBar（应用位于 #{opt_prefix}/AgentBar.app）。
      想在启动台或“应用程序”里看到它，可以手动链接：
        ln -sf #{opt_prefix}/AgentBar.app ~/Applications/AgentBar.app

      每次升级都会在本机重新编译，应用签名随之改变：
        - 开启了“通过 cursor-agent 获取 Cursor 用量”时，系统会再次请求钥匙串授权；
        - 如果开机自启失效，请在 AgentBar 设置中把“开机自动启动”关掉再打开。
    EOS
  end

  test do
    assert_predicate prefix/"AgentBar.app/Contents/MacOS/AgentBar", :executable?
    assert_match "LSUIElement", (prefix/"AgentBar.app/Contents/Info.plist").read
  end
end
