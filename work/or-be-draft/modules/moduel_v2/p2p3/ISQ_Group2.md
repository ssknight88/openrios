# Module `ISQ_Group2`

> Source: `work/rtl/rtl_v1/p2p3/ISQ_Group2.sv`  
> Modeling class: single-entry FSM

## 1. Boundary and Responsibility
FPU issue queue. Three-source readiness, bypass capture and same-cycle bypass-around issue.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `isq_payload_t payload_in` | payload or static info |
| input | `logic wr_en` | event/control |
| input | `logic bypass_valid [NUM_LANES]` | event/control |
| input | `logic [TAG_W-1:0] bypass_tag [NUM_LANES]` | event/control |
| input | `logic [XLEN-1:0] bypass_data [NUM_LANES]` | event/control |
| input | `logic global_flush_late` | event/control |
| input | `logic FU_ready` | event/control |
| output | `logic issue_valid` | event/control |
| output | `logic [XLEN-1:0] rs1_data` | payload or static info |
| output | `logic [XLEN-1:0] rs2_data` | payload or static info |
| output | `logic [XLEN-1:0] rs3_data` | payload or static info |
| output | `logic [TAG_W-1:0] self_tag` | payload or static info |
| output | `logic [EXE_SUBOP_W-1:0] exe_subop` | payload or static info |
| output | `logic [FULL_DECODE_W-1:0] full_decode` | payload or static info |
| output | `logic isq_free_for_dispatch` | payload or static info |

## 3. Events
### `dispatch` (in)
- **Fire来源:** `wr_en`
- **Payload来源:** payload subset
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `bypass_capture` (in)
- **Fire来源:** `entry_valid ∧ ¬global_flush_late ∧ ¬issue_fire ∧ tag_match`
- **Payload来源:** bypass_tag, bypass_data
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `issue` (out)
- **Fire来源:** `entry_valid ∧ operand_ready ∧ FU_ready ∧ ¬global_flush_late`
- **Payload来源:** rs1/rs2/rs3_data, self_tag, exe_subop, full_decode
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** FREE / RESIDENT via entry_valid
- **Header:** rs1/rs2/rs3 ready/wait_tag
- **Payload:** rs1/rs2/rs3_data, self_tag, exe_subop, full_decode
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
dispatch -> entry; three bypass matchers -> source data; entry -> FPU issue.

## 6. Control Path
flush > dispatch > issue > bypass_capture; same-cycle dispatch+issue retains resident state.

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