# Module `div_simple`

`div_simple`：execute G0 integer divide/remainder operations and publish a delayed held completion。

## Submodule
无。

## FSM
### State
#### Per-entry State
```text
IDLE: `busy_reg=0`.
ITERATE_2: `cnt=2` after issue capture.
ITERATE_1: `cnt=1`.
WRITEBACK: `cnt=0`, result enters `wb_q`.
HOLD: `wb_q.result_valid=1` waits for grant.
Reset State: IDLE.
```

### State Transition & Condition Name
1. `IDLE -> ITERATE_2`：`accept`
2. `ITERATE_2 -> ITERATE_1`：`clock`
3. `ITERATE_1 -> WRITEBACK`：`clock`
4. `WRITEBACK -> HOLD`：`no grant`
5. `WRITEBACK/HOLD -> IDLE`：`winner_ack`
6. `ANY -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `accept`：
   accept = issue_valid ∧ FU_ready ∧ (FU_Group == G0_FU_DIV) ∧ ¬flush.fire

2. `clock`：
   见本模块条件逻辑。

3. `clock`：
   见本模块条件逻辑。

4. `no grant`：
   见本模块条件逻辑。

5. `winner_ack`：
   winner_ack = winner_grant ∧ ¬flush.fire

6. `flush`：
   见本模块条件逻辑。

## Data structure
### State

- ``busy_reg``：Width=1; Role=pipeline state; Reset=0; Update=accept -> 1; winner/flush -> 0
- ``cnt``：Width=2; Role=countdown; Reset=0; Update=accept -> 2; iterate -> decrement
- ``wb_q.result_valid``：Width=1; Role=completion state; Reset=0; Update=writeback -> 1; winner/flush -> 0

### Header

`reg_tag` is a 4-bit completion header. `FU_Group` and `exe_subop` are issue-time selectors.

### Payload

`reg_result` is 64 bits; `wb_q` stores the completion payload.

## Data Path
- `G0 issue operands` -> `divide datapath`：issue payload；驱动 `issue`；`accept`
- `result/tag` -> `result registers`：64-bit result + tag；驱动 divide datapath；accept edge
- `delayed completion` -> ``p3_arbiter_G0``：`completion_common_t`；驱动 result registers；`request_valid`

## Interface

### In-event

- `issue`：Transaction；G0 issue payload；capture on `accept`
- `flush`：Notify；`∅`；clears pipeline

### In Static Info

- `winner_grant`, `loser_hold`：arbitration feedback；1 bit each；same-cycle

### Out-event

- `completion_request`:
- ``result_valid``：Width / Type=1; Generation rule=`request_valid`
- ``tag_out``：Width / Type=`TAG_W=4`; Generation rule=captured issue `self_tag`
- ``result_data``：Width / Type=`XLEN=64`; Generation rule=divide/remainder function
- ``mispredict_flag`, `mispredict_target_pc``：Width / Type=1 + 64; Generation rule=zero
- ``exception_flag`, `exception_cause`, `exception_tval``：Width / Type=1 + 63 + 64; Generation rule=zero
- ``is_mret`, `is_sret``：Width / Type=1 + 1; Generation rule=zero
- ``fpu_fflags``：Width / Type=5; Generation rule=zero

  `completion_request` appears after the fixed countdown and remains stable through arbitration loss.

### Out Static Info

```text
FU_ready = ¬busy_reg ∧ ¬loser_hold
```
- `FU_ready`：Static Info；1 bit；combinational

### Interface Timing

- 无。


