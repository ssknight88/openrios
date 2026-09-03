# Module `FP_tag_mapping`

> Source: `work/rtl/rtl_v1/p1/FP_tag_mapping.sv`  
> Modeling class: sequential storage

## 1. Boundary and Responsibility
FP rename map with alloc, commit-clear, flush and three combinational read ports.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic accept [ISSUE_WIDTH]` | event/control |
| input | `logic alloc_rd_write_enable [ISSUE_WIDTH]` | event/control |
| input | `logic alloc_rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] alloc_rd_idx [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] self_tag [ISSUE_WIDTH]` | event/control |
| input | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] commit_rd_idx [ISSUE_WIDTH]` | event/control |
| input | `logic commit_rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic commit_rd_write_enable [ISSUE_WIDTH]` | event/control |
| input | `logic global_flush_late` | event/control |
| input | `logic [REG_ADDR_W-1:0] fp_read_idx [1:3]` | payload or static info |
| output | `logic [TAG_W-1:0] tag [1:3]` | payload or static info |
| output | `logic busy [1:3]` | payload or static info |

## 3. Events
### `alloc` (in)
- **Fire来源:** `accept[s] ∧ alloc_rd_write_enable[s] ∧ alloc_rd_is_fp[s]`
- **Payload来源:** self_tag, alloc_rd_idx[s]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `commit_clear` (in)
- **Fire来源:** `commit_valid[k] ∧ commit_rd_write_enable[k] ∧ commit_rd_is_fp[k] ∧ tag_match[k]`
- **Payload来源:** commit_tag, commit_rd_idx[k]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** IDLE / BUSY per FP register
- **Header:** tag per renamed FP register
- **Payload:** busy plus latest producer tag
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
alloc writes tag/busy; commit clears busy on matching tag; reads expose tag/busy.

## 6. Control Path
per-entry FSM; alloc/commit/flush priority is encoded in RTL.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE | alloc | BUSY / write producer tag |
| BUSY | matching commit clear | IDLE |
| ANY | flush | IDLE |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.