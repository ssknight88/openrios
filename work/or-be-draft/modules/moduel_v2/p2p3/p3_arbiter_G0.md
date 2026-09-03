# Module `p3_arbiter_G0`

> Source: `work/rtl/rtl_v1/p2p3/p3_arbiter_G0.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Static-priority G0 completion arbiter: ALU0/BRU > CSR > DIV, forwards one request and broadcasts non-exception result.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic request_valid [G0_NUM_FU]` | event/control |
| input | `logic [TAG_W-1:0] req_tag [G0_NUM_FU]` | payload or static info |
| input | `logic [XLEN-1:0] req_result_data [G0_NUM_FU]` | payload or static info |
| input | `logic req_mispredict_flag [G0_NUM_FU]` | payload or static info |
| input | `logic [XLEN-1:0] req_mispredict_target_pc [G0_NUM_FU]` | payload or static info |
| input | `logic req_exception_flag [G0_NUM_FU]` | payload or static info |
| input | `logic [EXCP_CAUSE_W-1:0] req_exception_cause [G0_NUM_FU]` | payload or static info |
| input | `logic [XLEN-1:0] req_exception_tval [G0_NUM_FU]` | payload or static info |
| input | `logic req_is_mret [G0_NUM_FU]` | payload or static info |
| input | `logic req_is_sret [G0_NUM_FU]` | payload or static info |
| input | `logic [FFLAGS_W-1:0] req_fpu_fflags [G0_NUM_FU]` | payload or static info |
| input | `logic req_is_csr [G0_NUM_FU]` | payload or static info |
| input | `logic req_csr_write_enable [G0_NUM_FU]` | payload or static info |
| input | `logic [CSR_ADDR_W-1:0] req_csr_addr [G0_NUM_FU]` | payload or static info |
| input | `logic [XLEN-1:0] req_csr_wdata [G0_NUM_FU]` | payload or static info |
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
| output | `logic is_csr` | payload or static info |
| output | `logic csr_write_enable` | payload or static info |
| output | `logic [CSR_ADDR_W-1:0] csr_addr` | payload or static info |
| output | `logic [XLEN-1:0] csr_wdata` | payload or static info |
| output | `logic bypass_valid` | event/control |
| output | `logic [TAG_W-1:0] bypass_tag` | event/control |
| output | `logic [XLEN-1:0] bypass_data` | event/control |
| output | `logic winner_grant [G0_NUM_FU]` | payload or static info |
| output | `logic loser_hold [G0_NUM_FU]` | payload or static info |

## 3. Events
### `winner_select` (out)
- **Fire来源:** `winner_valid = ∨k request_valid[k]; winner_idx = lowest valid k`
- **Payload来源:** winner_grant[0:2], loser_hold[0:2]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `writeback` (out)
- **Fire来源:** `Result_valid = winner_valid`
- **Payload来源:** completion_common lane 0 plus CSR sideband
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `bypass_publish` (out)
- **Fire来源:** `bypass_valid = Result_valid ∧ ¬exception_flag`
- **Payload来源:** bypass_tag, bypass_data
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** request_valid[0:2], winner priority
- **Payload:** winner completion_common; winner_grant/loser_hold; bypass publish; CSR sideband
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
three request bundles -> first-valid winner -> lane-0 completion and feedback.

## 6. Control Path
pure combinational priority select.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.