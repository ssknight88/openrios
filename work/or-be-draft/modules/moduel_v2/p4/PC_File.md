# Module `PC_File`

> Source: `work/rtl/rtl_v1/p4/PC_File.sv`  
> Modeling class: sequential storage

## 1. Boundary and Responsibility
Sixteen-entry instruction-PC store. Accept writes PCs; flush/head tags read recovery and trace PCs.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic accept [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] self_tag [ISSUE_WIDTH]` | event/control |
| input | `logic [XLEN-1:0] pc [ISSUE_WIDTH]` | event/control |
| input | `logic [TAG_W-1:0] flush_tag` | event/control |
| input | `logic [TAG_W-1:0] head0_tag` | payload or static info |
| input | `logic [TAG_W-1:0] head1_tag` | payload or static info |
| output | `logic [XLEN-1:0] inst_pc` | payload or static info |
| output | `logic [XLEN-1:0] trace_pc [ISSUE_WIDTH]` | event/control |

## 3. Events
### `write` (in)
- **Fire来源:** `accept[s]`
- **Payload来源:** self_tag[s], pc[s]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `read` (out)
- **Fire来源:** `∅`
- **Payload来源:** flush_tag/head tags -> inst_pc/trace_pc
- **约束:** static read
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none (payload-only entries)
- **Header:** self_tag write addresses
- **Payload:** entry_inst_pc[tag] 64-bit
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
accept[s] -> entry_inst_pc[self_tag[s]]; read tags -> inst_pc/trace_pc.

## 6. Control Path
no FSM.

| Current state | Condition/event | Next state/action |
|---|---|---|
| storage | write event | overwrite addressed payload |
| storage | read | combinational payload view |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.