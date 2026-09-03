# Module `FP_read_address_mux`

> Source: `work/rtl/rtl_v1/p1/FP_read_address_mux.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Narrows six candidate FP source addresses to three read ports using one slot-select bit.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic [REG_ADDR_W-1:0] rs1_idx [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs2_idx [ISSUE_WIDTH]` | event/control |
| input | `logic [REG_ADDR_W-1:0] rs3_idx [ISSUE_WIDTH]` | event/control |
| input | `logic is_fp_instruction` | payload or static info |
| output | `logic [REG_ADDR_W-1:0] fp_read_idx [1:3]` | payload or static info |

## 3. Events
### `fp_read_address` (out)
- **Fire来源:** `∅`
- **Payload来源:** fp_read_idx[1:3], REG_ADDR_W each
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** slot rs1/2/3 indices, is_fp_instruction
- **Payload:** fp_read_idx[1:3]
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
per source k: fp_read_idx[k] = is_fp_instruction ? slot0.rsX_idx : slot1.rsX_idx.

## 6. Control Path
pure combinational.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.