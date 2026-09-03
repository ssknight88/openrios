# Module v2 文档索引

本目录由 `work/rtl/rtl_v1` 按 `rules/microarchitecture.md` 生成。目录结构与 RTL stage 保持一致。

## fu
- [alu_simple](fu/alu_simple.md)
- [csr_unit](fu/csr_unit.md)
- [div_simple](fu/div_simple.md)
- [fpu_simple](fu/fpu_simple.md)
- [mul_simple](fu/mul_simple.md)

## lsu
- [g3_lsu_iface](lsu/g3_lsu_iface.md)

## p1
- [decode](p1/decode.md)
- [dependency_check](p1/dependency_check.md)
- [dispatch_logic](p1/dispatch_logic.md)
- [FP_ARF](p1/FP_ARF.md)
- [FP_read_address_mux](p1/FP_read_address_mux.md)
- [FP_tag_mapping](p1/FP_tag_mapping.md)
- [IB](p1/IB.md)
- [INT_ARF](p1/INT_ARF.md)
- [INT_tag_mapping](p1/INT_tag_mapping.md)
- [p1_ISQ_input_mux](p1/p1_ISQ_input_mux.md)
- [rvc_expand](p1/rvc_expand.md)

## p2p3
- [ISQ_Group0](p2p3/ISQ_Group0.md)
- [ISQ_Group1](p2p3/ISQ_Group1.md)
- [ISQ_Group2](p2p3/ISQ_Group2.md)
- [ISQ_Group3](p2p3/ISQ_Group3.md)
- [p3_arbiter_G0](p2p3/p3_arbiter_G0.md)
- [p3_arbiter_G1](p2p3/p3_arbiter_G1.md)

## p4
- [Buffer](p4/Buffer.md)
- [CompletionScoreboard](p4/CompletionScoreboard.md)
- [flush_model](p4/flush_model.md)
- [PC_File](p4/PC_File.md)
- [SerialInstructionTracker](p4/SerialInstructionTracker.md)
- [system_instruction_handler](p4/system_instruction_handler.md)

## top
- [backend_top](top/backend_top.md)


## 排除项
- `or_be_types_check.sv`: 编译期 schema 检查模块，不承载数据通路或控制状态。
- `isq_payload_assembly.sv`: RTL 明确标注为顶层唯一组合胶水，规范归集成层 §2.1。
- `FU_input_mux.sv`: RTL 明确标注为 ISQ_Group 内部子块，行为已由所属 ISQ 文档引用。