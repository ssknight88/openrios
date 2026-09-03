# Module `decode_logic`

`decode_logic`：Decode 内部的规范指令分类与字段生成逻辑。

## Submodule

无。

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

无。

### Header

无。

### Payload

无。

## Data Path

- `rvc_expand.inst32[s] -> decoded_info_local[s]`：规范 32-bit 指令字段、立即数、子码和分类信息。
- `rvc_expand.rvc_illegal[s] -> decoded_info_local[s]`：RVC 非法状态。
- `decode.ib_fetch_excp_vld[s] -> decoded_info_local[s]`：取指异常状态。
- `rvc_expand.inst32[s] -> decode_index_local[s]`：rs1/rs2/rs3/rd 索引。

## Interface

### In-event

无。

### In Static Info

- `inst32[s]`：32 bit，`s∈{0,1}`；规范指令。
- `rvc_illegal[s]`：1 bit，`s∈{0,1}`；RVC 展开状态。
- `ib_fetch_excp_vld[s]`：1 bit，`s∈{0,1}`；取指异常状态。
- `ib_inst16[s]`、`ib_is_compressed[s]`：16/1 bit，`s∈{0,1}`；压缩别名上下文。

### Out-event

无。

### Out Static Info

- `decoded_info_local[s]`：`decoded_info_t`、120 bit，`s∈{0,1}`；由 opcode、立即数、subop、操作数和合法性规则生成。
- `decode_index_local[s]`：`decode_index_t`、20 bit，`s∈{0,1}`；由规范指令寄存器字段生成。

### Interface Timing

组合逻辑；无时钟、复位、握手或存储。


