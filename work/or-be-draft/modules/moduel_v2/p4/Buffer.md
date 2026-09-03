# Module `Buffer`

> Source: `work/rtl/rtl_v1/p4/Buffer.sv`  
> Modeling class: sequential storage

## 1. Boundary and Responsibility
Sixteen-entry result buffer. Four writeback ports overwrite by tag; two head reads feed commit.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic Result_valid [NUM_LANES]` | event/control |
| input | `logic [TAG_W-1:0] tag_out [NUM_LANES]` | payload or static info |
| input | `logic [XLEN-1:0] result_data [NUM_LANES]` | payload or static info |
| input | `logic [TAG_W-1:0] head0_tag` | payload or static info |
| input | `logic [TAG_W-1:0] head1_tag` | payload or static info |
| output | `logic [XLEN-1:0] commit_data [ISSUE_WIDTH]` | event/control |

## 3. Events
### `writeback` (in)
- **Fire来源:** `Result_valid[g]`
- **Payload来源:** tag_out[g], result_data[g]
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `read` (out)
- **Fire来源:** `∅`
- **Payload来源:** head0_tag/head1_tag -> commit_data[0:1]
- **约束:** static read
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none (payload-only entries)
- **Header:** tag_out write addresses
- **Payload:** entry_result_data[tag] 64-bit
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
writeback lane -> entry_result_data[tag]; head tags -> commit_data[0:1].

## 6. Control Path
no FSM; writes occur on writeback event.

| Current state | Condition/event | Next state/action |
|---|---|---|
| storage | write event | overwrite addressed payload |
| storage | read | combinational payload view |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.