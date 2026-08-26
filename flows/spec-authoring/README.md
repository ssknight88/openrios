# Specification Authoring Flow

这个 flow 用于把 OR-BE 的分析材料整理成可评审的 specification。它可以由人工执行，也可以由 AI 按同样的步骤执行。

## 输入和约束

- 工作材料：[`work/or-be-draft/`](../../work/or-be-draft/)
- 规范：[`rules/microarchitecture.md`](../../rules/microarchitecture.md)
- 文档模板：[`templates/module.md`](templates/module.md)

## 推荐步骤

1. 确定 per-entry state，并在需要时确定 structure state 的压缩映射。
2. 为每条状态转换命名 condition event。
3. 列出带 payload 的 data path 边。
4. 展开 condition 的 fire 判据、valid/ready 和 guard。
5. 完整描述 data structure 及字段角色。
6. 从前述定义推导 interface，并执行规则检查。

产物先写入 `work/or-be-draft/`。通过评审后，移动到 `spec/or-be/`，并保留变更的 Git 历史。

## 示例

- [`cam-fifo.md`](examples/cam-fifo.md)：CAM 型和 FIFO 型控制逻辑的完整示例。
