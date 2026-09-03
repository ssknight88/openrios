# Module `FP_ARF`

`FP_ARF`：32-entry、64-bit floating-point architectural register file（`NUM_FPR=32`、`XLEN=64`、`FP_READ_PORTS=3`）。

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
`entry.payload[0:31]`：`FP_payload`。

`FP_payload`：`value[63:0]`。

## Data Path

- `commit_write[k] -> entry.payload[rd_idx[k]]`：`FP_payload`；commit write fire 时写入。
- `entry.payload[fp_read_idx[x]] -> FP_read_data[x]`：`FP_payload.value`；组合读。

## Interface
### In-event
- `commit_write[k]`：Notify，`k∈{0,1}`，payload=`rd_idx[k]`、`commit_data[k]`；commit fire 时写入。
### In Static Info
- `rd_is_fp[k]`、`rd_write_enable[k]`：1 bit x 2；commit write qualifier。
- `fp_read_idx[x]`：5 bit x 3；read addresses。
### Out-event
无。
### Out Static Info
- `FP_read_data[x]`：64 bit，`x∈{1,2,3}`；`entry.payload[fp_read_idx[x]].value`。
### Interface Timing
`clk` 同步写入；`rst_n` 异步复位；read data 组合输出。
