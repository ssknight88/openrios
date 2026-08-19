# Subop / Opcode / Funct3 关系说明

本文用于澄清 RISC-V 指令编码字段和 ORBE 后端 `exe_subop` 的关系。

---

## 当前结论

```text
opcode / funct3 / funct7 是 RISC-V 指令编码字段，是 decode 的输入。
exe_subop 是 decode 之后生成的 decoded instruction id，是 BE payload/control bundle 的一部分。
```

当前 ORBE subop 方案采用：

```text
一条具体支持指令 -> 一个 exe_subop
```

因此 `exe_subop` 不再是“多个指令共享的算子级 selector”，而是后端携带的具体指令身份。当前 proposal 的 `exe_subop` 数值由 `RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md` 中的 opcode/funct 字段组合得到，不使用表格行号。

---

## opcode 是什么

`opcode` 是 RISC-V 指令编码中的大类字段，通常位于 32-bit 指令的 `inst[6:0]`。

`opcode` 不是一条指令一个。一个 opcode 往往覆盖一组指令。

例如：

```text
opcode = LOAD
  LB / LH / LW / LD / LBU / LHU / LWU

opcode = OP
  ADD / SUB / SLL / SLT / SLTU / XOR / SRL / SRA / OR / AND
  也包括 M 扩展中的 MUL / DIV / REM 等

opcode = BRANCH
  BEQ / BNE / BLT / BGE / BLTU / BGEU
```

所以 `opcode` 是第一层分类字段。

---

## funct3 / funct7 是什么

`funct3` 通常位于 `inst[14:12]`，用于在同一个 opcode 大类中继续区分功能。

`funct3` 的含义依赖 opcode。例如同样 `funct3 = 000`：

```text
opcode = OP-IMM  -> ADDI
opcode = OP      -> ADD 或 SUB，还要继续看 funct7
opcode = LOAD    -> LB
opcode = STORE   -> SB
opcode = BRANCH  -> BEQ
```

`funct7` 常用于在 `opcode + funct3` 仍不足以区分时继续细分。

例如：

```text
ADD:
  opcode = OP
  funct3 = 000
  funct7 = 0000000

SUB:
  opcode = OP
  funct3 = 000
  funct7 = 0100000

SRL:
  opcode = OP
  funct3 = 101
  funct7 = 0000000

SRA:
  opcode = OP
  funct3 = 101
  funct7 = 0100000
```

因此：

```text
opcode / funct3 / funct7 共同参与决定具体指令身份。
```

---

## exe_subop 是什么

`exe_subop` 不是 RISC-V 指令原始编码里的固定字段。RISC-V 指令中没有哪几位天然叫 subop。

在当前 ORBE 方案中：

```text
exe_subop = decode 后的唯一指令 ID
```

也就是说：

```text
ADD   -> SUBOP_ADD
ADDI  -> SUBOP_ADDI
LB    -> SUBOP_LB
LBU   -> SUBOP_LBU
FADD.S -> SUBOP_FADD_S
FADD.D -> SUBOP_FADD_D
FLD   -> SUBOP_FLD
```

`exe_subop` 可以对齐公司内网参数，也可以采用本文档当前的 opcode/funct 字段组合方案。无论哪种方案，它仍然是 decode 输出，不是原始 instruction bits 的简单切片。

原因是 RISC-V 指令格式并不统一。有些指令需要：

```text
opcode + funct3 + funct7
```

有些还需要：

```text
funct12
funct5 + aq/rl
fmt / rm: F/D floating-point format and rounding mode
compressed quadrant / compressed funct bits
```

所以更准确的描述是：

```text
opcode/funct 字段用于 decode；
exe_subop 是 decode 后的唯一 instruction id。
```

当前文件集合中，字段来源关系是：

```text
RISCV_SUPPORTED_OPCODE_FUNCT_TABLE.md
  记录每条支持指令的 opcode / funct3 / funct7 / funct12 / funct5 / C-extension bits

exe_subop_pkg.sv
  使用该表 opcode/funct 字段组合出 SUBOP_* 数值
```

---

## exe_type 和 exe_subop 的关系

`exe_type` 决定指令去哪个 group：

```text
G0: ALU0 / BRU / DIV / CSR
G1: ALU1 / MUL
G2: FPU
G3: LSU / memory path
```

`exe_subop` 不负责决定去哪个 group。它只表示具体指令身份。

完整 BE 解释上下文是：

```text
{exe_type, exe_subop}
```

例如：

```text
ADD:
  exe_subop = SUBOP_ADD
  exe_type  = G0 或 G1，由 dispatch policy 决定

AUIPC:
  exe_subop = SUBOP_AUIPC
  exe_type  = G0

MUL:
  exe_subop = SUBOP_MUL
  exe_type  = G1

FADD.S:
  exe_subop = SUBOP_FADD_S
  exe_type  = G2

FADD.D:
  exe_subop = SUBOP_FADD_D
  exe_type  = G2

FLD:
  exe_subop = SUBOP_FLD
  exe_type  = G3

LD:
  exe_subop = SUBOP_LD
  exe_type  = G3
```

---

## 算子能否自动识别指令该由谁执行

不能自动识别。必须有 group 内局部 decode / classification。

`exe_type` 先把指令送到某个 group。进入 group 之后，仍然需要根据 `exe_subop` 判断该启用哪个算子。

例如 Group 0 内部需要：

```systemverilog
is_g0_alu0_subop(subop)
is_g0_bru_subop(subop)
is_g0_div_subop(subop)
is_g0_csr_subop(subop)
```

Group 1 内部需要：

```systemverilog
is_g1_alu1_subop(subop)
is_g1_mul_subop(subop)
```

因此执行链路是：

```text
instruction bits
  -> decode 得到 exe_type / exe_subop
  -> exe_type 选择 group
  -> group 内辅助分类函数根据 exe_subop 选择算子
  -> 算子内部根据 exe_subop 执行具体指令算法
```

---

## decode 后是否保留原始指令 bits

默认不需要。

`RV64` 表示 `XLEN=64`，不表示一条指令是 64 bit。普通 RISC-V 指令通常是 32-bit；支持 C 扩展时还有 16-bit compressed 指令。

decode 前：

```text
inst[31:0] 或 inst[15:0]
```

decode 后传入 BE：

```text
exe_type
exe_subop
rd/rs index
imm
pc
预测信息
其他 side-effect/control metadata
```

BE payload 不需要默认保留 raw opcode/funct3/funct7。只有 debug、trace、illegal instruction tval、验证 scoreboard 等特殊用途才需要携带 raw instruction bits。

---

## BE payload 是否需要定义 bit 位范围

最终 RTL contract 需要精确定义字段位宽和布局，但不一定要在概念讨论阶段手写 flat bit range。

如果使用 `typedef struct packed`，优先冻结字段名、宽度、顺序和语义：

```systemverilog
typedef struct packed {
    logic [1:0] exe_type;
    backend_exe_subop_t exe_subop;
    logic [4:0] rd_idx;
    logic       imm_valid;
    logic [63:0] imm_data;
} be_payload_t;
```

如果使用 flat bus，则必须明确：

```text
be_payload[127:126] = exe_type
be_payload[125:??]  = exe_subop
...
```

ORBE 更适合先用 struct 字段定义接口，再在需要对接 TB 或外部工具时导出 bit range。

---

## 示例：LD x5, 16(x6)

```asm
LD x5, 16(x6)
```

32-bit I-type 编码：

```text
31          20 19   15 14  12 11    7 6      0
+-------------+-------+------+--------+--------+
| imm[11:0]   | rs1   |funct3| rd     | opcode |
+-------------+-------+------+--------+--------+
```

字段值：

```text
imm[11:0] = 16       = 000000010000
rs1       = x6       = 00110
funct3    = LD       = 011
rd        = x5       = 00101
opcode    = LOAD     = 0000011
```

decode 后：

```text
exe_type  = G3
exe_subop = SUBOP_LD
```

当前 proposal 中，`SUBOP_LD = enc_inst32(OPCODE_LOAD, F3_011, hi_none())`。也就是说，`LOAD opcode + LD funct3` 不只是表格追溯信息，而是直接参与生成 `SUBOP_LD` 的值。

---

## 总结

```text
opcode / funct3 / funct7:
  原始 ISA 编码字段，是 decode 输入。

exe_subop:
  decode 输出，是一条具体支持指令的唯一 ID。

exe_type:
  decode/dispatch 输出，决定进哪个 execution group。

group 内辅助分类函数:
  在 group 内根据 subop 决定启用哪个算子。
```

当前设计目标：

```text
subop 保留具体指令身份；
exe_type 负责 group 路由；
group 内辅助分类函数负责算子选择。
```
