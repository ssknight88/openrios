# Module `flush_model`

> Source: `work/rtl/rtl_v1/p4/flush_model.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Translates SCB flush decision into one global broadcast, FE redirect and trap-state write.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic [RECOVERY_KIND_W-1:0] recovery_kind` | payload or static info |
| input | `logic flush_valid` | event/control |
| input | `logic [TAG_W-1:0] flush_tag` | event/control |
| input | `logic [XLEN-1:0] mispredict_target_pc` | payload or static info |
| input | `logic [EXCP_CAUSE_W-1:0] exception_cause` | payload or static info |
| input | `logic [XLEN-1:0] exception_tval` | payload or static info |
| input | `logic [XLEN-1:0] inst_pc` | payload or static info |
| input | `logic [XLEN-1:0] mepc` | payload or static info |
| input | `logic [XLEN-1:0] sepc` | payload or static info |
| input | `logic [EXCP_CAUSE_W-1:0] interrupt_cause` | payload or static info |
| input | `logic [XLEN-1:0] trap_vector` | payload or static info |
| output | `logic global_flush_late` | event/control |
| output | `logic redirect_valid` | event/control |
| output | `logic [XLEN-1:0] redirect_pc` | payload or static info |
| output | `logic [RECOVERY_KIND_W-1:0] redirect_kind` | payload or static info |
| output | `logic frontend_icache_invalidate` | event/control |
| output | `trap_state_write_t trap_state_write` | event/control |
| output | `logic [EXCP_CAUSE_W-1:0] cause` | payload or static info |
| output | `logic is_interrupt` | payload or static info |

## 3. Events
### `global_flush_late` (out)
- **Fire来源:** `global_flush_late = flush_valid`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `redirect` (out)
- **Fire来源:** `redirect_valid = flush_valid`
- **Payload来源:** redirect_pc, redirect_kind, frontend_icache_invalidate
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `trap_state_write` (out)
- **Fire来源:** `trap_state_write.valid = flush_valid ∧ kind_sel ∈ {EXCEPTION, MRET, SRET, INTERRUPT}`
- **Payload来源:** trap_state_write_t
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `trap_vector_read` (out)
- **Fire来源:** `∅`
- **Payload来源:** cause, is_interrupt -> trap_vector
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** flush_valid, recovery_kind, flush_tag; recovery reads
- **Payload:** global_flush_late; redirect; trap_state_write; trap_vector arguments
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
kind-select -> recovery PC/cause/tval -> redirect/trap pack and global flush fanout.

## 6. Control Path
pure combinational; recovery kind case select.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.