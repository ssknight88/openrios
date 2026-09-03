# Module `CompletionScoreboard`

> Source: `work/rtl/rtl_v1/p4/CompletionScoreboard.sv`  
> Modeling class: structure FSM / retire authority

## 1. Boundary and Responsibility
Single retirement authority. Compresses validity into head/tail pointers, tracks terminal execution and store wakeup, emits commit/flush.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic accept [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] alloc_self_tag [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rd_idx [ISSUE_WIDTH]` | event/control |
| input | `logic rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic rd_write_enable [ISSUE_WIDTH]` | event/control |
| input | `logic is_store [ISSUE_WIDTH]` | event/control |
| input | `logic is_fence_i [ISSUE_WIDTH]` | event/control |
| input | `logic may_flush [ISSUE_WIDTH]` | event/control |
| input | `logic is_atomic [ISSUE_WIDTH]` | event/control |
| input | `logic Result_valid [NUM_LANES]` | event/control |
| input | `logic [TAG_W-1:0] tag_out [NUM_LANES]` | payload or static info |
| input | `logic mispredict_flag [NUM_LANES]` | payload or static info |
| input | `logic [XLEN-1:0] mispredict_target_pc [NUM_LANES]` | payload or static info |
| input | `logic exception_flag [NUM_LANES]` | payload or static info |
| input | `logic [EXCP_CAUSE_W-1:0] exception_cause [NUM_LANES]` | payload or static info |
| input | `logic [XLEN-1:0] exception_tval [NUM_LANES]` | payload or static info |
| input | `logic is_mret [NUM_LANES]` | payload or static info |
| input | `logic is_sret [NUM_LANES]` | payload or static info |
| input | `logic [FFLAGS_W-1:0] fpu_fflags [NUM_LANES]` | payload or static info |
| input | `logic global_flush_late` | event/control |
| input | `logic interrupt_pending` | payload or static info |
| input | `logic [TAG_W-1:0] st_br_resolve_tag` | payload or static info |
| input | `logic st_br_resolve_tag_valid` | event/control |
| output | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| output | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| output | `logic [REG_ADDR_W-1:0] commit_rd_idx [ISSUE_WIDTH]` | event/control |
| output | `logic commit_rd_is_fp [ISSUE_WIDTH]` | event/control |
| output | `logic commit_rd_write_enable [ISSUE_WIDTH]` | event/control |
| output | `logic [FFLAGS_W-1:0] commit_fflags [ISSUE_WIDTH]` | event/control |
| output | `logic [COMMIT_COUNT_W-1:0] commit_count` | event/control |
| output | `logic store_wakeup_valid` | event/control |
| output | `logic [TAG_W-1:0] store_wakeup_tag` | event/control |
| output | `logic flush_valid` | event/control |
| output | `logic [TAG_W-1:0] flush_tag` | event/control |
| output | `logic [RECOVERY_KIND_W-1:0] recovery_kind` | payload or static info |
| output | `logic [TAG_W-1:0] head0_tag` | payload or static info |
| output | `logic [TAG_W-1:0] head1_tag` | payload or static info |
| output | `logic [XLEN-1:0] recovery_mispredict_target_pc` | payload or static info |
| output | `logic [EXCP_CAUSE_W-1:0] recovery_exception_cause` | payload or static info |
| output | `logic [XLEN-1:0] recovery_exception_tval` | payload or static info |
| output | `logic st_br_resolve` | payload or static info |
| output | `logic [ROB_DEPTH-1:0] scoreboard_valid_bits` | event/control |
| output | `logic [ROB_DEPTH-1:0] scoreboard_exec_done_bits` | payload or static info |
| output | `logic [TAG_W-1:0] Buffer_tail` | payload or static info |
| output | `logic can_alloc_1` | payload or static info |
| output | `logic can_alloc_2` | payload or static info |
| output | `logic buffer_empty` | payload or static info |

## 3. Events
### `alloc` (in)
- **Fire来源:** `accept[s]`
- **Payload来源:** self_tag, rd_idx, rd_is_fp, rd_write_enable, is_store, is_fence_i, may_flush, is_atomic, st_br_resolve
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `writeback` (in)
- **Fire来源:** `Result_valid[g] ∧ ¬global_flush_late`
- **Payload来源:** tag_out, result_data-independent completion fields
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `store_wakeup` (out)
- **Fire来源:** `safe-prefix scan hit`
- **Payload来源:** store_wakeup_tag
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `commit` (out)
- **Fire来源:** `commit_valid[k] from head decision`
- **Payload来源:** commit_tag, rd_idx, rd_is_fp, rd_write_enable, commit_fflags, commit_count
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (out)
- **Fire来源:** `flush_valid from decision chain`
- **Payload来源:** flush_tag, recovery_kind
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** live interval [head,tail); exec_done; store_wakeup_issued
- **Header:** alloc header per tag; completion event batch
- **Payload:** alloc/writeback batches, recovery fields
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
alloc -> header/tag lifetime; writeback -> terminal bits; head decision -> commit or flush; safe-prefix scan -> store wakeup.

## 6. Control Path
decision chain: head0 validity/done, exception, interrupt boundary, irrevocable/fence/branch/system; head1 dual-FP block and commit count.

| Current state | Condition/event | Next state/action |
|---|---|---|
| live=0 | alloc | live=1; clear terminal bits; write header |
| live=1 | terminal writeback | exec_done=1 |
| live=1 | commit | advance head; live=0 |
| live=1 | flush | tail=head_new; younger entries discarded |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.