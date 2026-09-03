# Module `SerialInstructionTracker`

> Source: `work/rtl/rtl_v1/p4/SerialInstructionTracker.sv`  
> Modeling class: single-bit FSM

## 1. Boundary and Responsibility
Tracks the one serial instruction interlock; set by dispatch, clear by matching commit or flush.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic serial_set` | event/control |
| input | `logic [TAG_W-1:0] self_tag` | payload or static info |
| input | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| input | `logic global_flush_late` | event/control |
| output | `logic serial_inflight_valid` | event/control |

## 3. Events
### `serial_set` (in)
- **Fire来源:** `serial_set`
- **Payload来源:** self_tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `commit_clear` (in)
- **Fire来源:** `serial_inflight_valid ∧ commit_valid[k] ∧ commit_tag[k] == serial_inflight_tag`
- **Payload来源:** commit tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** IDLE / INFLIGHT
- **Header:** serial_inflight_tag
- **Payload:** none
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
serial_set -> tag latch; commit tag match/flush -> valid clear.

## 6. Control Path
IDLE->INFLIGHT on set; INFLIGHT->IDLE on clear or flush.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE | serial_set | INFLIGHT / latch tag |
| INFLIGHT | matching commit or flush | IDLE |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.