# NOTICE

## 授权

项目代码以 MIT 授权，见 `LICENSE`。下文“agent 图标”一节列出的图标不在 MIT 授权范围内，按其各自的授权和商标规则使用。

## AgentBar 的 logo

`assets/logo/` 下的 logo 和应用图标由本项目绘制，随代码一起以 MIT 授权。应用图标由
`swift scripts/make-app-icon.swift assets/logo/agentbar.svg assets/logo/AppIcon.icns` 生成。

## agent 图标

`assets/icons/` 下的 SVG 及由其转换得到的 `Sources/AgentBar/Resources/{claude,cursor,openai,minimax}.pdf` 来自
[Simple Icons](https://simpleicons.org)，除特别注明外按 [CC0 1.0](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md) 授权：

| 文件 | 图标 | 来源版本 |
|---|---|---|
| `claude.svg` | Claude | simple-icons 16.37.0 |
| `cursor.svg` | Cursor | simple-icons 16.37.0 |
| `openai.svg` | OpenAI | simple-icons 15.22.0（16.0.0 起已移除该图标） |
| `minimax.svg` | MiniMax（MiniMax Code、mmx 共用） | simple-icons 16.37.0，**不是 CC0**：按 MiniMax 给 Simple Icons 的单独授权（见 [simple-icons#13982](https://github.com/simple-icons/simple-icons/pull/13982#issuecomment-3531627803)），原图来自 [MiniMax-AI/MiniMax-01](https://github.com/MiniMax-AI/MiniMax-01) |

转换方法：`swift scripts/svg2pdf.swift assets/icons/<name>.svg Sources/AgentBar/Resources/<name>.pdf`。

## 商标

Claude 和 Anthropic 是 Anthropic PBC 的商标，OpenAI 是 OpenAI 的商标，Cursor 是 Anysphere Inc. 的商标，MiniMax 是 MiniMax 的商标。
CC0 只放弃了图形本身的著作权，不涉及商标权。本项目与上述公司没有关联，也没有获得它们的认可；
这些 logo 仅用于在界面中标识对应的 agent。如果权利方提出异议，会改用自绘的符号。
