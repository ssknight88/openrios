# Module `rvc_expand`

`rvc_expand`：Decode 内部的 RVC 压缩指令展开逻辑。

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

- `decode.ib_inst_bits[s] -> inst32[s]`：32 bit；非压缩时直通，压缩时使用解压结果。
- `decode.ib_is_compressed[s] -> inst32[s]`：1 bit；选择直通或解压结果。
- `decode.ib_is_compressed[s] -> rvc_illegal[s]`：1 bit；组合生成压缩编码合法性。

## Interface

### In-event

无。

### In Static Info

- `ib_inst_bits[s]`：32 bit，`s∈{0,1}`；原始指令编码。
- `ib_is_compressed[s]`：1 bit，`s∈{0,1}`；压缩指令标志。

### Out-event

无。

### Out Static Info

- `inst32[s]`：32 bit，`s∈{0,1}`；`ib_is_compressed[s] ? rvc_decompress_rv64(ib_inst_bits[s][15:0]) : ib_inst_bits[s]`。
- `rvc_illegal[s]`：1 bit，`s∈{0,1}`；`ib_is_compressed[s] ∧ ¬rvc_ok[s]`。

### Interface Timing

组合逻辑；无时钟、复位、握手或存储。


