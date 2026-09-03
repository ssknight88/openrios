# Module `ISQ_Group0`

> Source: `work/rtl/rtl_v1/p2p3/ISQ_Group0.sv`  
> Modeling class: single-entry FSM

## 1. Boundary and Responsibility
ALU0/BRU + CSR + DIV issue queue. Captures selected payload, tracks operand readiness, forwards bypass and issues to selected FU.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic wr_en` | event/control |
| input | `isq_payload_t payload_in` | payload or static info |
| input | `logic bypass_valid [NUM_LANES]` | event/control |
| input | `logic [TAG_W-1:0] bypass_tag [NUM_LANES]` | event/control |
| input | `logic [XLEN-1:0] bypass_data [NUM_LANES]` | event/control |
| input | `logic global_flush_late` | event/control |
| input | `logic FU_ready [G0_NUM_FU]` | event/control |
| output | `logic issue_valid` | event/control |
| output | `logic [XLEN-1:0] rs1_data` | payload or static info |
| output | `logic [XLEN-1:0] rs2_data` | payload or static info |
| output | `logic [FU_GROUP_W-1:0] FU_Group` | payload or static info |
| output | `logic imm_valid` | event/control |
| output | `logic [XLEN-1:0] imm_data` | payload or static info |
| output | `logic [XLEN-1:0] pc` | payload or static info |
| output | `logic [31:0] inst_bits` | payload or static info |
| output | `logic is_compressed` | payload or static info |
| output | `logic pred_taken` | payload or static info |
| output | `logic [XLEN-1:0] pred_target_pc` | payload or static info |
| output | `logic [TAG_W-1:0] self_tag` | payload or static info |
| output | `logic [EXE_SUBOP_W-1:0] exe_subop` | payload or static info |
| output | `logic [FULL_DECODE_W-1:0] full_decode` | payload or static info |
| output | `logic fetch_excp_vld` | payload or static info |
| output | `logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause` | payload or static info |
| output | `logic [XLEN-1:0] fetch_excp_tval` | payload or static info |
| output | `logic isq_free_for_dispatch` | payload or static info |

## 3. Events
### `dispatch` (in)
- **Fire来源:** `wr_en`
- **Payload来源:** payload_in subset
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `bypass_capture` (in)
- **Fire来源:** `isq_valid ∧ ¬global_flush_late ∧ ¬issue_fire ∧ bypass_valid[b] ∧ tag_match`
- **Payload来源:** bypass_tag, bypass_data
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `issue` (out)
- **Fire来源:** `issue_req ∧ fu_ready_sel ∧ ¬global_flush_late`
- **Payload来源:** FU_Group, rs1/rs2_data, imm_*, pc, prediction, self_tag, exe_subop, full_decode
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** FREE / RESIDENT via isq_valid
- **Header:** ready/wait_tag per rs1/rs2; FU_Group
- **Payload:** rs1/rs2 data, imm, pc, prediction, self_tag, exe_subop, full_decode subset
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
dispatch -> entry; bypass tag match -> source update; entry -> selected FU issue bus.

## 6. Control Path
flush > dispatch/issue > bypass; same-cycle dispatch+issue allowed.

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