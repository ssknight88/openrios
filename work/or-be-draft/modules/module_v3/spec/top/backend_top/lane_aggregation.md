# Module `lane_aggregation`

`lane_aggregation`：backend_top 内部的 completion/bypass lane 映射。

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

- `p3_arbiter_G0.writeback_g0 -> completion_lane[0]`：completion payload；同拍传递。
- `p3_arbiter_G1.writeback_g1 -> completion_lane[1]`：completion payload；同拍传递。
- `fpu_simple.completion -> completion_lane[2]`：completion payload；同拍传递。
- `g3_lsu_iface.completion_g3 -> completion_lane[3]`：completion payload；同拍传递。
- 各 producer bypass -> `bypass_publish[g]`：bypass payload；保持 lane 对齐。

## Interface
### In-event
无。
### In Static Info
- FU、LSU 和 arbiter completion/bypass 输出。
### Out-event
无。
### Out Static Info
- `completion_lane[g]`：`completion_common_t`，4 lane。
- `bypass_publish[g]`：`{tag,data}`，4 lane。
### Interface Timing
组合 lane projection；不增加存储或仲裁。


