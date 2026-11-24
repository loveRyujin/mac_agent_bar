#!/usr/bin/osascript -l JavaScript
// AgentBar 示例插件：读取 agent 保存在本地的 JSON 文件。
//
// 用 macOS 自带的 JavaScript for Automation（osascript），不需要安装 Node。
// 假设 ~/.example-agent/account.json 长这样：
//   {"email": "you@example.com", "plan": "pro",
//    "subscription": {"status": "active", "renews_at": "2026-12-01T00:00:00Z"},
//    "quota": {"daily": {"used": 120, "limit": 500, "reset_at": "2026-11-25T00:00:00Z"}}}
//
// run() 的返回值会打印到标准输出；console.log 打印到标准错误，可以用来调试。
ObjC.import('Foundation')

const FILE = '.example-agent/account.json'
const PLANS = { free: 'Free', pro: 'Pro', team: 'Team' }
const STATES = { active: 'active', trialing: 'trial', expired: 'expired', canceled: 'expired' }

function readJSON(relativePath) {
  const home = $.NSProcessInfo.processInfo.environment.objectForKey('HOME').js
  const text = $.NSString.stringWithContentsOfFileEncodingError(`${home}/${relativePath}`, $.NSUTF8StringEncoding, null)
  return text.isNil() ? null : JSON.parse(text.js)
}

function status() {
  let account
  try {
    account = readJSON(FILE)
  } catch (e) {
    return { error: `~/${FILE} 格式无法解析` }
  }
  if (!account) return { error: `找不到 ~/${FILE}` }
  if (!account.email) return { plan: '未登录', state: 'signedOut' }

  const subscription = account.subscription || {}
  const daily = (account.quota || {}).daily
  const result = {
    plan: PLANS[account.plan] || account.plan || '未知套餐',
    state: STATES[subscription.status] || 'unknown',
    account: account.email,
    periodEnd: subscription.renews_at || null,
  }
  if (daily && daily.limit > 0) {
    result.usage = {
      windows: [{ windowMinutes: 1440, usedPercent: (daily.used / daily.limit) * 100, resetsAt: daily.reset_at || null }],
    }
  }
  return result
}

function run() {
  return JSON.stringify(status())
}
