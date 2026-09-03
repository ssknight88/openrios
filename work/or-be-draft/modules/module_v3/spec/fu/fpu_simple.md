# Module `fpu_simple`

`fpu_simple`：execute the single G2 floating-point operation and publish completion and bypass on lane 2。

## Submodule
无。

## FSM
### State
#### Per-entry State
```text
IDLE: `busy_q=0`; a new issue may be accepted.
EXEC: one operation is captured; completion is produced by the next clock edge.
Reset State: IDLE.
```

### State Transition & Condition Name
1. `IDLE -> EXEC`：`issue_fire`
2. `EXEC -> IDLE`：`next cycle`
3. `ANY -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `issue_fire`：
   issue_fire = issue_valid ∧ FU_ready ∧ ¬flush.fire

2. `next cycle`：
   见本模块条件逻辑。

3. `flush`：
   见本模块条件逻辑。

## Data structure
### State

- ``busy_q``：Width=1; Role=execution state; Reset=0; Update=issue -> 1; next cycle/flush -> 0
- ``wb_payload``：Width=completion schema; Role=completion register; Reset=zero; Update=issue edge; next cycle/flush -> zero

### Header

`self_tag` (4), `exe_subop` (24), and `full_decode.rm` (3 of 17) are consumed by operation selection and completion tagging.

### Payload

Operands are combinational inputs; result and flags are stored in `wb_payload`.

## Data Path
- `G2 issue payload` -> `FP datapath`：operands/subop/rm；驱动 `issue`；`issue_fire`
- `result/flags/tag` -> ``wb_payload``：completion schema；驱动 FP datapath；issue edge
- ``wb_payload`` -> `lane 2 consumers`：`completion_common_t`；驱动 `completion`；`completion.fire`
- ``wb_payload`` -> `all ISQ groups`：`{tag,data}`；驱动 `bypass_publish`；`bypass_publish.fire`

## Interface

### In-event

- `issue`：Transaction；G2 issue payload；capture when `issue_valid ∧ FU_ready`
- `flush`：Notify；`∅`；clear busy/output

### In Static Info

- 无。

### Out-event

- `completion`:
  The complete payload is registered one cycle after `issue_fire`.
- ``result_valid``：Width / Type=1; Generation rule=`wb_payload.result_valid`
- ``tag_out``：Width / Type=`TAG_W=4`; Generation rule=issue `self_tag`
- ``result_data``：Width / Type=`XLEN=64`; Generation rule=`fpu_result`
- ``mispredict_flag`, `mispredict_target_pc``：Width / Type=1 + 64; Generation rule=zero
- ``exception_flag`, `exception_cause`, `exception_tval``：Width / Type=1 + 63 + 64; Generation rule=zero
- ``is_mret`, `is_sret``：Width / Type=1 + 1; Generation rule=zero
- ``fpu_fflags``：Width / Type=5; Generation rule=FPU operation/rounder flags
- `bypass_publish`:
  ```text
  bypass_publish.fire = Result_valid ∧ ¬flush.fire
  bypass_publish.tag  = tag_out
  bypass_publish.data = result_data
  ```

  Lane 2 completion and bypass are sourced from the same `wb_payload` register.

### Out Static Info

```text
FU_ready = ¬busy_q
```
- `FU_ready`：Static Info；1 bit；combinational

### Interface Timing

- 无。


