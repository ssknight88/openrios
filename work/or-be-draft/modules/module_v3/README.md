# Module v3 文档索引

本目录是面向 RTL 正向生成的 v3 模块规格工作区。`microarchitecture_v3.md` 定义事件、状态、数据通路和接口规则；`module_v3.md` 是单个 module 的文档骨架；`module_composition_v3.md` 定义公共积木、父模块私有实现和集成边界。

- [or_be_has_v3.md](or_be_has_v3.md)：基于 v3 module 关系的整体 HAS，包含 ISA、主数据路径、ISA 控制和 submodule 说明。

## 文档层级

- **Public module**：系统级积木，拥有独立对外 event、static info、payload schema 和 Interface；只在本索引登记。
- **Private submodule**：父模块内部实现分解，只由父模块文档索引，不进入 sibling module 的依赖或顶层连接。
- **Integration**：`integration-layer_v3.md` 只连接 public module 契约，不重新定义子模块状态机或 payload schema。

## 当前公共模块分组

以下列表是稳定的公共边界，不把 mux、demux、merge、fan-out 等推论结构列为 module。

### top
- [`backend_top`](top/backend_top.md)

### p1
- [`IB`](p1/IB.md)
- [`decode`](p1/decode.md)
- [`dependency_check`](p1/dependency_check.md)
- [`dispatch_logic`](p1/dispatch_logic.md)
- [`INT_ARF`](p1/INT_ARF.md)
- [`FP_ARF`](p1/FP_ARF.md)
- [`INT_tag_mapping`](p1/INT_tag_mapping.md)
- [`FP_tag_mapping`](p1/FP_tag_mapping.md)

`decode` 的 `rvc_expand`、`decode_logic` 仅作为 `p1/decode/` 下的 private submodule 文档。

### p2p3
- [`ISQ_Group0`](p2p3/ISQ_Group0.md)
- [`ISQ_Group1`](p2p3/ISQ_Group1.md)
- [`ISQ_Group2`](p2p3/ISQ_Group2.md)
- [`ISQ_Group3`](p2p3/ISQ_Group3.md)
- [`p3_arbiter_G0`](p2p3/p3_arbiter_G0.md)
- [`p3_arbiter_G1`](p2p3/p3_arbiter_G1.md)

四个 ISQ 保持四个独立的 public module；组选择和 payload 组装归 `backend_top` 集成逻辑。

### fu
- [`alu_simple`](fu/alu_simple.md)
- [`csr_unit`](fu/csr_unit.md)
- [`div_simple`](fu/div_simple.md)
- [`mul_simple`](fu/mul_simple.md)
- [`fpu_simple`](fu/fpu_simple.md)

### lsu
- [`g3_lsu_iface`](lsu/g3_lsu_iface.md)

### p4
- [`Buffer`](p4/Buffer.md)
- [`CompletionScoreboard`](p4/CompletionScoreboard.md)
- [`PC_File`](p4/PC_File.md)
- [`SerialInstructionTracker`](p4/SerialInstructionTracker.md)
- [`flush_model`](p4/flush_model.md)
- [`system_instruction_handler`](p4/system_instruction_handler.md)

P4 是阶段分组，不是单一 module；每个条目保持独立契约。

## 私有实现文档

- Decode：[`rvc_expand`](p1/decode/rvc_expand.md)、[`decode_logic`](p1/decode/decode_logic.md)
- backend_top：[`payload_assembly`](top/backend_top/payload_assembly.md)、[`isq_group_selection`](top/backend_top/isq_group_selection.md)、[`fp_read_address_selection`](top/backend_top/fp_read_address_selection.md)、[`lane_aggregation`](top/backend_top/lane_aggregation.md)

这些文档只描述父模块内部契约，不增加公共 module 或跨模块连接端点。

## 生成顺序

1. FU / LSU：定义 issue、completion 和 bypass 契约。
2. ISQ_Group0..3：定义 entry 存储、operand readiness、bypass 和 issue。
3. dependency_check、ARF、tag mapping：定义操作数数据、ready、wait tag 和来源选择。
4. dispatch_logic：定义路由、FU index 和 admission 条件。
5. decode：定义 `ib_payload_t` 到 `decoded_info_t`、`decode_index_t` 的公共契约；RVC 展开留在内部。
6. IB：保存 Decode 与后续模块所需的原始 payload。
7. backend_top / integration：连接公共契约并承担 slot/group 组合。
8. 生成 RTL、package、断言和验证，并执行文档一致性检查。

## 参考

- [microarchitecture_v3.md](microarchitecture_v3.md)
- [module_v3.md](module_v3.md)
- [module_composition_v3.md](module_composition_v3.md)
- [integration-layer_v3.md](integration-layer_v3.md)
- [v2 初始模块索引](../module_v2/README.md)
