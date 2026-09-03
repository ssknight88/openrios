# Module `decode`

`decode`：2-slot 指令解码模块（`ISSUE_WIDTH=2`、`XLEN=64`、`DECODE_INFO_W=120`、`DECODE_INDEX_W=20`）。

## Submodule

- `rvc_expand`：`decode/rvc_expand.md`
- `decode_logic`：`decode/decode_logic.md`

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

- `decode_payload[s] -> rvc_expand`：`decode_payload`；组合传递。
- `rvc_expand.inst32[s] -> decode_logic`：32-bit canonical instruction；组合传递。
- `decode_logic.decoded_info[s] -> decoded_info[s]`：`decoded_info`；组合传递。
- `decode_logic.decode_index[s] -> decode_index[s]`：`decode_index`；组合传递。

## Interface

### In-event

无。

### In Static Info

- `decode_payload[s]`：`decode_payload`，232 bit，`s∈{0,1}`；IB head payload。

### Out-event

无。

### Out Static Info

- `decoded_info[s]`：`decoded_info`，120 bit，`s∈{0,1}`；字段为 `is_serial`、`is_fp_instruction`、`use_rs1`、`use_rs2`、`use_rs3`、`rs1_is_fp`、`rs2_is_fp`、`rs3_is_fp`、`use_rd`、`rd_is_fp`、`is_store`、`mem_funct3`、`imm_valid`、`imm_data[63:0]`、`exe_subop[23:0]`、`full_decode[16:0]`。
- `decode_index[s]`：`decode_index`，20 bit，`s∈{0,1}`；字段为 `rs1_idx[4:0]`、`rs2_idx[4:0]`、`rs3_idx[4:0]`、`rd_idx[4:0]`。

`full_decode`：`csr_write_intent[16]`、`illegal[15]`、`rm[14:12]`、`csr_addr[11:0]`。

### Interface Timing

组合输出；无时钟、复位、握手或存储。


