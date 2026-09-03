# Module `SerialInstructionTracker`

`SerialInstructionTracker`：单个 serial instruction 的在途状态记录（`TAG_W=4`）。

## Submodule
无。

## FSM
### State
#### Per-entry State
1. `IDLE`：没有 serial instruction 在途。
2. `INFLIGHT`：记录一个 serial instruction 的 tag。

### State Transition & Condition Name
1. `IDLE -> INFLIGHT`：`serial_set`
2. `INFLIGHT -> IDLE`：`commit`
3. `INFLIGHT -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `serial_set`：建立 serial instruction 记录。
   - Fire来源：
     - `serial_set.fire = serial_set_request`
     - `serial_set_request`
   - State update：`serial_inflight_valid=1`；`serial_inflight_tag=serial_set_tag`。

2. `commit`：提交当前 serial instruction。
   - Fire来源：
     - `commit.fire = serial_inflight_valid ∧ commit_hit`
     - `serial_inflight_valid`
     - `commit_hit = ∨k:(commit[k].fire ∧ commit[k].commit_tag == serial_inflight_tag)`
     - `commit[k].fire`
     - `commit[k].commit_tag`
     - `serial_inflight_tag`
   - State update：`serial_inflight_valid=0`。

3. `flush`：取消 serial instruction 记录。
   - Fire来源：`flush.fire = global_flush_late`
   - State update：`serial_inflight_valid=0`。

## Data structure
### State
`serial_inflight_valid`：1 bit；`IDLE/INFLIGHT`；reset=0；`serial_set` 置 1，`commit`/`flush` 清 0。
### Header
`serial_inflight_tag`：`TAG_W=4 bit`；`commit` 比较字段；`serial_set` 更新，其他情况保持。
### Payload
无。

## Data Path
- `serial_set` -> `serial_inflight_tag`：tag；fire 时写入。
- `commit` -> `serial_inflight_valid`：`∅`；commit fire 时清除。
- `flush` -> `serial_inflight_valid`：`∅`；flush fire 时清除。

## Interface
### In-event
- `serial_set`：Notify，payload=`serial_set_tag`（4 bit）；fire=见 FSM 第 1 条。
- `commit[k]`：Notify，`k∈{0,1}`，payload=`commit_tag`（4 bit）；fire=提交 Event fire。
- `flush`：Notify，payload=`∅`；fire=`global_flush_late`。
### In Static Info
无。
### Out-event
无。
### Out Static Info
- `serial_inflight_valid`：1 bit；注册状态投影。
### Interface Timing
`clk` 为时钟，`rst_n` 为异步低有效复位；无 ready/backpressure。
