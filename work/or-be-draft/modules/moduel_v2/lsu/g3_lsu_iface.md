# Module `g3_lsu_iface`

> Source: `work/rtl/rtl_v1/lsu/g3_lsu_iface.sv`  
> Modeling class: bridge with per-tag state

## 1. Boundary and Responsibility
LSU bridge: assembles issue payload, folds LSU ready, relays store wakeup, merges done/exception/bypass.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic issue_valid` | event/control |
| input | `logic [TAG_W-1:0] self_tag` | payload or static info |
| input | `logic [EXE_SUBOP_W-1:0] exe_subop` | payload or static info |
| input | `logic [MEM_FUNCT3_W-1:0] mem_funct3` | payload or static info |
| input | `logic rd_is_fp` | payload or static info |
| input | `logic [XLEN-1:0] rs1_data` | payload or static info |
| input | `logic [XLEN-1:0] rs2_data` | payload or static info |
| input | `logic imm_valid` | event/control |
| input | `logic signed [XLEN-1:0] imm_data` | payload or static info |
| input | `logic is_store` | payload or static info |
| input | `logic st_br_resolve` | payload or static info |
| input | `logic store_wakeup_valid` | event/control |
| input | `logic [TAG_W-1:0] store_wakeup_tag` | event/control |
| input | `logic global_flush_late` | event/control |
| input | `logic lsu_be_issue_ready` | event/control |
| input | `logic lsu_be_done_valid` | event/control |
| input | `lsu_be_done_pld_t lsu_be_done_pld` | payload or static info |
| input | `logic lsu_be_exception_valid` | event/control |
| input | `lsu_be_exception_pld_t lsu_be_exception_pld` | payload or static info |
| input | `logic lsu_be_bypass_valid` | event/control |
| input | `lsu_be_done_pld_t lsu_be_bypass_pld` | event/control |
| output | `logic FU_ready` | event/control |
| output | `logic Result_valid` | event/control |
| output | `logic [TAG_W-1:0] tag_out` | payload or static info |
| output | `logic [XLEN-1:0] result_data` | payload or static info |
| output | `logic mispredict_flag` | payload or static info |
| output | `logic [XLEN-1:0] mispredict_target_pc` | payload or static info |
| output | `logic exception_flag` | payload or static info |
| output | `logic [EXCP_CAUSE_W-1:0] exception_cause` | payload or static info |
| output | `logic [XLEN-1:0] exception_tval` | payload or static info |
| output | `logic is_mret` | payload or static info |
| output | `logic is_sret` | payload or static info |
| output | `logic [FFLAGS_W-1:0] fpu_fflags` | payload or static info |
| output | `logic bypass_valid` | event/control |
| output | `logic [TAG_W-1:0] bypass_tag` | event/control |
| output | `logic [XLEN-1:0] bypass_data` | event/control |
| output | `logic be_lsu_issue_valid` | event/control |
| output | `be_lsu_issue_pld_t be_lsu_issue_pld` | event/control |
| output | `logic be_lsu_entry_ready` | event/control |
| output | `logic be_lsu_store_wakeup_valid` | event/control |

## 3. Events
### `issue` (in)
- **Fire来源:** `issue_valid ∧ bridge_has_room ∧ lsu_be_issue_ready ∧ ¬global_flush_late`
- **Payload来源:** self_tag, exe_subop, mem_funct3, rd_is_fp, rs1/rs2_data, imm_*, is_store
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_issue` (out)
- **Fire来源:** `be_lsu_issue_valid ∧ lsu_be_issue_ready`
- **Payload来源:** be_lsu_issue_pld_t
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `store_wakeup` (in)
- **Fire来源:** `store_wakeup_valid ∧ rst_n`
- **Payload来源:** store_wakeup_tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `store_wakeup_relay` (out)
- **Fire来源:** `be_lsu_store_wakeup_valid`
- **Payload来源:** ∅
- **约束:** immediate or held relay
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_done` (in)
- **Fire来源:** `lsu_be_done_valid`
- **Payload来源:** lsu_be_done_pld_t(tag,data)
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_exception` (in)
- **Fire来源:** `lsu_be_exception_valid`
- **Payload来源:** lsu_be_exception_pld_t(tag,cause,tval)
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_bypass` (in)
- **Fire来源:** `lsu_be_bypass_valid`
- **Payload来源:** lsu_be_bypass_pld_t(tag,data)
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `completion` (out)
- **Fire来源:** `Result_valid`
- **Payload来源:** tag_out, result_data, exception_*
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** clears per-tag state
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** req_in_flight_q[tag], wakeup_held_q[tag]
- **Header:** self_tag, st_br_resolve, wakeup tag
- **Payload:** be_lsu_issue_pld_t; lane-3 completion_common; store_wakeup
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
ISQ issue fields + req_property_from_subop + st_br_resolve -> LSU payload; LSU result structs -> lane-3 completion/CDB.

## 6. Control Path
per-tag in-flight and delayed wakeup bookkeeping; flush clears all tag bits.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE/EXEC | issue | execute or register payload |
| EXEC/HOLD | completion acknowledgement | IDLE |
| ANY | flush | IDLE / clear in-flight state |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.