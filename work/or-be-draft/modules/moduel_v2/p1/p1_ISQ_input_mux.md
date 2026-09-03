# Module `p1_ISQ_input_mux`

> Source: `work/rtl/rtl_v1/p1/p1_ISQ_input_mux.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Onehot0 two-way whole-payload selector, instantiated once per ISQ group.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `isq_payload_t slot_payload [ISSUE_WIDTH]` | event/control |
| input | `logic select_payload [ISSUE_WIDTH]` | event/control |
| output | `isq_payload_t ISQ_payload_in` | payload or static info |

## 3. Events
### `isq_payload_select` (out)
- **Fire来源:** `∅`
- **Payload来源:** ISQ_payload_in: isq_payload_t (ISQ_PAYLOAD_W bits)
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** slot_payload[0:1], select_payload[0:1]
- **Payload:** ISQ_payload_in = selected full payload
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
select_payload[0] ? slot_payload[0] : select_payload[1] ? slot_payload[1] : zero.

## 6. Control Path
pure combinational.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.