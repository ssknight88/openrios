# Module `dispatch_logic`

> Source: `work/rtl/rtl_v1/p1/dispatch_logic.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Single admission point. Routes each decoded slot, applies legality/effective rounding, and creates mutually constrained admission events.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic slot0_present` | payload or static info |
| input | `logic slot1_present` | payload or static info |
| input | `logic serial0` | payload or static info |
| input | `logic serial_inst` | payload or static info |
| input | `logic fp0` | payload or static info |
| input | `logic fp1` | payload or static info |
| input | `logic slot_missed_wakeup [ISSUE_WIDTH]` | event/control |
| input | `logic [EXE_SUBOP_W-1:0] exe_subop [ISSUE_WIDTH]` | event/control |
| input | `full_decode_t full_decode [ISSUE_WIDTH]` | event/control |
| input | `logic is_fp_instruction [ISSUE_WIDTH]` | event/control |
| input | `logic fs_enabled` | payload or static info |
| input | `rm_e frm` | payload or static info |
| input | `logic can_alloc_1` | payload or static info |
| input | `logic can_alloc_2` | payload or static info |
| input | `logic buffer_empty` | payload or static info |
| input | `logic isq_free_for_dispatch [NUM_LANES]` | payload or static info |
| input | `logic serial_inflight_valid` | event/control |
| input | `logic [TAG_W-1:0] self_tag` | payload or static info |
| input | `logic global_flush_late` | event/control |
| output | `logic accept [ISSUE_WIDTH]` | event/control |
| output | `logic ib_dequeue [ISSUE_WIDTH]` | event/control |
| output | `logic isq_wr_en [NUM_LANES]` | event/control |
| output | `logic [FU_GROUP_W-1:0] slot_FU_Group [ISSUE_WIDTH]` | event/control |
| output | `rm_e effective_rm [ISSUE_WIDTH]` | event/control |
| output | `logic is_fence_i [ISSUE_WIDTH]` | event/control |
| output | `logic may_flush [ISSUE_WIDTH]` | event/control |
| output | `logic is_atomic [ISSUE_WIDTH]` | event/control |
| output | `logic serial_set` | event/control |
| output | `logic [TAG_W-1:0] serial_set_tag` | event/control |
| output | `logic select_payload [NUM_LANES][ISSUE_WIDTH]` | event/control |

## 3. Events
### `accept` (out)
- **Fire来源:** `accept[0] = slot0_present ∧ slot0_guard_ok; accept[1] = accept[0] ∧ slot1_present ∧ slot1_guard_ok`
- **Payload来源:** accept[0:1]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `ib_dequeue` (out)
- **Fire来源:** `ib_dequeue[s] = accept[s]`
- **Payload来源:** ib_dequeue[0:1]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `isq_dispatch` (out)
- **Fire来源:** `isq_wr_en[g] = ∨s select_payload[g][s]`
- **Payload来源:** isq_wr_en[0:NUM_LANES-1], select_payload
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `serial_set` (out)
- **Fire来源:** `serial_set = accept[0] ∧ serial0`
- **Payload来源:** serial_set, serial_set_tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `alloc_metadata` (out)
- **Fire来源:** `∅`
- **Payload来源:** slot_FU_Group, effective_rm, is_fence_i, may_flush, is_atomic
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** dependency projections, decode results, FP state, SCB/ISQ readiness, serial state
- **Payload:** accept, ib_dequeue, isq_wr_en, slot_FU_Group, effective_rm, serial_set, select_payload, SCB header bits
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
classify -> legality/effective_rm -> group choice -> slot guards -> accept/dequeue/ISQ writes.

## 6. Control Path
pure combinational; route priority and admission guards are predicates.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.