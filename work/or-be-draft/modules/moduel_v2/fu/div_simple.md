# Module `div_simple`

> Source: `work/rtl/rtl_v1/fu/div_simple.sv`  
> Modeling class: sequential FU

## 1. Boundary and Responsibility
G0 integer divide/remainder FU with iterative datapath and registered completion.

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
| input | `logic winner_grant` | payload or static info |
| input | `logic loser_hold` | payload or static info |
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

## 3. Events
### `issue` (in)
- **Fire来源:** `issue_valid ∧ (FU_Group == G0_FU_DIV) ∧ FU_ready ∧ ¬global_flush_late`
- **Payload来源:** rs1_data, rs2_data, self_tag, exe_subop
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `completion_request` (out)
- **Fire来源:** `request_valid ∧ winner_grant ∧ ¬global_flush_late`
- **Payload来源:** req_tag, req_result_data, zero exception/mispredict/mret/fpu fields
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** voids in-flight division
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** IDLE / ITERATE / WRITEBACK / HOLD
- **Header:** self_tag, FU_Group
- **Payload:** completion_common
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
issue operands -> divide iteration -> result register -> completion hold.

## 6. Control Path
issue capture, iterative countdown, winner acknowledgement; flush clears all stages.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE/EXEC | issue | execute or register payload |
| EXEC/HOLD | completion acknowledgement | IDLE |
| ANY | flush | IDLE / clear in-flight state |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.