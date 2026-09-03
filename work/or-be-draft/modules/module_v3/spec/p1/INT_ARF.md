# Module `INT_ARF`

`INT_ARF`：32-entry、64-bit integer architectural register file（`NUM_GPR=32`、`XLEN=64`、`INT_READ_PORTS=4`）。

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
`entry.payload[0:31]`：`INT_payload`。

`INT_payload`：`value[63:0]`；register 0 固定为 0。

## Data Path

- `commit_write[k] -> entry.payload[rd_idx[k]]`：`INT_payload`；commit write fire 时写入，`rd_idx=0` 时丢弃。
- `entry.payload[rs_idx[s][x]] -> INT_read_data[s][x]`：`INT_payload.value`；`rs_idx=0` 时输出 0，其他地址组合读。

## Interface
### In-event
- `commit_write[k]`：Notify，`k∈{0,1}`，payload=`rd_idx[k]`、`commit_data[k]`；commit fire 时写入。
### In Static Info
- `rd_is_fp[k]`、`rd_write_enable[k]`：1 bit x 2；commit write qualifier。
- `rs_idx[s][x]`：5 bit x 4；read addresses。
### Out-event
无。
### Out Static Info
- `INT_read_data[s][x]`：64 bit，`s∈{0,1}`、`x∈{1,2}`；`rs_idx=0 ? 0 : entry.payload[rs_idx].value`。
### Interface Timing
`clk` 同步写入；`rst_n` 异步复位；read data 组合输出。
