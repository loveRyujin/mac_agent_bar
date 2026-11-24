"""AgentBar 示例插件：调用 agent 官方命令行工具的查询命令。

如果 agent 自带查询额度的命令（例如 `example-cli quota --json`），优先用它：
凭据和联网都由官方工具自己处理，插件只读它的输出。

假设 `example-cli quota --json` 输出：
  {"plan": "Pro", "email": "you@example.com",
   "limits": [{"window_minutes": 300, "remaining_percent": 60, "resets_at": "2026-11-25T03:00:00Z"}]}
未登录时以非零退出，标准错误里有 "not logged in"。
"""

import json
import shutil
import subprocess


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False))


def main():
    # AgentBar 已经把常见的安装位置（Homebrew、mise、~/.local/bin 等）加进了 PATH
    cli = shutil.which("example-cli")
    if cli is None:
        return emit({"error": "找不到 example-cli，请先安装"})

    try:
        result = subprocess.run([cli, "quota", "--json"], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return emit({"error": "example-cli 没有响应"})

    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        message = lines[-1] if lines else f"example-cli 运行失败（退出码 {result.returncode}）"
        if "not logged in" in message.lower():
            return emit({"plan": "未登录", "state": "signedOut"})
        return emit({"error": message})

    try:
        data = json.loads(result.stdout)
    except ValueError:
        return emit({"error": "example-cli 的输出无法解析"})

    windows = [
        {
            "windowMinutes": limit["window_minutes"],
            # 官方工具给的是剩余比例，AgentBar 要的是已用比例
            "usedPercent": 100 - limit["remaining_percent"],
            "resetsAt": limit.get("resets_at"),
        }
        for limit in data.get("limits", [])
        if "window_minutes" in limit and "remaining_percent" in limit
    ]
    emit({
        "plan": data.get("plan") or "未知套餐",
        "state": "active",
        "account": data.get("email"),
        "usage": {"windows": windows} if windows else {"unavailable": "example-cli 没有返回额度"},
    })


main()
