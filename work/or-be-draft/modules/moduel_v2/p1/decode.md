# Module `decode`

> Source: `work/rtl/rtl_v1/p1/decode.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Post-IB decoder: slices instruction fields, classifies subop, generates decode metadata; no storage and no fire.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic [31:0] ib_inst32 [ISSUE_WIDTH]` | event/control |
| input | `logic [15:0] ib_inst16 [ISSUE_WIDTH]` | event/control |
| input | `logic ib_is_compressed [ISSUE_WIDTH]` | event/control |
| input | `logic ib_rvc_illegal [ISSUE_WIDTH]` | event/control |
| input | `logic ib_fetch_excp_vld [ISSUE_WIDTH]` | event/control |
| output | `decoded_info_t dec_info [ISSUE_WIDTH]` | event/control |

## 3. Events
### `decode_result` (out)
- **Fire来源:** `∅`
- **Payload来源:** dec_info[s]: decoded_info_t, one result per ISSUE_WIDTH lane
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** ib_inst32/ib_inst16, compression and fetch-exception flags
- **Payload:** decoded_info_t per slot
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
raw instruction -> field slices -> subop/class/decoded_info_t.

## 6. Control Path
pure combinational; no FSM.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.