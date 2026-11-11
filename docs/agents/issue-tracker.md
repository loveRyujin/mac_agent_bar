# Issue tracker：本地 Markdown

本仓库的 issue 和 spec 以 markdown 文件的形式存放在 `.scratch/` 下。

## 约定

- 每个功能一个目录：`.scratch/<feature-slug>/`
- spec 文件为 `.scratch/<feature-slug>/spec.md`
- 实现类 issue 每个工单一个文件，路径为 `.scratch/<feature-slug>/issues/<NN>-<slug>.md`，从 `01` 开始编号；不要把多个工单合并到一个文件里
- 状态记录在每个 issue 文件顶部附近的一行 `Status:` 中，值为简短的状态字符串，例如 `open`、`in-progress`、`done`
- 评论和讨论记录追加到文件底部的 `## Comments` 标题下

## 当某个 skill 说“发布到 issue tracker”时

在 `.scratch/<feature-slug>/` 下新建一个文件（目录不存在则先创建）。

## 当某个 skill 说“获取相关工单”时

读取所引用路径的文件。用户通常会直接给出路径或 issue 编号。

## Wayfinding 操作

供 `/wayfinder` 使用。**map** 是一个文件，每个**子工单**各一个文件。

- **Map**：`.scratch/<effort>/map.md`（包含 Notes / Decisions-so-far / Fog 三部分）。
- **子工单**：`.scratch/<effort>/issues/NN-<slug>.md`，从 `01` 开始编号，正文写要解决的问题。用一行 `Type:` 记录工单类型（`research`/`prototype`/`grilling`/`task`）；用一行 `Status:` 记录 `claimed`/`resolved`。
- **阻塞关系**：在顶部附近写一行 `Blocked by: NN, NN`。当列出的所有文件都是 `resolved` 时，该工单即解除阻塞。
- **Frontier（可开工的工单）**：扫描 `.scratch/<effort>/issues/`，找出未关闭、未被阻塞、未被认领的文件；编号最小的优先。
- **认领**：开始任何工作之前，先设置 `Status: claimed` 并保存。
- **解决**：在 `## Answer` 标题下追加答案，设置 `Status: resolved`，然后在 `map.md` 的 Decisions-so-far 中追加一条上下文指引（要点 + 链接）。
