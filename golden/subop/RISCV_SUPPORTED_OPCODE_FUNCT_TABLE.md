# ORBE Supported RV64 Instruction Encoding Table

This table covers the 194 instructions listed in
`RISCV_SUPPORTED_INSTRUCTION_LIST.md`.

Conventions:

- For ordinary 32-bit instructions, `opcode` is `inst[6:0]`, `funct3` is
  `inst[14:12]`, and `funct7` is `inst[31:25]` when that field is fixed.
- `N/A` means the instruction format does not have a meaningful fixed
  `funct3` or `funct7` field.
- For A-extension instructions, bits `[31:27]` are `funct5`; bits `[26:25]`
  are `aq/rl`. The table keeps the instruction unexpanded; suffix variants
  use `aq/rl = 00/10/01/11` for none/aq/rl/aqrl.
- For F/D-extension instructions, `rm` means the dynamic/static rounding-mode
  field in `funct3`.
- For C-extension instructions, `opcode` means compressed `op[1:0]`; `funct3`
  means compressed bits `[15:13]`. There is no 7-bit `funct7` field.
- Primary encoding source: RISC-V standard encodings, cross-checked against the
  `riscv-opcodes` project used by Spike and the RISC-V manuals.

| # | Instruction | Extension | Format | opcode / op | funct3 | funct7 / high fixed field | Notes |
|---:|---|---|---|---|---|---|---|
| 1 | ADDI | RV64I | I | 0010011 | 000 | N/A | OP-IMM |
| 2 | SLTI | RV64I | I | 0010011 | 010 | N/A | OP-IMM |
| 3 | SLTIU | RV64I | I | 0010011 | 011 | N/A | OP-IMM |
| 4 | XORI | RV64I | I | 0010011 | 100 | N/A | OP-IMM |
| 5 | ORI | RV64I | I | 0010011 | 110 | N/A | OP-IMM |
| 6 | ANDI | RV64I | I | 0010011 | 111 | N/A | OP-IMM |
| 7 | SLLI | RV64I | I-shift | 0010011 | 001 | funct6=000000 | RV64 shamt is 6 bits |
| 8 | SRLI | RV64I | I-shift | 0010011 | 101 | funct6=000000 | RV64 shamt is 6 bits |
| 9 | SRAI | RV64I | I-shift | 0010011 | 101 | funct6=010000 | RV64 shamt is 6 bits |
| 10 | ADD | RV64I | R | 0110011 | 000 | 0000000 | OP |
| 11 | SUB | RV64I | R | 0110011 | 000 | 0100000 | OP |
| 12 | SLL | RV64I | R | 0110011 | 001 | 0000000 | OP |
| 13 | SLT | RV64I | R | 0110011 | 010 | 0000000 | OP |
| 14 | SLTU | RV64I | R | 0110011 | 011 | 0000000 | OP |
| 15 | XOR | RV64I | R | 0110011 | 100 | 0000000 | OP |
| 16 | SRL | RV64I | R | 0110011 | 101 | 0000000 | OP |
| 17 | SRA | RV64I | R | 0110011 | 101 | 0100000 | OP |
| 18 | OR | RV64I | R | 0110011 | 110 | 0000000 | OP |
| 19 | AND | RV64I | R | 0110011 | 111 | 0000000 | OP |
| 20 | ADDIW | RV64I | I | 0011011 | 000 | N/A | OP-IMM-32 |
| 21 | SLLIW | RV64I | I-shift | 0011011 | 001 | 0000000 | OP-IMM-32, shamt is 5 bits |
| 22 | SRLIW | RV64I | I-shift | 0011011 | 101 | 0000000 | OP-IMM-32, shamt is 5 bits |
| 23 | SRAIW | RV64I | I-shift | 0011011 | 101 | 0100000 | OP-IMM-32, shamt is 5 bits |
| 24 | ADDW | RV64I | R | 0111011 | 000 | 0000000 | OP-32 |
| 25 | SUBW | RV64I | R | 0111011 | 000 | 0100000 | OP-32 |
| 26 | SLLW | RV64I | R | 0111011 | 001 | 0000000 | OP-32 |
| 27 | SRLW | RV64I | R | 0111011 | 101 | 0000000 | OP-32 |
| 28 | SRAW | RV64I | R | 0111011 | 101 | 0100000 | OP-32 |
| 29 | LUI | RV64I | U | 0110111 | N/A | N/A | U-type |
| 30 | AUIPC | RV64I | U | 0010111 | N/A | N/A | U-type |
| 31 | JAL | RV64I | J | 1101111 | N/A | N/A | J-type |
| 32 | JALR | RV64I | I | 1100111 | 000 | N/A | I-type branch target |
| 33 | BEQ | RV64I | B | 1100011 | 000 | N/A | B-type |
| 34 | BNE | RV64I | B | 1100011 | 001 | N/A | B-type |
| 35 | BLT | RV64I | B | 1100011 | 100 | N/A | B-type |
| 36 | BGE | RV64I | B | 1100011 | 101 | N/A | B-type |
| 37 | BLTU | RV64I | B | 1100011 | 110 | N/A | B-type |
| 38 | BGEU | RV64I | B | 1100011 | 111 | N/A | B-type |
| 39 | LB | RV64I | I | 0000011 | 000 | N/A | LOAD |
| 40 | LH | RV64I | I | 0000011 | 001 | N/A | LOAD |
| 41 | LW | RV64I | I | 0000011 | 010 | N/A | LOAD |
| 42 | LD | RV64I | I | 0000011 | 011 | N/A | RV64-only LOAD |
| 43 | LBU | RV64I | I | 0000011 | 100 | N/A | LOAD |
| 44 | LHU | RV64I | I | 0000011 | 101 | N/A | LOAD |
| 45 | LWU | RV64I | I | 0000011 | 110 | N/A | RV64-only LOAD |
| 46 | SB | RV64I | S | 0100011 | 000 | N/A | STORE |
| 47 | SH | RV64I | S | 0100011 | 001 | N/A | STORE |
| 48 | SW | RV64I | S | 0100011 | 010 | N/A | STORE |
| 49 | SD | RV64I | S | 0100011 | 011 | N/A | RV64-only STORE |
| 50 | FENCE | RV64I | I | 0001111 | 000 | N/A | MISC-MEM; pred/succ/fm in imm[11:0] |
| 51 | ECALL | RV64I | I-system | 1110011 | 000 | funct12=000000000000 | rd=x0, rs1=x0 |
| 52 | EBREAK | RV64I | I-system | 1110011 | 000 | funct12=000000000001 | rd=x0, rs1=x0 |
| 53 | FENCE.I | Zifencei | I | 0001111 | 001 | funct12=000000000000 | rd=x0, rs1=x0 |
| 54 | CSRRW | Zicsr | I-system | 1110011 | 001 | csr[11:0]=var | CSR address in inst[31:20] |
| 55 | CSRRS | Zicsr | I-system | 1110011 | 010 | csr[11:0]=var | CSR address in inst[31:20] |
| 56 | CSRRC | Zicsr | I-system | 1110011 | 011 | csr[11:0]=var | CSR address in inst[31:20] |
| 57 | CSRRWI | Zicsr | I-system | 1110011 | 101 | csr[11:0]=var | zimm in rs1 field |
| 58 | CSRRSI | Zicsr | I-system | 1110011 | 110 | csr[11:0]=var | zimm in rs1 field |
| 59 | CSRRCI | Zicsr | I-system | 1110011 | 111 | csr[11:0]=var | zimm in rs1 field |
| 60 | MRET | Privileged | I-system | 1110011 | 000 | funct12=001100000010 | Machine return |
| 61 | MUL | RV64M | R | 0110011 | 000 | 0000001 | OP M-extension |
| 62 | MULH | RV64M | R | 0110011 | 001 | 0000001 | OP M-extension |
| 63 | MULHSU | RV64M | R | 0110011 | 010 | 0000001 | OP M-extension |
| 64 | MULHU | RV64M | R | 0110011 | 011 | 0000001 | OP M-extension |
| 65 | DIV | RV64M | R | 0110011 | 100 | 0000001 | OP M-extension |
| 66 | DIVU | RV64M | R | 0110011 | 101 | 0000001 | OP M-extension |
| 67 | REM | RV64M | R | 0110011 | 110 | 0000001 | OP M-extension |
| 68 | REMU | RV64M | R | 0110011 | 111 | 0000001 | OP M-extension |
| 69 | MULW | RV64M | R | 0111011 | 000 | 0000001 | OP-32 M-extension |
| 70 | DIVW | RV64M | R | 0111011 | 100 | 0000001 | OP-32 M-extension |
| 71 | DIVUW | RV64M | R | 0111011 | 101 | 0000001 | OP-32 M-extension |
| 72 | REMW | RV64M | R | 0111011 | 110 | 0000001 | OP-32 M-extension |
| 73 | REMUW | RV64M | R | 0111011 | 111 | 0000001 | OP-32 M-extension |
| 74 | LR.W | RV64A | R-atomic | 0101111 | 010 | funct5=00010, aq/rl=var | rs2=00000; no suffix means aq/rl=00 |
| 75 | SC.W | RV64A | R-atomic | 0101111 | 010 | funct5=00011, aq/rl=var | no suffix means aq/rl=00 |
| 76 | AMOSWAP.W | RV64A | R-atomic | 0101111 | 010 | funct5=00001, aq/rl=var | no suffix means aq/rl=00 |
| 77 | AMOADD.W | RV64A | R-atomic | 0101111 | 010 | funct5=00000, aq/rl=var | no suffix means aq/rl=00 |
| 78 | AMOXOR.W | RV64A | R-atomic | 0101111 | 010 | funct5=00100, aq/rl=var | no suffix means aq/rl=00 |
| 79 | AMOAND.W | RV64A | R-atomic | 0101111 | 010 | funct5=01100, aq/rl=var | no suffix means aq/rl=00 |
| 80 | AMOOR.W | RV64A | R-atomic | 0101111 | 010 | funct5=01000, aq/rl=var | no suffix means aq/rl=00 |
| 81 | AMOMIN.W | RV64A | R-atomic | 0101111 | 010 | funct5=10000, aq/rl=var | no suffix means aq/rl=00 |
| 82 | AMOMAX.W | RV64A | R-atomic | 0101111 | 010 | funct5=10100, aq/rl=var | no suffix means aq/rl=00 |
| 83 | AMOMINU.W | RV64A | R-atomic | 0101111 | 010 | funct5=11000, aq/rl=var | no suffix means aq/rl=00 |
| 84 | AMOMAXU.W | RV64A | R-atomic | 0101111 | 010 | funct5=11100, aq/rl=var | no suffix means aq/rl=00 |
| 85 | LR.D | RV64A | R-atomic | 0101111 | 011 | funct5=00010, aq/rl=var | rs2=00000; no suffix means aq/rl=00 |
| 86 | SC.D | RV64A | R-atomic | 0101111 | 011 | funct5=00011, aq/rl=var | no suffix means aq/rl=00 |
| 87 | AMOSWAP.D | RV64A | R-atomic | 0101111 | 011 | funct5=00001, aq/rl=var | no suffix means aq/rl=00 |
| 88 | AMOADD.D | RV64A | R-atomic | 0101111 | 011 | funct5=00000, aq/rl=var | no suffix means aq/rl=00 |
| 89 | AMOXOR.D | RV64A | R-atomic | 0101111 | 011 | funct5=00100, aq/rl=var | no suffix means aq/rl=00 |
| 90 | AMOAND.D | RV64A | R-atomic | 0101111 | 011 | funct5=01100, aq/rl=var | no suffix means aq/rl=00 |
| 91 | AMOOR.D | RV64A | R-atomic | 0101111 | 011 | funct5=01000, aq/rl=var | no suffix means aq/rl=00 |
| 92 | AMOMIN.D | RV64A | R-atomic | 0101111 | 011 | funct5=10000, aq/rl=var | no suffix means aq/rl=00 |
| 93 | AMOMAX.D | RV64A | R-atomic | 0101111 | 011 | funct5=10100, aq/rl=var | no suffix means aq/rl=00 |
| 94 | AMOMINU.D | RV64A | R-atomic | 0101111 | 011 | funct5=11000, aq/rl=var | no suffix means aq/rl=00 |
| 95 | AMOMAXU.D | RV64A | R-atomic | 0101111 | 011 | funct5=11100, aq/rl=var | no suffix means aq/rl=00 |
| 96 | FLW | RV64F | I | 0000111 | 010 | N/A | LOAD-FP |
| 97 | FSW | RV64F | S | 0100111 | 010 | N/A | STORE-FP |
| 98 | FMADD.S | RV64F | R4 | 1000011 | rm | fmt=00, rs3=var | Fused multiply-add |
| 99 | FMSUB.S | RV64F | R4 | 1000111 | rm | fmt=00, rs3=var | Fused multiply-sub |
| 100 | FNMSUB.S | RV64F | R4 | 1001011 | rm | fmt=00, rs3=var | Negated fused multiply-sub |
| 101 | FNMADD.S | RV64F | R4 | 1001111 | rm | fmt=00, rs3=var | Negated fused multiply-add |
| 102 | FADD.S | RV64F | R | 1010011 | rm | 0000000 | OP-FP, fmt=S |
| 103 | FSUB.S | RV64F | R | 1010011 | rm | 0000100 | OP-FP, fmt=S |
| 104 | FMUL.S | RV64F | R | 1010011 | rm | 0001000 | OP-FP, fmt=S |
| 105 | FDIV.S | RV64F | R | 1010011 | rm | 0001100 | OP-FP, fmt=S |
| 106 | FSQRT.S | RV64F | R | 1010011 | rm | 0101100 | rs2=00000 |
| 107 | FSGNJ.S | RV64F | R | 1010011 | 000 | 0010000 | OP-FP |
| 108 | FSGNJN.S | RV64F | R | 1010011 | 001 | 0010000 | OP-FP |
| 109 | FSGNJX.S | RV64F | R | 1010011 | 010 | 0010000 | OP-FP |
| 110 | FMIN.S | RV64F | R | 1010011 | 000 | 0010100 | OP-FP |
| 111 | FMAX.S | RV64F | R | 1010011 | 001 | 0010100 | OP-FP |
| 112 | FCVT.W.S | RV64F | R | 1010011 | rm | 1100000 | rs2=00000 |
| 113 | FCVT.WU.S | RV64F | R | 1010011 | rm | 1100000 | rs2=00001 |
| 114 | FCVT.L.S | RV64F | R | 1010011 | rm | 1100000 | rs2=00010 |
| 115 | FCVT.LU.S | RV64F | R | 1010011 | rm | 1100000 | rs2=00011 |
| 116 | FCVT.S.W | RV64F | R | 1010011 | rm | 1101000 | rs2=00000 |
| 117 | FCVT.S.WU | RV64F | R | 1010011 | rm | 1101000 | rs2=00001 |
| 118 | FCVT.S.L | RV64F | R | 1010011 | rm | 1101000 | rs2=00010 |
| 119 | FCVT.S.LU | RV64F | R | 1010011 | rm | 1101000 | rs2=00011 |
| 120 | FMV.X.W | RV64F | R | 1010011 | 000 | 1110000 | rs2=00000 |
| 121 | FMV.W.X | RV64F | R | 1010011 | 000 | 1111000 | rs2=00000 |
| 122 | FEQ.S | RV64F | R | 1010011 | 010 | 1010000 | OP-FP compare |
| 123 | FLT.S | RV64F | R | 1010011 | 001 | 1010000 | OP-FP compare |
| 124 | FLE.S | RV64F | R | 1010011 | 000 | 1010000 | OP-FP compare |
| 125 | FCLASS.S | RV64F | R | 1010011 | 001 | 1110000 | rs2=00000 |
| 126 | FLD | RV64D | I | 0000111 | 011 | N/A | LOAD-FP |
| 127 | FSD | RV64D | S | 0100111 | 011 | N/A | STORE-FP |
| 128 | FMADD.D | RV64D | R4 | 1000011 | rm | fmt=01, rs3=var | Fused multiply-add |
| 129 | FMSUB.D | RV64D | R4 | 1000111 | rm | fmt=01, rs3=var | Fused multiply-sub |
| 130 | FNMSUB.D | RV64D | R4 | 1001011 | rm | fmt=01, rs3=var | Negated fused multiply-sub |
| 131 | FNMADD.D | RV64D | R4 | 1001111 | rm | fmt=01, rs3=var | Negated fused multiply-add |
| 132 | FADD.D | RV64D | R | 1010011 | rm | 0000001 | OP-FP, fmt=D |
| 133 | FSUB.D | RV64D | R | 1010011 | rm | 0000101 | OP-FP, fmt=D |
| 134 | FMUL.D | RV64D | R | 1010011 | rm | 0001001 | OP-FP, fmt=D |
| 135 | FDIV.D | RV64D | R | 1010011 | rm | 0001101 | OP-FP, fmt=D |
| 136 | FSQRT.D | RV64D | R | 1010011 | rm | 0101101 | rs2=00000 |
| 137 | FSGNJ.D | RV64D | R | 1010011 | 000 | 0010001 | OP-FP |
| 138 | FSGNJN.D | RV64D | R | 1010011 | 001 | 0010001 | OP-FP |
| 139 | FSGNJX.D | RV64D | R | 1010011 | 010 | 0010001 | OP-FP |
| 140 | FMIN.D | RV64D | R | 1010011 | 000 | 0010101 | OP-FP |
| 141 | FMAX.D | RV64D | R | 1010011 | 001 | 0010101 | OP-FP |
| 142 | FCVT.W.D | RV64D | R | 1010011 | rm | 1100001 | rs2=00000 |
| 143 | FCVT.WU.D | RV64D | R | 1010011 | rm | 1100001 | rs2=00001 |
| 144 | FCVT.L.D | RV64D | R | 1010011 | rm | 1100001 | rs2=00010 |
| 145 | FCVT.LU.D | RV64D | R | 1010011 | rm | 1100001 | rs2=00011 |
| 146 | FCVT.D.W | RV64D | R | 1010011 | rm | 1101001 | rs2=00000 |
| 147 | FCVT.D.WU | RV64D | R | 1010011 | rm | 1101001 | rs2=00001 |
| 148 | FCVT.D.L | RV64D | R | 1010011 | rm | 1101001 | rs2=00010 |
| 149 | FCVT.D.LU | RV64D | R | 1010011 | rm | 1101001 | rs2=00011 |
| 150 | FCVT.S.D | RV64D | R | 1010011 | rm | 0100000 | rs2=00001 |
| 151 | FCVT.D.S | RV64D | R | 1010011 | rm | 0100001 | rs2=00000 |
| 152 | FMV.X.D | RV64D | R | 1010011 | 000 | 1110001 | rs2=00000 |
| 153 | FMV.D.X | RV64D | R | 1010011 | 000 | 1111001 | rs2=00000 |
| 154 | FEQ.D | RV64D | R | 1010011 | 010 | 1010001 | OP-FP compare |
| 155 | FLT.D | RV64D | R | 1010011 | 001 | 1010001 | OP-FP compare |
| 156 | FLE.D | RV64D | R | 1010011 | 000 | 1010001 | OP-FP compare |
| 157 | FCLASS.D | RV64D | R | 1010011 | 001 | 1110001 | rs2=00000 |
| 158 | C.ADDI4SPN | RV64C | CIW | 00 | 000 | N/A | nzuimm != 0 |
| 159 | C.NOP | RV64C | CI | 01 | 000 | N/A | rd=x0, imm=0; alias of C.ADDI |
| 160 | C.ADDI | RV64C | CI | 01 | 000 | N/A | rd != x0 for non-NOP form |
| 161 | C.ADDIW | RV64C | CI | 01 | 001 | N/A | RV64C |
| 162 | C.LI | RV64C | CI | 01 | 010 | N/A | rd != x0 |
| 163 | C.ADDI16SP | RV64C | CI | 01 | 011 | N/A | rd=x2, nzimm != 0 |
| 164 | C.LUI | RV64C | CI | 01 | 011 | N/A | rd != x0/x2, nzimm != 0 |
| 165 | C.FLD | RV64C/RV64D | CL | 00 | 001 | N/A | compressed double-precision FP load |
| 166 | C.LW | RV64C | CL | 00 | 010 | N/A | rd'/rs1' compressed regs |
| 167 | C.LD | RV64C | CL | 00 | 011 | N/A | RV64C doubleword load |
| 168 | C.FSD | RV64C/RV64D | CS | 00 | 101 | N/A | compressed double-precision FP store |
| 169 | C.SW | RV64C | CS | 00 | 110 | N/A | rs1'/rs2' compressed regs |
| 170 | C.SD | RV64C | CS | 00 | 111 | N/A | RV64C doubleword store |
| 171 | C.FLDSP | RV64C/RV64D | CI | 10 | 001 | N/A | compressed double-precision FP load, base x2/sp |
| 172 | C.LWSP | RV64C | CI | 10 | 010 | N/A | base x2/sp |
| 173 | C.LDSP | RV64C | CI | 10 | 011 | N/A | base x2/sp |
| 174 | C.FSDSP | RV64C/RV64D | CSS | 10 | 101 | N/A | compressed double-precision FP store, base x2/sp |
| 175 | C.SWSP | RV64C | CSS | 10 | 110 | N/A | base x2/sp |
| 176 | C.SDSP | RV64C | CSS | 10 | 111 | N/A | base x2/sp |
| 177 | C.SLLI | RV64C | CI | 10 | 000 | N/A | shamt encoded in compressed immediate |
| 178 | C.SRLI | RV64C | CB | 01 | 100 | [11:10]=00 | bit[12] is shamt high bit |
| 179 | C.SRAI | RV64C | CB | 01 | 100 | [11:10]=01 | bit[12] is shamt high bit |
| 180 | C.ANDI | RV64C | CB | 01 | 100 | [11:10]=10 | compressed immediate |
| 181 | C.SUB | RV64C | CA | 01 | 100 | [12]=0,[11:10]=11,[6:5]=00 | rd'/rs2' compressed regs |
| 182 | C.XOR | RV64C | CA | 01 | 100 | [12]=0,[11:10]=11,[6:5]=01 | rd'/rs2' compressed regs |
| 183 | C.OR | RV64C | CA | 01 | 100 | [12]=0,[11:10]=11,[6:5]=10 | rd'/rs2' compressed regs |
| 184 | C.AND | RV64C | CA | 01 | 100 | [12]=0,[11:10]=11,[6:5]=11 | rd'/rs2' compressed regs |
| 185 | C.SUBW | RV64C | CA | 01 | 100 | [12]=1,[11:10]=11,[6:5]=00 | RV64C |
| 186 | C.ADDW | RV64C | CA | 01 | 100 | [12]=1,[11:10]=11,[6:5]=01 | RV64C |
| 187 | C.MV | RV64C | CR | 10 | 100 | [12]=0 | rs2 != x0 |
| 188 | C.ADD | RV64C | CR | 10 | 100 | [12]=1 | rs2 != x0 |
| 189 | C.J | RV64C | CJ | 01 | 101 | N/A | jal x0, offset |
| 190 | C.JR | RV64C | CR | 10 | 100 | [12]=0 | rs2=x0, rs1 != x0 |
| 191 | C.JALR | RV64C | CR | 10 | 100 | [12]=1 | rs2=x0, rs1 != x0 |
| 192 | C.BEQZ | RV64C | CB | 01 | 110 | N/A | rs1' == x0 |
| 193 | C.BNEZ | RV64C | CB | 01 | 111 | N/A | rs1' != x0 |
| 194 | C.EBREAK | RV64C | CR | 10 | 100 | [12]=1 | rs1=x0, rs2=x0 |
