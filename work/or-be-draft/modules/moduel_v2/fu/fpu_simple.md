# Module `fpu_simple`

> Source: `work/rtl/rtl_v1/fu/fpu_simple.sv`  
> Modeling class: sequential FU

## 1. Boundary and Responsibility
G2 single-member FP execute unit. Supports arithmetic, conversion, compare, FMA, divide and sqrt with registered one-cycle completion.

## 2. Interface
| Direction | RTL declaration | Role |
|---|---|---|
| input | `logic clk` | clock/reset |
| input | `logic rst_n` | clock/reset |
| input | `logic global_flush_late` | event/control |
| input | `logic issue_valid` | event/control |
| input | `logic [XLEN-1:0] rs1_data` | payload or static info |
| input | `logic [XLEN-1:0] rs2_data` | payload or static info |
| input | `logic [XLEN-1:0] rs3_data` | payload or static info |
| input | `logic [TAG_W-1:0] self_tag` | payload or static info |
| input | `logic [EXE_SUBOP_W-1:0] exe_subop` | payload or static info |
| input | `logic [FULL_DECODE_W-1:0] full_decode` | payload or static info |
| output | `logic FU_ready` | event/control |
| output | `logic Result_valid` | event/control |
| output | `logic [TAG_W-1:0] tag_out` | payload or static info |
| output | `logic [XLEN-1:0] result_data` | payload or static info |
| output | `logic mispredict_flag` | payload or static info |
| output | `logic [XLEN-1:0] mispredict_target_pc` | payload or static info |
| output | `logic exception_flag` | payload or static info |
| output | `logic [EXCP_CAUSE_W-1:0] exception_cause` | payload or static info |
| output | `logic [XLEN-1:0] exception_tval` | payload or static info |
| output | `logic is_mret` | payload or static info |
| output | `logic is_sret` | payload or static info |
| output | `logic [FFLAGS_W-1:0] fpu_fflags` | payload or static info |
| output | `logic bypass_valid` | event/control |
| output | `logic [TAG_W-1:0] bypass_tag` | event/control |
| output | `logic [XLEN-1:0] bypass_data` | event/control |

## 3. Events
### `issue` (in)
- **Fire来源:** `issue_valid ∧ FU_ready ∧ ¬global_flush_late`
- **Payload来源:** rs1_data, rs2_data, rs3_data, self_tag, exe_subop, full_decode
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `completion` (out)
- **Fire来源:** `Result_valid ∧ ¬global_flush_late`
- **Payload来源:** tag_out, result_data, exception_*, fpu_fflags
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `bypass_publish` (out)
- **Fire来源:** `bypass_valid`
- **Payload来源:** bypass_tag, bypass_data
- **约束:** lane-2 broadcast
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.
### `flush` (in)
- **Fire来源:** `global_flush_late`
- **Payload来源:** ∅
- **约束:** voids in-flight operation
- **Payload定义:** schema follows the listed RTL fields; width/slot cardinality is the declaration shown in Interface.

## 4. Data Structure
- **State:** IDLE / EXEC / COMPLETE
- **Header:** self_tag, exe_subop, full_decode.rm
- **Payload:** completion_common; fpu_fflags
- State is stored only where the RTL has clocked assignments; combinational aliases are views and are not additional state.

## 5. Data Path
three operands -> unpack/classify/operation/round -> completion and bypass lane 2.

## 6. Control Path
issue capture; completion and bypass publish; flush clears busy and suppresses completion.

| Current state | Condition/event | Next state/action |
|---|---|---|
| IDLE/EXEC | issue | execute or register payload |
| EXEC/HOLD | completion acknowledgement | IDLE |
| ANY | flush | IDLE / clear in-flight state |

## 7. Fire Expansion and Traceability
- Every non-leaf predicate in a Fire expression is the RTL predicate named in the corresponding event section.
- Leaf signals are limited to declared Interface ports or the Data Structure fields above. A missing declaration is recorded as ``⟨需确认⟩`` rather than invented.
- Payload schemas are defined at this module output when the module produces the event; consumers reference the event name and fields.