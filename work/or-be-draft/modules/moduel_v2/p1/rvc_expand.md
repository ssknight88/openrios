# Module `rvc_expand`

> Source: `work/rtl/rtl_v1/p1/rvc_expand.sv`  
> Modeling class: combinational

## 1. Boundary and Responsibility
Expands compressed instruction to canonical 32-bit form and reports illegal compressed encodings.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic [31:0] ib_inst_bits [ISSUE_WIDTH]` | event/control |
| input | `logic ib_is_compressed [ISSUE_WIDTH]` | event/control |
| output | `logic [31:0] inst32 [ISSUE_WIDTH]` | event/control |
| output | `logic rvc_illegal [ISSUE_WIDTH]` | event/control |

## 3. Events
### `rvc_result` (out)
- **Fire来源:** `∅`
- **Payload来源:** inst32[31:0] and ill_rvc, one result per ISSUE_WIDTH lane
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** none
- **Header:** ib_inst_bits, ib_is_compressed
- **Payload:** inst32, ill_rvc
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
per lane raw 16/32 encoding -> riscv_rvc_pkg::rvc_decompress_rv64 -> inst32/ill_rvc.

## 6. Control Path
pure combinational.

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.