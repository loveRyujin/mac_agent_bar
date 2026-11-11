# 领域文档

工程类 skill 在探索代码库时应如何使用本仓库的领域文档。

## 探索之前，先读这些

- 仓库根目录下的 **`GLOSSARY.md`**，或者
- 仓库根目录下的 **`GLOSSARY-MAP.md`**（如果存在）：它指向每个上下文各自的 `GLOSSARY.md`。阅读与当前主题相关的那些。
- **`docs/adr/`**：阅读与你即将修改的区域相关的 ADR。在多上下文仓库中，还要检查 `src/<context>/docs/adr/` 里针对特定上下文的决策。

如果这些文件不存在，**直接继续，不要提示**。不要指出它们缺失，也不要建议预先创建。`/domain-modeling` skill（通过 `/grill-with-docs` 和 `/improve-codebase-architecture` 触发）会在术语或决策真正确定下来时按需创建它们。

## 文件结构

单上下文仓库（大多数仓库）：

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

多上下文仓库（根目录存在 `GLOSSARY-MAP.md`）：

```
/
├── GLOSSARY-MAP.md
├── docs/adr/                          ← 系统级决策
└── src/
    ├── ordering/
    │   ├── GLOSSARY.md
    │   └── docs/adr/                  ← 特定上下文的决策
    └── billing/
        ├── GLOSSARY.md
        └── docs/adr/
```

## 使用术语表中的词汇

当你的输出提到某个领域概念时（issue 标题、重构提案、假设、测试名称等），使用 `GLOSSARY.md` 中定义的术语。不要换成术语表明确避免使用的同义词。

如果你需要的概念还不在术语表里，这是一个信号：要么你在发明项目并不使用的说法（请重新考虑），要么确实存在空缺（记下来交给 `/domain-modeling`）。

## 指出与 ADR 的冲突

如果你的输出与某个现有 ADR 相矛盾，要明确指出，而不是悄悄推翻它：

> _与 ADR-0007（事件溯源订单）相矛盾，但值得重新讨论，因为……_
