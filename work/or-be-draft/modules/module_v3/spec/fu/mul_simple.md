# Module `mul_simple`

`mul_simple`：execute G1 integer multiply operations and publish a delayed completion request。

## Submodule
无。

## FSM
### State
#### Per-entry State
```text
IDLE: `busy_reg=0`.
DELAY_1: product/tag stored, `cnt=1`.
WRITEBACK: `cnt=0`, result enters hold registers.
HOLD: held completion waits for `winner_grant`.
Reset State: IDLE.
```

### State Transition & Condition Name
1. `IDLE -> DELAY_1`：`issue_accept`
2. `DELAY_1 -> WRITEBACK`：`clock`
3. `WRITEBACK -> HOLD`：`no grant`
4. `WRITEBACK -> IDLE`：`winner_ack`
5. `HOLD -> IDLE`：`winner_ack`
6. `HOLD -> HOLD`：`no grant`
7. `ANY -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `issue_accept`：
   issue_accept = issue_valid ∧ FU_ready

2. `clock`：
   见本模块条件逻辑。

3. `no grant`：
   见本模块条件逻辑。

4. `winner_ack`：
   winner_ack = winner_grant ∧ ¬flush.fire

5. `winner_ack`：
   winner_ack = winner_grant ∧ ¬flush.fire

6. `no grant`：
   见本模块条件逻辑。

7. `flush`：
   见本模块条件逻辑。

## Data structure
### State

- ``busy_reg``：Width=1; Role=pipeline state; Reset=0; Update=issue -> 1; winner/flush -> 0
- ``cnt``：Width=1; Role=delay state; Reset=0; Update=issue -> 1; next cycle -> 0
- ``hold_valid``：Width=1; Role=completion state; Reset=0; Update=writeback -> 1; winner/flush -> 0

### Header

`reg_tag` is 4 bits; `FU_Group` and `exe_subop` are issue-time selectors.

### Payload

`reg_result` is 64 bits; `hold_tag` and `hold_result_data` form the held completion.

## Data Path
- `G1 issue payload` -> `product datapath`：operands/subop；驱动 `issue`；`issue_accept`
- `product + tag` -> `delay registers`：64-bit result/tag；驱动 product；issue edge
- `held completion` -> ``p3_arbiter_G1``：`completion_common_t`；驱动 delay；`request_valid`

## Interface

### In-event

- `issue`：Transaction；G1 issue payload；capture on `issue_accept`
- `flush`：Notify；`∅`；clears pipeline

### In Static Info

- `winner_grant`, `loser_hold`：arbitration feedback；1 bit each；same-cycle

### Out-event

- `completion_request`:
  The held result is exposed after the fixed countdown and remains stable while arbitration loses.
- ``result_valid``：Width / Type=1; Generation rule=`request_valid`
- ``tag_out``：Width / Type=`TAG_W=4`; Generation rule=captured `self_tag`
- ``result_data``：Width / Type=`XLEN=64`; Generation rule=product function
- ``mispredict_flag`, `mispredict_target_pc``：Width / Type=1 + 64; Generation rule=zero
- ``exception_flag`, `exception_cause`, `exception_tval``：Width / Type=1 + 63 + 64; Generation rule=zero
- ``is_mret`, `is_sret``：Width / Type=1 + 1; Generation rule=zero
- ``fpu_fflags``：Width / Type=5; Generation rule=zero

### Out Static Info

```text
FU_ready = ¬busy_reg ∧ ¬loser_hold
```
- `FU_ready`：Static Info；1 bit；combinational

### Interface Timing

- 无。


