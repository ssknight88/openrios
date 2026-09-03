# Module `fp_read_address_selection`

`fp_read_address_selection`：backend_top 内部的三路 FP read address 选择。

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

- `decode_index[s] -> fp_read_idx[k]`：5-bit register index；组合选择。
- `fp_read_idx[k] -> FP_ARF`：FP read address；组合传递。
- `fp_read_idx[k] -> FP_tag_mapping`：FP read address；组合传递。

## Interface
### In-event
无。
### In Static Info
- `decode_index[s]`：2 slot register indices。
- `is_fp_instruction[s]`：2 slot selector。
### Out-event
无。
### Out Static Info
- `fp_read_idx[1:3]`：5 bit x 3；由当前 FP slot 选择生成。
### Interface Timing
组合逻辑；无时钟、复位和存储。


