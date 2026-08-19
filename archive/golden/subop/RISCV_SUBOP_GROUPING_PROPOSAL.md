# ORBE Subop 一指令一编码方案

来源指令清单：`golden/subop/RISCV_SUPPORTED_INSTRUCTION_LIST.md`。

opcode/funct 字段表：`golden/subop/RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md`。

本文记录当前确认的新方向：

```text
subop = decoded instruction id
```

也就是说，`exe_subop` 不再定义成“算子级 semantic selector”，而是定义成 decode 之后的唯一指令身份。原则上，每条 ORBE 支持的 RISC-V 指令对应一个 subop。opcode/funct 字段由 `RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md` 维护，`exe_subop_pkg.sv` 中的 proposal 数值由这些编码字段组合得到，而不是使用表格行号。

---

## 当前决策

1. `exe_subop` 与具体指令一一对应。

   例如：

   ```text
   ADD   -> SUBOP_ADD
   ADDI  -> SUBOP_ADDI
   LUI   -> SUBOP_LUI
   LB    -> SUBOP_LB
   LBU   -> SUBOP_LBU
   FADD.S -> SUBOP_FADD_S
   FADD.D -> SUBOP_FADD_D
   ```

2. `exe_subop` 不再固定为 6 bit。

   位宽由参数决定，例如：

   ```systemverilog
   parameter int BACKEND_EXE_SUBOP_W = <由编码方案决定>;
   typedef logic [BACKEND_EXE_SUBOP_W-1:0] backend_exe_subop_t;
   ```

   因此，不再受 Group 0 指令数超过 64 的限制。

   当前 `exe_subop_pkg.sv` 使用 24 bit proposal key：`{format[1:0], opcode_or_op[6:0], funct3[2:0], high_fixed[11:0]}`。这个宽度来自“保留 opcode/funct 派生信息”的需求，不是由指令数量决定。若公司内网算子已有 parameter 宽度，则以公司参数为准。

3. `exe_type` 决定指令去哪个 group。

   `exe_subop` 不负责 route。完整执行语义由下面两层共同决定：

   ```text
   exe_type  -> 选择 Group 0 / 1 / 2 / 3
   exe_subop -> 在该 group 中表示具体指令身份
   ```

4. 算子不会“自动”从 subop 推断自己该不该执行。

   每个 group 内仍然需要局部映射表或辅助分类函数：

   ```text
   is_g0_alu0_subop(subop)
   is_g0_bru_subop(subop)
   is_g0_div_subop(subop)
   is_g0_csr_subop(subop)
   is_g1_mul_subop(subop)
   is_g2_fpu_subop(subop)
   is_g3_lsu_subop(subop)
   ```

   这些函数把“一条具体指令”映射到 group 内的具体算子/算法。

---

## 和旧方案的区别

旧方案：

```text
多条指令 -> 一个 semantic subop -> attributes 区分细节
```

例如：

```text
LB / LH / LW / LD / LBU / LHU / LWU -> G3_LSU_LOAD
ADD / ADDI / LUI / AUIPC -> G0_ALU_ADD
```

新方案：

```text
每条具体指令 -> 一个 subop
```

例如：

```text
LB  -> SUBOP_LB
LBU -> SUBOP_LBU
ADD -> SUBOP_ADD
ADDI -> SUBOP_ADDI
LUI -> SUBOP_LUI
AUIPC -> SUBOP_AUIPC
```

新方案的优点：

- 指令身份保留清楚，便于 debug、trace、验证和对接公司内网算子。
- 不需要为 subop 合并设计大量 attribute。
- `exe_subop` 更接近“解码后的 instruction id”，容易和官方 opcode 表校对。
- 宽度参数化后，不再受 6-bit 编码空间限制。

新方案的代价：

- subop 数量增加。
- group 内算子仍需要对 subop 做二次分类。
- 压缩指令是否保留独立 subop 需要明确策略。
- A 扩展 `.aq/.rl`、F/D 扩展 rounding mode 等编码字段是否并入 subop，需要和公司算子参数规范对齐。

---

## subop 数值来源

建议不要把 subop 写成无法追溯的随意编号。当前 proposal 采用下面的追溯关系：

```text
RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md 的 opcode / funct3 / high fixed field
  -> exe_subop_pkg.sv 中 enc_inst32/enc_c 组合出的 SUBOP_* 数值
```

推荐来源顺序：

1. 优先使用公司内网算子已有 parameter。
2. 若内网没有定义，则使用 `RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md` 中的编码字段组合得到 subop value。
3. 普通 32-bit 指令使用 `{format, opcode, funct3, high_fixed}`；压缩指令使用 `{format, op[1:0], funct3, high_fixed/tag}`。

需要注意：RISC-V 不是所有指令都只靠 `opcode/funct3/funct7` 唯一确定。还可能涉及：

```text
funct12: ECALL / EBREAK / MRET
funct5 + aq/rl: A extension
fmt / rm / funct5: F/D extension
compressed quadrant / funct bits: C extension
```

因此更准确的说法是：

```text
subop 是 decoded instruction id；
当前 proposal 的 subop value 直接由 opcode/funct 字段组合得到。
```

精确 opcode/funct 字段以 `RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md` 为准。若公司内网算子参数表存在，则最终冻结时可把当前字段组合值替换为公司参数。

## 位宽原则

`exe_subop` 位宽不应凭空指定。推荐决策顺序：

1. 如果公司内网算子已有 parameter 宽度，直接采用该宽度。
2. 如果使用当前 opcode/funct 组合方案，则按 key 的组成决定宽度。当前 key 是 `2 + 7 + 3 + 12 = 24 bit`。
3. 若未来改成纯 instruction id 编号方案，194 个 instruction item 至少需要 8 bit；但这不是当前方案。

因此：

```text
24 bit 是当前 opcode/funct 组合 proposal 的宽度；
最终宽度仍可被公司内网算子 parameter 覆盖。
```

当前 proposal 已把 opcode/funct 派生信息放入 subop value；冻结前仍需确认公司参数规范是否采用同样编码。

---

## Group 0 指令集合

Group 0 包含 ALU0 / BRU / DIV / CSR 相关指令，以及 trap/return 等控制语义。`exe_type` 必须把这些固定路由到 G0，除非 dispatch policy 把纯 ALU 子集分流到 G1 ALU1。

### G0 ALU0 指令

- `ADDI`
- `SLTI`
- `SLTIU`
- `XORI`
- `ORI`
- `ANDI`
- `SLLI`
- `SRLI`
- `SRAI`
- `LUI`
- `AUIPC`
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
- `ADDIW`
- `SLLIW`
- `SRLIW`
- `SRAIW`
- `ADDW`
- `SUBW`
- `SLLW`
- `SRLW`
- `SRAW`

### G0 BRU 指令

- `JAL`
- `JALR`
- `BEQ`
- `BNE`
- `BLT`
- `BGE`
- `BLTU`
- `BGEU`

### G0 DIV 指令

- `DIV`
- `DIVU`
- `REM`
- `REMU`
- `DIVW`
- `DIVUW`
- `REMW`
- `REMUW`

### G0 CSR / System 指令

- `CSRRW`
- `CSRRS`
- `CSRRC`
- `CSRRWI`
- `CSRRSI`
- `CSRRCI`
- `ECALL`
- `EBREAK`
- `MRET`

### G0 压缩指令输入

如果压缩指令保留独立 subop，则以下 `C.*` 指令也属于 G0 相关 subop：

- `C.ADDI4SPN`
- `C.NOP`
- `C.ADDI`
- `C.ADDIW`
- `C.LI`
- `C.ADDI16SP`
- `C.LUI`
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
- `C.J`
- `C.JR`
- `C.JALR`
- `C.BEQZ`
- `C.BNEZ`
- `C.EBREAK`

---

## Group 1 指令集合

Group 1 包含 ALU1 / MUL。

### G1 ALU1 可分流指令

这些指令和 G0 ALU0 使用相同具体 subop，但 `exe_type` 可由 dispatch policy 选择为 G1：

- `ADDI`
- `SLTI`
- `SLTIU`
- `XORI`
- `ORI`
- `ANDI`
- `SLLI`
- `SRLI`
- `SRAI`
- `LUI`
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
- `ADDIW`
- `SLLIW`
- `SRLIW`
- `SRAIW`
- `ADDW`
- `SUBW`
- `SLLW`
- `SRLW`
- `SRAW`

`AUIPC` 固定 G0-only，因为它依赖 ALU0/BRU 的 PC-relative path。

如果压缩指令保留独立 subop，可分流的压缩 ALU 指令包括：

- `C.ADDI4SPN`
- `C.NOP`
- `C.ADDI`
- `C.ADDIW`
- `C.LI`
- `C.ADDI16SP`
- `C.LUI`
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

### G1 MUL 指令

- `MUL`
- `MULH`
- `MULHSU`
- `MULHU`
- `MULW`

---

## Group 2 指令集合

Group 2 包含 FPU。ORBE 当前列出 RV64F 单精度指令和标准非压缩 RV64D 双精度指令。

- `FLW` 不在 G2 执行，属于 G3 LSU load，目标 register bank 是 FP。
- `FSW` 不在 G2 执行，属于 G3 LSU store，source register bank 是 FP。
- `FLD` 不在 G2 执行，属于 G3 LSU load，目标 register bank 是 FP。
- `FSD` 不在 G2 执行，属于 G3 LSU store，source register bank 是 FP。

G2 FPU 指令：

- `FMADD.S`
- `FMSUB.S`
- `FNMSUB.S`
- `FNMADD.S`
- `FMADD.D`
- `FMSUB.D`
- `FNMSUB.D`
- `FNMADD.D`
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
- `FSGNJ.S`
- `FSGNJN.S`
- `FSGNJX.S`
- `FSGNJ.D`
- `FSGNJN.D`
- `FSGNJX.D`
- `FMIN.S`
- `FMAX.S`
- `FMIN.D`
- `FMAX.D`
- `FCVT.W.S`
- `FCVT.WU.S`
- `FCVT.L.S`
- `FCVT.LU.S`
- `FCVT.W.D`
- `FCVT.WU.D`
- `FCVT.L.D`
- `FCVT.LU.D`
- `FCVT.S.W`
- `FCVT.S.WU`
- `FCVT.S.L`
- `FCVT.S.LU`
- `FCVT.D.W`
- `FCVT.D.WU`
- `FCVT.D.L`
- `FCVT.D.LU`
- `FCVT.S.D`
- `FCVT.D.S`
- `FMV.X.W`
- `FMV.W.X`
- `FMV.X.D`
- `FMV.D.X`
- `FEQ.S`
- `FLT.S`
- `FLE.S`
- `FCLASS.S`
- `FEQ.D`
- `FLT.D`
- `FLE.D`
- `FCLASS.D`

---

## Group 3 指令集合

Group 3 是 LSU 路径。这里列出会走 memory / LSU / memory-ordering 相关路径的具体指令。

### G3 Load / Store 指令

- `LB`
- `LH`
- `LW`
- `LD`
- `LBU`
- `LHU`
- `LWU`
- `SB`
- `SH`
- `SW`
- `SD`
- `FLW`
- `FSW`
- `FLD`
- `FSD`

### G3 Fence 指令

这些不是普通 load/store 算子，但需要 backend serialization 和 FE/cache 或 memory-system 协作：

- `FENCE`
- `FENCE.I`

### G3 Atomic 指令

A 扩展完整验证依赖 memory/cache agent 对 atomic / reservation / ordering 的支持。

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

### G3 压缩 Load / Store 输入

如果压缩指令保留独立 subop，则以下指令属于 G3：

- `C.LW`
- `C.LD`
- `C.FLD`
- `C.SW`
- `C.SD`
- `C.FSD`
- `C.LWSP`
- `C.LDSP`
- `C.FLDSP`
- `C.SWSP`
- `C.SDSP`
- `C.FSDSP`

---

## 算子如何识别自己该执行什么

算子不能“自动”根据 subop 知道自己该不该执行。必须有 group 内局部 decode / classification。

例如 Group 0 内部：

```systemverilog
function automatic logic is_g0_alu0_subop(backend_exe_subop_t s);
    return s inside {SUBOP_ADD, SUBOP_ADDI, SUBOP_SUB, SUBOP_AND, ...};
endfunction

function automatic logic is_g0_bru_subop(backend_exe_subop_t s);
    return s inside {SUBOP_JAL, SUBOP_JALR, SUBOP_BEQ, SUBOP_BNE, ...};
endfunction

function automatic logic is_g0_div_subop(backend_exe_subop_t s);
    return s inside {SUBOP_DIV, SUBOP_DIVU, SUBOP_REM, SUBOP_REMU, ...};
endfunction
```

Group 1 内部：

```systemverilog
function automatic logic is_g1_mul_subop(backend_exe_subop_t s);
    return s inside {SUBOP_MUL, SUBOP_MULH, SUBOP_MULHSU, SUBOP_MULHU, SUBOP_MULW};
endfunction
```

因此：

```text
exe_type 决定进哪个 group；
subop 表示具体指令身份；
group 内辅助分类函数决定启用哪个算子；
算子内部再按 subop 执行具体指令算法。
```

---

## 统计口径

按来源清单，不展开 A 扩展 `.aq/.rl/.aqrl` suffix 时：

```text
RV64I base integer，不含 FENCE.I: 52
Zifencei: 1
Zicsr: 6
ORBE required privileged subset: 1
RV64M: 13
RV64A: 22
RV64F single precision: 30
RV64D double precision: 32
RV64C: 37
Total: 194
```

如果严格按 A 扩展 encoding form，把 `.aq/.rl/.aqrl` 都作为独立 subop，22 个 A base mnemonic 会扩展到 88 个 A forms，总数变为：

```text
194 - 22 + 88 = 260
```

这个口径包含压缩 D load/store forms：`C.FLD`、`C.FLDSP`、`C.FSD`、`C.FSDSP`。

---

## 待确认项

1. 公司内网算子是否已有统一 subop parameter 表。
2. A 扩展的 `.aq/.rl/.aqrl` 是否作为独立 subop。
3. F/D 扩展的 rounding mode 是否作为 subop 的一部分，还是作为独立控制字段。
4. C 扩展是否保留独立 subop，还是 FE 先展开为非压缩 instruction id。
5. 精确 subop 数值是否直接使用 opcode/funct 字段组合，还是替换为公司内部 instruction id parameter。
