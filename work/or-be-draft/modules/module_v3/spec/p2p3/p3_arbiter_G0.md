# Module `p3_arbiter_G0`

`p3_arbiter_G0`：select one completion request in G0 and publish lane-0 completion, CSR sideband, bypass, and requester feedback。

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
- `requester FU `k`` -> `priority selector`：completion + CSR sideband；驱动 `completion_request[k]`；`request_valid[k]`
- `selected request` -> `lane 0 consumers`：completion + CSR sideband；驱动 `writeback_g0`；`Result_valid`
- `selected result` -> `all ISQ groups`：`{tag,data}`；驱动 `bypass_publish_g0`；`bypass_valid`

## Interface

### In-event

- 无。

### In Static Info

- `request_valid[k]`：completion trigger；1 x 3；combinational
- `req_*[k]`：completion payload；common + CSR sideband；combinational

### Out-event

- `writeback_g0`:
  ```text
  Result_valid = winner_valid
  winner_payload = request_payload[winner_idx] when winner_valid, else zero
  ```

  All common fields and the G0 CSR sideband are forwarded verbatim from `winner_payload`.
- `bypass_publish_g0`:
  ```text
  bypass_valid = Result_valid ∧ ¬exception_flag
  bypass_tag = tag_out
  bypass_data = result_data
  ```
- `Result_valid`, winner fields`：Transaction；lane-0 completion；same-cycle
- `bypass_valid/tag/data`：Notify；`{tag:4,data:64}`；same-cycle

### Out Static Info

- `winner_grant[k]`, `loser_hold[k]`：Static Info；1 x 3；same-cycle feedback

### Interface Timing

No clock, reset, or flush input exists.


