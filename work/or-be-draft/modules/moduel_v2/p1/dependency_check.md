# Module `dependency_check`

> Source: `work/rtl/rtl_v1/p1/dependency_check.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Single P1 tag comparison and operand resolution point. First-hit chain gives ARF/commit/bypass selection.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic [ISSUE_WIDTH-1:0] inst_valid` | event/control |
| input | `logic [REG_ADDR_W-1:0] rd_idx [ISSUE_WIDTH]` | event/control |
| input | `logic rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic use_rd [ISSUE_WIDTH]` | event/control |
| input | `logic is_serial [ISSUE_WIDTH]` | event/control |
| input | `logic is_fp_instruction [ISSUE_WIDTH]` | event/control |
| input | `logic use_rs1 [ISSUE_WIDTH]` | event/control |
| input | `logic use_rs2 [ISSUE_WIDTH]` | event/control |
| input | `logic use_rs3 [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs1_idx [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs2_idx [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs3_idx [ISSUE_WIDTH]` | event/control |
| input | `logic rs1_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic rs2_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic rs3_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] Buffer_tail` | payload or static info |
| input | `logic [TAG_W-1:0] INT_tag_mapping_tag [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]` | event/control |
| input | `logic INT_tag_mapping_busy [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]` | event/control |
| input | `logic [TAG_W-1:0] FP_tag_mapping_tag [1:FP_READ_PORTS]` | payload or static info |
| input | `logic FP_tag_mapping_busy [1:FP_READ_PORTS]` | payload or static info |
| input | `logic [ROB_DEPTH-1:0] scoreboard_valid_bits` | event/control |
| input | `logic [ROB_DEPTH-1:0] scoreboard_exec_done_bits` | payload or static info |
| input | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] commit_tag [ISSUE_WIDTH]` | event/control |
| input | `logic bypass_valid [NUM_LANES]` | event/control |
| input | `logic [TAG_W-1:0] bypass_tag [NUM_LANES]` | event/control |
| output | `logic [TAG_W-1:0] self_tag [ISSUE_WIDTH]` | event/control |
| output | `logic rd_write_enable [ISSUE_WIDTH]` | event/control |
| output | `logic slot0_present` | payload or static info |
| output | `logic slot1_present` | payload or static info |
| output | `logic serial0` | payload or static info |
| output | `logic serial_inst` | payload or static info |
| output | `logic fp0` | payload or static info |
| output | `logic fp1` | payload or static info |
| output | `logic slot_missed_wakeup [ISSUE_WIDTH]` | event/control |
| output | `logic rsX_ready [ISSUE_WIDTH][1:FP_READ_PORTS]` | event/control |
| output | `logic [TAG_W-1:0] rsX_wait_tag [ISSUE_WIDTH][1:FP_READ_PORTS]` | event/control |
| output | `logic [RS_DATA_SEL_W-1:0] rs_data_sel_t [ISSUE_WIDTH][1:FP_READ_PORTS]` | event/control |

## 3. Events
### `operand_resolution` (out)
- **Fire来源:** `∅`
- **Payload来源:** rsX_ready[slot][source], rsX_wait_tag[slot][source], rs_data_sel_t[slot][source]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** IB head fields, tag-map reads, commit/bypass broadcasts
- **Payload:** rsX_ready, rsX_wait_tag, rs_data_sel_t, slot projections
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
presence/class projections -> RAW overlay -> tag queries -> first-hit source selection.

## 6. Control Path
pure combinational; no FSM.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.