# Integration Layer Specification v3

## 1. Scope

```text
Module: `backend_top`
Role: instantiate public backend modules and connect their event/static-info contracts.
Boundary: owns composition, schema-preserving projections, slot/group selection, lane aggregation, and FE/LSU boundaries; child modules own storage and local control.
```

本文件只连接 `module_v3` 中登记的 public module，不重新定义子模块的状态机、event fire 或 payload schema。所有 event 的唯一语义仍归其 producer 的 `Output`。

## 2. Public Stage Topology

- Stage=`top`; Public modules=`backend_top`
- Stage=`p1`; Public modules=`IB`, `decode`, `dependency_check`, `dispatch_logic`, `INT_ARF`, `FP_ARF`, `INT_tag_mapping`, `FP_tag_mapping`
- Stage=`p2p3`; Public modules=`ISQ_Group0..3`, `p3_arbiter_G0`, `p3_arbiter_G1`
- Stage=`fu`; Public modules=`alu_simple`, `csr_unit`, `div_simple`, `mul_simple`, `fpu_simple`
- Stage=`lsu`; Public modules=`g3_lsu_iface`
- Stage=`p4`; Public modules=`Buffer`, `CompletionScoreboard`, `PC_File`, `SerialInstructionTracker`, `flush_model`, `system_instruction_handler`


`rvc_expand`、`decode_logic`、payload assembly、slot-to-group selection、`FU_input_mux` 等均为父模块私有实现块；它们不出现在此表或 sibling module Interface 中。

## 3. Composition Rules

1. 每条跨模块 event 只有一个 producer 和一个 schema 定义点。
2. 父模块可以组合私有块结果后产生 public event；组合不改变 event owner。
3. 连接默认保持 payload schema、位宽、slot/lane cardinality 和时序；目的模块声明 capture subset 时才允许投影。
4. mux、demux、merge、fan-out 由端点、payload 分组和互斥关系推导，不创建额外架构 module。
5. 一个 public module 的状态和局部控制不得由 `backend_top` 旁路修改。

## 4. FE -> IB -> Decode

```text
FE fe_instr_pld[s] --(fe_valid[s] ∧ fe_ready[s])--> IB enqueue
IB head payload[s] ---------------------------------> decode input `ib_payload_t[s]`
decode output `decoded_info_t[s]`, `decode_index_t[s]` -> dependency_check / dispatch_logic
```

`decode` 的公共边界只暴露上述输入和输出。其内部文档 `p1/decode/rvc_expand.md`、`p1/decode/decode_logic.md` 由 `decode` 索引；`inst32`、`rvc_illegal` 等局部 static info 不进入顶层公共连接。只有未来明确提升为 public module 时，才建立新的 stage 条目和集成边界。

## 5. P1 -> ISQ

```text
decode + dependency_check + ARF/tag views
    -> dispatch_logic candidate/group decisions
dispatch slot payloads + group credit
    -> backend_top group-selection composition
backend_top `isq_dispatch[g]`
    -> ISQ_Group[g] capture
```

对双 slot 输入，集成层定义选择关系：

```text
dispatch_fire[s] = candidate_valid[s] ∧ credit[target_group[s]]
select_payload[g][s] = dispatch_fire[s] ∧ (target_group[s] == g)
isq_dispatch[g].fire = ∨s: select_payload[g][s]
isq_dispatch[g].payload = selected slot_payload[s]
```

每个 `select_payload[g]` 必须满足 onehot0；不同 group 可同拍接收。mux 是该互斥关系的实现推论，不单独建模。

## 6. ISQ -> Execute

```text
ISQ_Group0.issue -> alu_simple / csr_unit / div_simple
ISQ_Group1.issue -> alu_simple / mul_simple
ISQ_Group2.issue -> fpu_simple
ISQ_Group3.issue -> g3_lsu_iface
```

具体 issue payload、ready 和 fire 由各 consumer/producer module 文档定义；集成层只保留公共端点连接。

## 7. Completion, Bypass and P4

```text
G0 -> p3_arbiter_G0 -> completion/bypass lane 0
G1 -> p3_arbiter_G1 -> completion/bypass lane 1
fpu_simple -----------------> lane 2
g3_lsu_iface ---------------> lane 3
completion lanes -> Buffer / CompletionScoreboard
CompletionScoreboard.commit -> ARF / tag mapping / system_instruction_handler
CompletionScoreboard.flush -> flush_model -> FE and speculative consumers
```

lane-indexed `valid/tag/data` 必须保持对齐；全局 flush 只有一个 canonical producer。

## 8. Integration Invariants and Change Impact

- public module index 不包含内部选择网络。
- `decode` 的 `ib_payload_t -> decoded_info_t/decode_index_t` 契约在拆分或合并内部实现时保持不变。
- `ISQ_Group0..3` 始终是四个独立 public contract。
- schema、fire、timing 或 cardinality 的修改必须检查所有 producer、consumer、package、top projection 和验证断言。
- public/private 边界变化必须同步更新 `module_v3/README.md`、父模块 `Submodule`、本文件连接表和影响报告。

