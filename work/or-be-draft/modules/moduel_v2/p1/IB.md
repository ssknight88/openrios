# Module `IB`

> Source: `work/rtl/rtl_v1/p1/IB.sv`  
> Modeling class: sequential FIFO

## 1. Boundary and Responsibility
Eight-entry instruction buffer. Stores raw FE payload, uses compressed pointers wptr/rptr, and exposes two head slots.

## 2. Interface
| Direction | RTL declaration                              | Role          |
| --------- | -------------------------------------------- | ------------- |
| input     | `logic clk`                                  | clock/reset   |
| input     | `logic rst_n`                                | clock/reset   |
| input     | `ib_payload_t enq_IB_Payload [ISSUE_WIDTH]`  | event/control |
| input     | `logic [ISSUE_WIDTH-1:0] fe_valid`           | event/control |
| input     | `logic ib_dequeue [ISSUE_WIDTH]`             | event/control |
| input     | `logic global_flush_late`                    | event/control |
| output    | `ib_payload_t head_IB_Payload [ISSUE_WIDTH]` | event/control |
| output    | `logic [ISSUE_WIDTH-1:0] inst_valid`         | event/control |
| output    | `logic [ISSUE_WIDTH-1:0] fe_ready`           | event/control |
| output    | `logic [ISSUE_WIDTH-1:0] accepted_slot`      | event/control |

## 3. Events
### `enqueue` (in)
- **Fire来源:** `accepted_slot[s] = fe_valid[s] ∧ fe_ready[s]`
- **Payload来源:** fe_instr_pld[s]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `dequeue` (out)
- **Fire来源:** `ib_dequeue[s] ∧ inst_valid[s]`
- **Payload来源:** head slot index s
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** reset both pointers
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** FREE / RESIDENT projected by ring interval
- **Header:** none
- **Payload:** ib_payload_t per slot
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
FE payload -> wptr+n entries; rptr+s -> head payload; accepted slots advance pointers.

## 6. Control Path
structure FSM: pointer update with flush > enqueue/dequeue priority.

| Current state | Condition/event | Next state/action |
|---|---|---|
| FREE | dispatch | RESIDENT / capture payload subset |
| RESIDENT | issue without replacement dispatch | FREE |
| RESIDENT | bypass_capture | RESIDENT / update matching source |
| ANY | flush | FREE / clear valid |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.