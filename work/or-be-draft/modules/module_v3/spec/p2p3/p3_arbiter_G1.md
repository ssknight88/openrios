# Module `p3_arbiter_G1`

`p3_arbiter_G1`：select one completion request in G1 and publish lane-1 completion, bypass, and requester feedback。

## Submodule
无。

## FSM
### State
#### Per-entry State
无。

### State Transition & Condition Name
无。

没有 Event fire 时状态保持。

### Detailed Condition Description
无。

## Data structure
### State
No stored state, header, or payload.

### Header
无。

### Payload
无。

## Data Path
- `requester FU `k`` -> `priority selector`：`completion_common_t`；驱动 `completion_request[k]`；`request_valid[k]`
- `selected request` -> `lane 1 consumers`：completion；驱动 `writeback_g1`；`Result_valid`
- `selected result` -> `all ISQ groups`：`{tag,data}`；驱动 `bypass_publish_g1`；`bypass_valid`

## Interface

### In-event

- 无。

### In Static Info

- `request_valid[k]`：completion trigger；1 x 2；combinational
- `req_*[k]`：completion payload；`completion_common_t`；combinational

### Out-event

- `writeback_g1`:
  ```text
  Result_valid = winner_valid
  winner_payload = request_payload[winner_idx] when winner_valid, else zero
  ```
- `bypass_publish_g1`:
  ```text
  bypass_valid = Result_valid ∧ ¬exception_flag
  bypass_tag = tag_out
  bypass_data = result_data
  ```
- `Result_valid`, winner fields`：Transaction；lane-1 completion；same-cycle
- `bypass_valid/tag/data`：Notify；`{tag:4,data:64}`；same-cycle

### Out Static Info

- `winner_grant[k]`, `loser_hold[k]`：Static Info；1 x 2；same-cycle feedback

### Interface Timing

No clock, reset, or flush input exists.


