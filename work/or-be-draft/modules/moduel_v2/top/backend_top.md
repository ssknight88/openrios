# Module `backend_top`

> Source: `work/rtl/rtl_v1/top/backend_top.sv`  
> Modeling class: integration / pure wiring

## 1. Boundary and Responsibility
Top-level backend integration. Instantiates and wires all modules; only documented glue projections are present.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic [ISSUE_WIDTH-1:0] fe_valid` | event/control |
| input | `fe_be_instr_pld_t fe_instr_pld [ISSUE_WIDTH]` | event/control |
| output | `logic [ISSUE_WIDTH-1:0] fe_ready` | event/control |
| output | `logic [ISSUE_WIDTH-1:0] accepted_slot` | event/control |
| output | `logic redirect_valid` | event/control |
| output | `logic [XLEN-1:0] redirect_pc` | payload or static info |
| output | `logic [RECOVERY_KIND_W-1:0] redirect_kind` | payload or static info |
| output | `logic frontend_icache_invalidate` | event/control |
| output | `logic predictor_update_valid` | event/control |
| output | `logic [XLEN-1:0] predictor_update_branch_pc` | payload or static info |
| output | `logic predictor_update_actual_taken` | payload or static info |
| output | `logic [XLEN-1:0] predictor_update_actual_target` | payload or static info |
| output | `cf_class_e predictor_update_cf_class` | payload or static info |
| output | `logic be_lsu_issue_valid` | event/control |
| output | `be_lsu_issue_pld_t be_lsu_issue_pld` | event/control |
| output | `logic be_lsu_entry_ready` | event/control |
| output | `logic be_lsu_store_wakeup_valid` | event/control |
| output | `logic global_flush_late` | event/control |
| input | `logic lsu_be_issue_ready` | event/control |
| input | `logic lsu_be_done_valid` | event/control |
| input | `lsu_be_done_pld_t lsu_be_done_pld` | payload or static info |
| input | `logic lsu_be_exception_valid` | event/control |
| input | `lsu_be_exception_pld_t lsu_be_exception_pld` | payload or static info |
| input | `logic lsu_be_bypass_valid` | event/control |
| input | `lsu_be_done_pld_t lsu_be_bypass_pld` | event/control |
| input | `logic mip_meip` | payload or static info |
| input | `logic mip_mtip` | payload or static info |
| input | `logic mip_msip` | payload or static info |
| output | `logic alloc_valid [ISSUE_WIDTH]` | event/control |
| output | `logic [TAG_W-1:0] alloc_tag [ISSUE_WIDTH]` | event/control |
| output | `logic exec_valid [NUM_LANES]` | event/control |
| output | `logic [TAG_W-1:0] exec_tag [NUM_LANES]` | payload or static info |
| output | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| output | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| output | `logic [REG_ADDR_W-1:0] commit_rd_idx [ISSUE_WIDTH]` | event/control |
| output | `logic commit_rd_is_fp [ISSUE_WIDTH]` | event/control |
| output | `logic commit_rd_write_enable [ISSUE_WIDTH]` | event/control |
| output | `logic [FFLAGS_W-1:0] commit_fflags [ISSUE_WIDTH]` | event/control |
| output | `logic [COMMIT_COUNT_W-1:0] commit_count` | event/control |
| output | `logic [XLEN-1:0] commit_data [ISSUE_WIDTH]` | event/control |
| output | `logic [XLEN-1:0] trace_pc [ISSUE_WIDTH]` | event/control |
| output | `logic global_flush_valid` | event/control |

## 3. Events
### `fe_enqueue` (in)
- **Fire来源:** `fe_valid[s] ∧ fe_ready[s]`
- **Payload来源:** fe_instr_pld[s]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `redirect` (out)
- **Fire来源:** `redirect_valid`
- **Payload来源:** redirect_pc, redirect_kind, frontend_icache_invalidate
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_issue` (out)
- **Fire来源:** `be_lsu_issue_valid ∧ lsu_be_issue_ready`
- **Payload来源:** be_lsu_issue_pld
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `lsu_done` (in)
- **Fire来源:** `lsu_be_done_valid`
- **Payload来源:** lsu_be_done_pld
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `commit` (out)
- **Fire来源:** `commit_valid[k]`
- **Payload来源:** commit_tag, commit_rd_*, commit_fflags, commit_count
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (out)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `observation` (out)
- **Fire来源:** `∅`
- **Payload来源:** alloc_*, exec_*, commit_*, trace_pc, global_flush_valid
- **约束:** static observation projections
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none at top level; child states are authoritative
- **Header:** child-module nets and observation buses
- **Payload:** FE/LSU boundary structs, commit/exec/alloc observations
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
FE -> IB -> P1 -> ISQ/FU -> completion/SCB -> FE/LSU/architectural outputs.

## 6. Control Path
no independent FSM; child events and seven documented glue operations define behavior.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.