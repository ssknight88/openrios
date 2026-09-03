# Module `alu_simple`

`alu_simple`：execute integer ALU, branch, and G0 system operations; publish completion。

## Submodule
无。

## FSM
### State
#### Per-entry State
```text
IDLE: no completion is held.
HOLD: `comp_q.result_valid=1`; completion waits for `winner_grant`.
Structure state: `comp_q.result_valid`; 0 -> IDLE, 1 -> HOLD.
Reset: IDLE, all registers zero.
```

### State Transition & Condition Name
1. `IDLE -> HOLD`：`issue_fire`
2. `HOLD -> IDLE`：`winner_ack`
3. `HOLD -> HOLD`：`hold_request`
4. `ANY -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `issue_fire`：
   issue_fire = issue_valid ∧ FU_ready ∧ (FU_Group == 0) ∧ ¬flush.fire

2. `winner_ack`：
   winner_ack = winner_grant ∧ ¬flush.fire

3. `hold_request`：
   hold_request = comp_q.result_valid ∧ ¬winner_ack

4. `flush`：
   见本模块条件逻辑。

## Data structure
### State

- ``comp_q``：Width / Depth=completion schema; Role=held completion; Reset=zero; Update=issue capture; winner/flush clear
- ``pu_*_q``：Width / Depth=predictor payload; Role=notify register; Reset=zero; Update=issue cycle

### Header

`self_tag`, `FU_Group`, `exe_subop`, `full_decode`, and privilege inputs are consumed by the predicates above and are not stored as an independent queue.

### Payload

`comp_q` stores the complete completion payload. Predictor registers store the predictor payload. No architectural state is owned here.

## Data Path
- `ISQ issue payload` -> `ALU/BRU datapath`：`issue_alu_payload_t`；驱动 `issue`；`issue_fire`
- `datapath result/sidebands` -> ``comp_q``：`completion_common_t`；驱动 `issue`；issue edge
- ``comp_q`` -> `G0/G1 arbiter`：completion schema；驱动 `completion_request`；`request_valid`
- `branch result` -> `predictor registers`：predictor payload；驱动 `issue`；`issue_fire ∧ is_bru_op`
- `predictor registers` -> `FE`：predictor payload；驱动 `predictor_update`；predictor valid

## Interface

### In-event

- `issue`：Transaction；group-specific issue payload；same-cycle request
- `flush`：Notify；`∅`；masks issue and clears state

### In Static Info

- `winner_grant`：arbitration feedback；1 bit；completion release
- `loser_hold`：arbitration static info；1 bit；ready suppression
- `privilege/mstatus`：Static Info；control bits；combinational

### Out-event

- `completion_request`:
  The full `completion_common_t` payload is registered on `issue_fire`, one cycle after issue, and held while `winner_grant=0`.
- ``result_valid``：Width / Type=1; Generation rule=`comp_q.result_valid`
- ``tag_out``：Width / Type=`TAG_W=4`; Generation rule=issue `self_tag`
- ``result_data``：Width / Type=64; Generation rule=link `fallthrough_pc` for JAL/JALR forms, else `alu_result`
- ``mispredict_flag``：Width / Type=1; Generation rule=`mispredict`
- ``mispredict_target_pc``：Width / Type=64; Generation rule=`correct_pc`
- ``exception_flag``：Width / Type=1; Generation rule=fetch fault or illegal/ECALL/EBREAK predicate
- ``exception_cause``：Width / Type=63; Generation rule=fetch cause; illegal 2; ECALL U/S/M 8/9/11; EBREAK 3
- ``exception_tval``：Width / Type=64; Generation rule=fetch address; raw instruction (compressed low16); EBREAK PC; else 0
- ``is_mret`, `is_sret``：Width / Type=1 each; Generation rule=legal MRET/SRET predicates
- ``fpu_fflags``：Width / Type=5; Generation rule=zero

  G0 CSR sideband fields are zero from this FU (`req_is_csr`, write enable, address, data). G1 event sidebands are zero by routing contract.
- `predictor_update`:
  ```text
  pu_valid_q = issue_fire ∧ is_bru_op
  predictor_update.fire = pu_valid_q ∧ ¬flush.fire
  payload = {branch_pc:pc, actual_taken:branch_taken,
             actual_target:correct_pc, cf_class:BRU subop class}
  ```

### Out Static Info

```text
FU_ready = ¬loser_hold
```
- `FU_ready`：Static Info；1 bit；`¬loser_hold`

### Interface Timing

- 无。


