# Module `alu_simple`

> Source: `work/rtl/rtl_v1/fu/alu_simple.sv`  
> Modeling class: sequential FU

## 1. Boundary and Responsibility
G0 ALU0/BRU and G1 ALU1 execute unit. Arithmetic, branch resolution, system/illegal checks; completion is registered.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic global_flush_late` | event/control |
| input | `logic issue_valid` | event/control |
| input | `logic [XLEN-1:0] rs1_data` | payload or static info |
| input | `logic [XLEN-1:0] rs2_data` | payload or static info |
| input | `logic [FU_GROUP_W-1:0] FU_Group` | payload or static info |
| input | `logic imm_valid` | event/control |
| input | `logic [XLEN-1:0] imm_data` | payload or static info |
| input | `logic [XLEN-1:0] pc` | payload or static info |
| input | `logic [31:0] inst_bits` | payload or static info |
| input | `logic is_compressed` | payload or static info |
| input | `logic pred_taken` | payload or static info |
| input | `logic [XLEN-1:0] pred_target_pc` | payload or static info |
| input | `logic [TAG_W-1:0] self_tag` | payload or static info |
| input | `logic [EXE_SUBOP_W-1:0] exe_subop` | payload or static info |
| input | `logic [FULL_DECODE_W-1:0] full_decode` | payload or static info |
| input | `logic [PRIV_W-1:0] current_priv` | payload or static info |
| input | `logic mstatus_tsr` | payload or static info |
| input | `logic mstatus_tw` | payload or static info |
| input | `logic mstatus_tvm` | payload or static info |
| input | `logic fetch_excp_vld` | payload or static info |
| input | `logic [FETCH_EXCP_CAUSE_W-1:0] fetch_excp_cause` | payload or static info |
| input | `logic [XLEN-1:0] fetch_excp_tval` | payload or static info |
| output | `logic FU_ready` | event/control |
| output | `logic request_valid` | event/control |
| output | `logic [TAG_W-1:0] req_tag` | payload or static info |
| output | `logic [XLEN-1:0] req_result_data` | payload or static info |
| output | `logic req_mispredict_flag` | payload or static info |
| output | `logic [XLEN-1:0] req_mispredict_target_pc` | payload or static info |
| output | `logic req_exception_flag` | payload or static info |
| output | `logic [EXCP_CAUSE_W-1:0] req_exception_cause` | payload or static info |
| output | `logic [XLEN-1:0] req_exception_tval` | payload or static info |
| output | `logic req_is_mret` | payload or static info |
| output | `logic req_is_sret` | payload or static info |
| output | `logic [FFLAGS_W-1:0] req_fpu_fflags` | payload or static info |
| output | `logic req_is_csr` | payload or static info |
| output | `logic req_csr_write_enable` | payload or static info |
| output | `logic [CSR_ADDR_W-1:0] req_csr_addr` | payload or static info |
| output | `logic [XLEN-1:0] req_csr_wdata` | payload or static info |
| output | `logic predictor_update_valid` | event/control |
| output | `logic [XLEN-1:0] predictor_update_branch_pc` | payload or static info |
| output | `logic predictor_update_actual_taken` | payload or static info |
| output | `logic [XLEN-1:0] predictor_update_actual_target` | payload or static info |
| output | `cf_class_e predictor_update_cf_class` | payload or static info |
| input | `logic winner_grant` | payload or static info |
| input | `logic loser_hold` | payload or static info |

## 3. Events
### `issue` (in)
- **Fire来源:** `issue_valid ∧ FU_ready ∧ ¬global_flush_late`
- **Payload来源:** rs1_data, rs2_data, imm_*, pc, inst_bits, prediction, self_tag, exe_subop, full_decode
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `completion_request` (out)
- **Fire来源:** `request_valid ∧ winner_grant ∧ ¬global_flush_late`
- **Payload来源:** req_tag, req_result_data, req_mispredict_*, req_exception_*, req_is_mret/req_is_sret, req_fpu_fflags
- **约束:** G0 uses arbiter handshake; G1 constant-zero sidebands are driven locally.
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** kills in-flight work and masks request_valid
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `predictor_update` (out)
- **Fire来源:** `predictor_update_valid`
- **Payload来源:** branch_pc, actual_taken, actual_target, cf_class
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** IDLE / EXEC / HOLD (busy_reg plus held completion)
- **Header:** self_tag, branch/prediction inputs, full_decode
- **Payload:** completion_common; predictor_update sideband
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
issue operands -> ALU/BRU datapath -> registered completion request; branch result and exception sidebands leave on the same completion edge.

## 6. Control Path
issue capture, execution/hold, winner acknowledgement; flush has priority.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE/EXEC | issue | execute or register payload |
| EXEC/HOLD | completion acknowledgement | IDLE |
| ANY | flush | IDLE / clear in-flight state |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.