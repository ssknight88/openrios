# ORBE Supported RISC-V Instruction List

This document is the target instruction coverage list for ORBE backend sub-op planning.

Target profile:

```text
RV64IMAFD C + Zicsr + Zifencei + ORBE required M-mode privileged subset
```

Important scope decisions:

- `D` extension is supported for the standard non-compressed RV64D floating-point instruction forms listed below. Compressed D load/store forms are included when C and D are both enabled, using the standard `rv_c_d` compressed encodings.
- `C` is supported as compressed decode input. In the current proposal, listed compressed instructions have distinct decoded `SUBOP_C_*` IDs; if FE later expands them before the BE boundary, those IDs can become FE-only aliases.
- `A` extension instructions are listed as architectural targets, even if full verification requires LSU/cache-agent support for reservation, atomicity, ordering, and interference injection.
- `Zicsr`, `Zifencei`, `ECALL`, `EBREAK`, and `MRET` are included because ORBE needs CSR/trap/fence behavior even though they are not all part of modern base `I` naming.
- Pseudo-instructions are not listed separately unless they are standard compressed encodings, such as `C.NOP` and `C.EBREAK`.

---

## RV64I Base Integer Instructions

### Integer Register-Immediate

- `ADDI`
- `SLTI`
- `SLTIU`
- `XORI`
- `ORI`
- `ANDI`
- `SLLI`
- `SRLI`
- `SRAI`

### Integer Register-Register

- `ADD`
- `SUB`
- `SLL`
- `SLT`
- `SLTU`
- `XOR`
- `SRL`
- `SRA`
- `OR`
- `AND`

### RV64 Word Integer Operations

- `ADDIW`
- `SLLIW`
- `SRLIW`
- `SRAIW`
- `ADDW`
- `SUBW`
- `SLLW`
- `SRLW`
- `SRAW`

### Control Transfer

- `LUI`
- `AUIPC`
- `JAL`
- `JALR`
- `BEQ`
- `BNE`
- `BLT`
- `BGE`
- `BLTU`
- `BGEU`

### Integer Loads

- `LB`
- `LH`
- `LW`
- `LD`
- `LBU`
- `LHU`
- `LWU`

### Integer Stores

- `SB`
- `SH`
- `SW`
- `SD`

### Memory Ordering and Environment

- `FENCE`
- `ECALL`
- `EBREAK`

---

## Zifencei

- `FENCE.I`

---

## Zicsr

- `CSRRW`
- `CSRRS`
- `CSRRC`
- `CSRRWI`
- `CSRRSI`
- `CSRRCI`

---

## ORBE Required Privileged Subset

- `MRET`

Out of scope unless explicitly added later:

- `SRET`
- `WFI`
- `SFENCE.VMA`
- Hypervisor fence instructions, including `HFENCE.*`

---

## RV64M Integer Multiply/Divide Instructions

### XLEN Operations

- `MUL`
- `MULH`
- `MULHSU`
- `MULHU`
- `DIV`
- `DIVU`
- `REM`
- `REMU`

### RV64 Word Operations

- `MULW`
- `DIVW`
- `DIVUW`
- `REMW`
- `REMUW`

---

## RV64A Atomic Instructions

Ordering suffixes apply to the A-extension operations where encoded:

- no suffix
- `.aq`
- `.rl`
- `.aqrl`

### Word Atomics

- `LR.W`
- `SC.W`
- `AMOSWAP.W`
- `AMOADD.W`
- `AMOXOR.W`
- `AMOAND.W`
- `AMOOR.W`
- `AMOMIN.W`
- `AMOMAX.W`
- `AMOMINU.W`
- `AMOMAXU.W`

### Doubleword Atomics

- `LR.D`
- `SC.D`
- `AMOSWAP.D`
- `AMOADD.D`
- `AMOXOR.D`
- `AMOAND.D`
- `AMOOR.D`
- `AMOMIN.D`
- `AMOMAX.D`
- `AMOMINU.D`
- `AMOMAXU.D`

Verification note: full A-extension validation requires memory-system support for LR/SC reservation, SC failure, atomic read-modify-write indivisibility, `.aq`/`.rl` ordering, and interference scenarios.

---

## RV64F/RV64D Floating-Point Instructions

### Floating-Point Loads and Stores

- `FLW`
- `FSW`
- `FLD`
- `FSD`

### Fused Multiply-Add

- `FMADD.S`
- `FMSUB.S`
- `FNMSUB.S`
- `FNMADD.S`
- `FMADD.D`
- `FMSUB.D`
- `FNMSUB.D`
- `FNMADD.D`

### Arithmetic

- `FADD.S`
- `FSUB.S`
- `FMUL.S`
- `FDIV.S`
- `FSQRT.S`
- `FADD.D`
- `FSUB.D`
- `FMUL.D`
- `FDIV.D`
- `FSQRT.D`

### Sign Injection

- `FSGNJ.S`
- `FSGNJN.S`
- `FSGNJX.S`
- `FSGNJ.D`
- `FSGNJN.D`
- `FSGNJX.D`

### Min/Max

- `FMIN.S`
- `FMAX.S`
- `FMIN.D`
- `FMAX.D`

### Float-to-Integer Conversion

- `FCVT.W.S`
- `FCVT.WU.S`
- `FCVT.L.S`
- `FCVT.LU.S`
- `FCVT.W.D`
- `FCVT.WU.D`
- `FCVT.L.D`
- `FCVT.LU.D`

### Integer-to-Float Conversion

- `FCVT.S.W`
- `FCVT.S.WU`
- `FCVT.S.L`
- `FCVT.S.LU`
- `FCVT.D.W`
- `FCVT.D.WU`
- `FCVT.D.L`
- `FCVT.D.LU`

### Float-to-Float Conversion

- `FCVT.S.D`
- `FCVT.D.S`

### Move Between Integer and Float Register Files

- `FMV.X.W`
- `FMV.W.X`
- `FMV.X.D`
- `FMV.D.X`

### Compare and Classify

- `FEQ.S`
- `FLT.S`
- `FLE.S`
- `FCLASS.S`
- `FEQ.D`
- `FLT.D`
- `FLE.D`
- `FCLASS.D`

---

## RV64C Compressed Instructions

### Stack-Pointer and Immediate Forms

- `C.ADDI4SPN`
- `C.NOP`
- `C.ADDI`
- `C.ADDIW`
- `C.LI`
- `C.ADDI16SP`
- `C.LUI`

### Compressed Integer Loads and Stores

- `C.LW`
- `C.LD`
- `C.SW`
- `C.SD`
- `C.LWSP`
- `C.LDSP`
- `C.SWSP`
- `C.SDSP`

### Compressed Double-Precision Floating-Point Loads and Stores

- `C.FLD`
- `C.FSD`
- `C.FLDSP`
- `C.FSDSP`

### Compressed ALU Operations

- `C.SLLI`
- `C.SRLI`
- `C.SRAI`
- `C.ANDI`
- `C.SUB`
- `C.XOR`
- `C.OR`
- `C.AND`
- `C.SUBW`
- `C.ADDW`
- `C.MV`
- `C.ADD`

### Compressed Control Transfer

- `C.J`
- `C.JR`
- `C.JALR`
- `C.BEQZ`
- `C.BNEZ`

### Compressed Environment

- `C.EBREAK`

RV64C exclusions under this ORBE profile:

- `C.JAL` is RV32C-only, not RV64C.
- RV64C does not provide compressed single-precision `C.FLW`/`C.FSW`; those encodings are used by integer doubleword load/store forms in RV64C.

---

## Backend Mapping Notes

This list is the ISA coverage target for the current one-instruction-one-subop proposal. Each listed instruction item maps to one decoded `SUBOP_*` ID in `exe_subop_pkg.sv`, using the opcode/funct-derived encoding fields from `RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md` unless company-internal operator parameters replace them.

- `C.*` instructions are currently listed as distinct decoded instruction IDs. If FE later expands compressed instructions before the BE boundary, the corresponding `SUBOP_C_*` entries can be removed or treated as FE-only aliases.
- `D` extension entries include standard non-compressed RV64D floating-point forms and the compressed D load/store forms `C.FLD`, `C.FLDSP`, `C.FSD`, and `C.FSDSP` when C and D are both enabled.
- A-extension `.aq/.rl/.aqrl` suffixes are currently kept as ordering fields, not expanded into separate `SUBOP_*` IDs. If company parameters expand them, the table and width must be updated together.
- `FENCE.I` may require frontend/cache cooperation; it still has a visible decoded instruction ID.
- CSR instructions use `Zicsr` decoded IDs plus commit-time architectural CSR update rules.
- `ECALL`, `EBREAK`, illegal instruction, and `MRET` are control/trap semantics, not ordinary ALU arithmetic, but still have concrete decoded IDs where listed.
