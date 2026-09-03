# Module `backend_top`

`backend_top`：后端 public module 的顶层连接。

## Submodule

- `IB`：`../p1/IB.md`
- `decode`：`../p1/decode.md`
- `dependency_check`：`../p1/dependency_check.md`
- `dispatch_logic`：`../p1/dispatch_logic.md`
- `ISQ_Group0..3`：`../p2p3/ISQ_Group0.md`、`ISQ_Group1.md`、`ISQ_Group2.md`、`ISQ_Group3.md`
- FU、LSU、P4 public modules：见对应 stage 文档。

## FSM

### State

#### Per-entry State

无。

### State Transition & Condition Name

无。

### Detailed Condition Description

无。

## Data structure

### State

无。所有状态由子 module 持有。

### Header

无。

### Payload

无。Top 不捕获子 module payload。

## Data Path

- `FE_payload[s] -> IB`：`FE_payload`；FE enqueue Event fire 时传输。
- `IB.decode_payload[s] -> decode`：`decode_payload`；组合连续传输。
- `decode.decoded_info[s] -> dependency_check/dispatch_logic`：Decode static info；组合传输。
- `backend_top.isq_payload[s] -> ISQ_Group[g]`：`isq_payload`；group dispatch Event fire 时传输。
- `ISQ_Group[g].issue -> FU/LSU`：issue payload；issue Event fire 时传输。
- `FU/LSU.completion -> CompletionScoreboard/Buffer`：completion payload；completion Event fire 时传输。
- `FU/LSU.bypass -> dependency_check/ISQ_Group[g]`：bypass payload；bypass Event fire 时传输。
- `CompletionScoreboard.commit -> ARF/tag mapping/system_instruction_handler`：commit payload；commit Event fire 时传输。
- `CompletionScoreboard.flush -> flush_model`：flush payload；flush Event fire 时传输。
- `flush_model.redirect -> FE`：redirect payload；redirect Event fire 时传输。

## Interface

### In-event

- `FE_enqueue[s]`：Transaction，`s∈{0,1}`，payload=`FE_payload[s]`；fire=`FE_valid[s] ∧ IB_ready[s]`。

### In Static Info

- 子 module 的 ready、credit、completion、bypass 和 recovery 输入。

### Out-event

- `isq_dispatch[g]`：Transaction，`g∈{0,1,2,3}`，payload=`isq_payload[g]`；fire 由 group selection condition 定义。
- 子 module issue、completion、commit、flush 和 redirect Event。

### Out Static Info

- `IB_ready[s]`、group credit、lane projection 和 observation projection。

### Interface Timing

Top 只连接子 module，不增加寄存器、payload hold 或独立状态。


