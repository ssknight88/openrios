# Module `payload_assembly`

`payload_assembly`：backend_top 内部的 ISQ payload 组装。

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

- `IB.decode_payload[s] -> isq_payload[s]`：IB 字段；组合投影。
- `decode.decoded_info[s] -> isq_payload[s]`：Decode 字段；组合投影。
- `dependency_check` operand views -> `isq_payload[s]`：操作数与 tag 字段；组合投影。
- `dispatch_logic` route views -> `isq_payload[s]`：group、FU 和控制字段；组合投影。

## Interface

### In-event
无。
### In Static Info
- `IB.decode_payload[s]`、Decode static info、dependency static info、dispatch static info。
### Out-event
无。
### Out Static Info
- `isq_payload[s]`：`isq_payload`，`s∈{0,1}`；由输入 static info 组合生成。
### Interface Timing
组合逻辑，无时钟、复位和存储。


