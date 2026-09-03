# Module `INT_ARF`

> Source: `work/rtl/rtl_v1/p1/INT_ARF.sv`  
> Modeling class: sequential storage

## 1. Boundary and Responsibility
Architectural integer register file with two commit writes and four combinational reads.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic commit_valid [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rd_idx [ISSUE_WIDTH]` | event/control |
| input | `logic rd_is_fp [ISSUE_WIDTH]` | event/control |
| input | `logic rd_write_enable [ISSUE_WIDTH]` | event/control |
| input | `logic [XLEN-1:0] commit_data [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs_idx [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]` | event/control |
| output | `logic [XLEN-1:0] ARF [ISSUE_WIDTH][1:INT_SRC_PER_SLOT]` | event/control |

## 3. Events
### `commit` (in)
- **Fire来源:** `commit_valid[k] ∧ rd_write_enable[k] ∧ ¬rd_is_fp[k] ∧ rd_idx[k] != 0`
- **Payload来源:** rd_idx, commit_data
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `read` (out)
- **Fire来源:** `∅`
- **Payload来源:** rs_idx[s][1:2] -> ARF data
- **约束:** static read
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** architectural register array (x0 hardwired)
- **Header:** commit write address/data
- **Payload:** ARF[x0..x31] 64-bit payload entries
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
commit -> write enabled nonzero register; rs_idx -> read with x0 forced zero.

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