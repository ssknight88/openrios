# OpenRIOS Specification Workspace

这个仓库记录 OR 项目的 specification，以及从分析材料到 golden specification 的可复现协作流程。

## 目录

- [`spec/`](spec/)：已确认、可供 RTL 或 Model 消费的 golden specification。
- [`work/or-be-draft/`](work/or-be-draft/)：OR-BE 当前的草稿、分析材料和待评审产物；这里的内容不是 golden。
- [`rules/`](rules/)：编写和验收 specification 时必须遵守的规范。
- [`flows/`](flows/)：把规则、模板和 AI/人工步骤串起来的工程流程。

## 生命周期

```text
work/or-be-draft/ -> review -> spec/ -> RTL / Model
```

只有经过评审的内容才能进入 `spec/`。生成 RTL 或 Model 时，应记录所消费的 specification 版本。
