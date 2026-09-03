# Module `Buffer`

`Buffer`：ROB tag 对应的结果存储（`ROB_DEPTH=16`、`XLEN=64`、`NUM_LANES=4`、`ISSUE_WIDTH=2`）。

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

`entry.payload[0:15]`：`Buffer_payload`；写入=`writeback[g].fire`；读取=`commit_data[s]`。

`Buffer_payload`：`tag[3:0]`、`result_data[63:0]`。

## Data Path

- `writeback[g] -> entry.payload[writeback[g].tag]`：`Buffer_payload`；`writeback[g].fire` 时写入。
- `entry.payload[head_tag[s]] -> commit_data[s]`：64-bit result；按 `head_tag[s]` 组合读。

## Interface

### In-event

- `writeback[g]`：Notify，`g∈{0,1,2,3}`，payload=`Buffer_payload`；`writeback[g].fire` 时写入。

### In Static Info

- `head_tag[s]`：4 bit，`s∈{0,1}`；commit head tag。

### Out-event

无。

### Out Static Info

- `commit_data[s]`：64 bit，`s∈{0,1}`；`entry.payload[head_tag[s]].result_data`。

### Interface Timing

`clk` 为时钟，`rst_n` 为异步低有效复位。writeback 在上升沿写入；commit_data 组合读出。flush 不清除结果存储。


