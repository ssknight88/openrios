# Module `system_instruction_handler`

> Source: `work/rtl/rtl_v1/p4/system_instruction_handler.sv`  
> Modeling class: architectural CSR + speculative stage

## 1. Boundary and Responsibility
Owns CSR file, privilege state, trap vector and the one speculative CSR write stage.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic Result_valid` | event/control |
| input | `logic [TAG_W-1:0] tag_out` | payload or static info |
| input | `logic sb_is_csr` | payload or static info |
| input | `logic sb_csr_write_enable` | payload or static info |
| input | `logic [CSR_ADDR_W-1:0] sb_csr_addr` | payload or static info |
| input | `logic [XLEN-1:0] sb_csr_wdata` | payload or static info |
| input | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| input | `logic [FFLAGS_W-1:0] commit_fflags [ISSUE_WIDTH]` | event/control |
| input | `logic rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic rd_write_enable [ISSUE_WIDTH]` | event/control |
| input | `logic [COMMIT_COUNT_W-1:0] commit_count` | event/control |
| input | `trap_state_write_t trap_state_write` | event/control |
| input | `logic global_flush_late` | event/control |
| input | `logic [CSR_ADDR_W-1:0] csr_addr` | payload or static info |
| input | `logic [EXCP_CAUSE_W-1:0] trap_cause_in` | payload or static info |
| input | `logic trap_is_interrupt_in` | payload or static info |
| input | `logic mip_meip` | payload or static info |
| input | `logic mip_mtip` | payload or static info |
| input | `logic mip_msip` | payload or static info |
| output | `logic [XLEN-1:0] csr_rdata` | payload or static info |
| output | `logic [PRIV_W-1:0] current_priv` | payload or static info |
| output | `rm_e frm` | payload or static info |
| output | `logic fs_enabled` | payload or static info |
| output | `logic [XLEN-1:0] trap_vector` | payload or static info |
| output | `logic interrupt_pending` | payload or static info |
| output | `logic [EXCP_CAUSE_W-1:0] interrupt_cause` | payload or static info |
| output | `logic [XLEN-1:0] mepc` | payload or static info |
| output | `logic [XLEN-1:0] sepc` | payload or static info |
| output | `logic mstatus_tvm` | payload or static info |
| output | `logic mstatus_tw` | payload or static info |
| output | `logic mstatus_tsr` | payload or static info |

## 3. Events
### `capture` (in)
- **Fire来源:** `Result_valid ∧ sb_is_csr ∧ sb_csr_write_enable ∧ ¬global_flush_late`
- **Payload来源:** tag_out, sb_csr_addr, sb_csr_wdata
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `apply` (in)
- **Fire来源:** `csr_stage.valid ∧ tag_hit_on_commit`
- **Payload来源:** commit tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `commit` (in)
- **Fire来源:** `commit_valid[k]`
- **Payload来源:** commit_fflags, rd_is_fp, rd_write_enable, commit_count
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `trap_state_write` (in)
- **Fire来源:** `trap_state_write.valid`
- **Payload来源:** kind, epc, cause, tval
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** clears csr_stage only
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `csr_read` (out)
- **Fire来源:** `∅`
- **Payload来源:** csr_addr -> csr_rdata
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `trap_vector_read` (out)
- **Fire来源:** `∅`
- **Payload来源:** trap_cause_in, trap_is_interrupt_in -> trap_vector
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** csr_stage EMPTY / STAGED; architectural CSR registers
- **Header:** csr_stage.tag/addr/wdata; current_priv and mstatus.MPP
- **Payload:** CSR architectural state, trap state, counters
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
capture completion sideband -> csr_stage; commit tag hit -> architectural CSR write; trap_state_write -> trap entry/mret/sret.

## 6. Control Path
capture/apply/flush stage FSM; architectural updates are event actions.

| Current state | Condition/event | Next state/action |
|---|---|---|
| EMPTY | capture | STAGED / latch CSR sideband |
| STAGED | matching commit | EMPTY / apply CSR write |
| STAGED | flush | EMPTY / discard stage |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.