# system_instruction_handler · 系统指令退休效应宿主 · 架构 CSR / 特权态 + csr_stage

scoreboard 组的第四个子模块（与 CompletionSCB、flush_model、SerialInstructionTracker 并列）。
系统指令的**退休效应**在此落笔——裁决仍在 [[CompletionScoreboard微架构文档.md]] 的判定链，
本模块只负责"生效"。由原 csr_file（架构 CSR 寄存器堆与特权态）与原 SCB 的 `csr_stage`
（CSR 写意图暂存）合并而成：**架构寄存器 flush 不动；`csr_stage` 是本模块唯一投机寄存器，
随 flush 作废。** 接口按消费者分侧组织：执行侧 / 写回侧 / 退休侧 / flush 侧 / 顶层。

## ① per-entry state

**架构组无阶段 + `csr_stage` 两态。** 寄存器清单分四块：

- **trap / 特权组**：`mstatus`（MIE / MPIE / MPP）、`mepc`、`mcause`、`mtval`、`mtvec`、
  `mscratch`、`mie`、`mip`，加 `current_priv`——**它不是 CSR**：无 12-bit 地址、
  软件读写不到（RISC-V 故意不提供"当前特权级"查询口），只随 trap / MRET 变化。
  **当前实现恒 M**；U 态待补
- **最小合规组**：`mhartid` / `mvendorid` / `marchid` / `mimpid` / `misa` ——
  硬连只读，全部读 0（`misa = 0` 是 spec 允许的"未实现"口径；`mhartid = 0` 即 hart 0）；
  `mcycle` / `minstret` —— 真 64 位计数器，可软件写
- **csr_stage** = `{valid(1), tag(4), csr_addr(12), csr_wdata(64)}` ——
  全库唯一的 CSR 写意图暂存，串行化"至多一条在飞"不变量的直接编码
- **待补挂点**（系统指令的 charter 归属本模块）：
  - `fcsr`（`frm` / `fflags`）与 `mstatus.FS`（F/D 支持需要）
  - U 态特权检查与 ECALL cause 细则（8/11 之分）
  - ECALL / EBREAK / FENCE / WFI 的路由与子码——见 [[IB微架构文档.md]] ⑤ 待补注记，
    缓行期译码按非法指令 trap
  - FENCE.I：可实现为无条件 `mispredict_flag = 1`、`target = pc + 4`（压缩 `pc + 2`），
    复用 MISPREDICT flush
  - SFENCE.VMA：S 态，远期

## ② state transition & condition（event 名）

- csr_stage：EMPTY → STAGED：capture；STAGED → EMPTY：apply / flush
- 架构组**无阶段转移**，写 event 三类：apply（软件写落笔）/ `trap_entry` / `mret_update`；
  另计数器自增（内部）

## ③ condition 细化

### capture（csr_stage）

```text
capture = Result_valid[0] ∧ is_csr ∧ csr_write_enable ∧ !global_flush_late
          → csr_stage ← {valid:1, tag: tag_out[0], addr: csr_addr, wdata: csr_wdata}
```

- **只监听 lane 0**——CSR 固定路由 G0；`is_csr` / `csr_write_enable` 只当 lane 线用
  （lane 0 的字段清单见 [[p3_arbiter_G0微架构文档.md]] ⑥）
- MRET 的 `is_csr = 0` ⇒ capture 不被 MRET 误触发；非法 CSR 由 csr_fu 置 `we = 0`
  不 capture（就算 capture 了也有 flush 兜底）
- 单寄存器容量依据：串行化 ⇒ **写意图同时存在量至多为 1**，per-tag ×16 是纯浪费

## apply（软件写落笔）

```text
apply_fire = csr_stage.valid ∧ (
      (commit_valid[0] ∧ commit_tag[0] == csr_stage.tag)
   ∨  (commit_valid[1] ∧ commit_tag[1] == csr_stage.tag))

apply_fire → CSR[csr_stage.addr] ← csr_stage.wdata

csr_stage.valid_d = (global_flush_late ∨ apply_fire) ? 0 :
                    capture ? 1 : csr_stage.valid_q
```

- tag 比对自证身份，与 [[SerialInstructionTracker微架构文档.md]] 的 clear 同哲学——
  **凭据保留，不靠"反正只有一条"来省**；**架构状态只在提交拍更新**
- capture（写回拍）与 apply（提交拍）至少隔一拍——`exec_done` 是寄存位，判定链读拍初值
- `apply_fire` 是已退休 CSR 指令的架构效应，不受 `global_flush_late` 门控；若两者同拍，
  CSR 写仍生效，`csr_stage.valid_d` 仍清 0。当前串行不变量下该组合不可达：外部中断抢占时
  `commit_valid=0`，MRET 不 capture，CSR 在飞时不可能有更年轻的分支误预测
- v2 的跨模块事件 `arch_csr_write` **消亡**——捕获与落笔同居本模块后降级为内部一行
- **本模块不复判合法性**：非法写在执行侧已被 csr_fu 判为异常（见 ⑥ 执行侧契约）
- **命中硬连组时写被静默忽略**（WARL 口径）：`misa` 等在可写地址空间且已实现，
  csr_fu 的非法判据拦不住——该写合法到达，但硬连组无存储，落笔即丢弃
- 命中 `mcycle` / `minstret` 时**软件写当拍覆盖自增**

### 硬件写（trap 边界，flush_model 的 `trap_state_write` 驱动）

```text
trap_entry    kind ∈ {EXCEPTION, INTERRUPT}
    mepc ← epc
    mcause ← (kind == INTERRUPT) ? ((64'(1) << 63) | cause) : cause
    mtval ← tval
    mstatus.MPIE ← mstatus.MIE；mstatus.MIE ← 0；mstatus.MPP ← current_priv（恒 M）
    current_priv ← M

mret_update   kind == MRET
    mstatus.MIE ← mstatus.MPIE；mstatus.MPIE ← 1
    current_priv ← mstatus.MPP（M-only 恒 M；U 态待补）
    mstatus.MPP ← M（spec 义务：MRET 后 MPP 置最低支持特权级；U 态实现写 U，待补）
```

- 这两条是本模块**唯一**的 `mstatus` 与 `current_priv` 更新路径；`MISPREDICT` 不触碰架构态
- `trap_state_write.cause` 始终是不带 bit 63 的 cause 编号；仅在写入架构 CSR `mcause` 时，
  `INTERRUPT` 类型才将 bit 63 置 1。`trap_vector(cause, is_interrupt)` 继续使用该低位 cause 编号
- **`mret_update` 只消费 `kind`**：`epc` / `cause` / `tval` 虽在总线上有值，本模块不采样。
  **MRET 不写 `mepc`**——它正要读 `mepc` 作恢复 PC
- 各场景取舍：异常 / 中断只发生 trap 侧写入（异常指令与被中断的指令都不提交）；
  MRET 只执行 `mret_update`；MISPREDICT 两条都不写；正常提交 CSR 指令只执行 apply

### 计数器

```text
mcycle   每拍 += 1
minstret 每拍 += commit_count        // SCB 的退休条数，0..2
```

软件写命中当拍，写值覆盖自增结果。

### 电平

- `mip` 的外部中断位由顶层电平**直接驱动**，不经任何 event；软件可写位才走软件写

### flush

```text
flush = global_flush_late → csr_stage.valid_d ← 0      // 架构寄存器不动
```

- 未退休且未发生 `apply_fire` 的 CSR 写意图在 flush 时蒸发；中断抢占后重取重执行、重新 capture——架构正确
- 架构寄存器没有投机成分，无可回滚

## ④ data path

### 1. 写通路

```text
capture 输入端口（lane 0）→ csr_stage                {tag, addr, wdata}
csr_stage                 → CSR[csr_stage.addr]      apply 拍落笔（单写口）
trap 输入端口             → mepc / mcause / mtval     epc / cause / tval
commit_count             → minstret                  自增量
顶层电平                  → mip 的外部中断位           不落盘，直接参与组合
```

### 2. 派生组合（output）

```text
trap_vector(cause, is_interrupt) =
    (mtvec.MODE == VECTORED) ∧ is_interrupt ? {mtvec.BASE, 2'b00} + (cause << 2)
                                            : {mtvec.BASE, 2'b00}

interrupt_pending = mstatus.MIE ∧ |(mie & mip)
interrupt_cause   = priority_encode(mie & mip)        // MEI > MSI > MTI
```

`interrupt_pending` 是**已经综合完**的一根线，消费者（SCB 判定链）直接用，
**不再自行组合** `mie` / `mip` / `mstatus.MIE`。

### 3. 软件读口

```text
CSR[csr_addr] → 读出端口    旧值（1 读口）
```

- 硬连组按地址返回常量；trap 组 / 计数器返回寄存器现值
- 未实现地址的读出值为 0——但**该读永远不该被采用**：csr_fu 在执行侧已判非法（⑥ 契约）

## ⑤ data structure（schema + 字段三角色）

- **state**：`current_priv`；`csr_stage.valid`
- **header**：`mstatus`（MIE / MPIE / MPP）、`mie`、`mip`、`mtvec`——被派生逻辑当谓词读；
  `csr_stage.tag`(4)——apply 时与 `commit_tag[k]` 比对
- **payload**：`mepc`、`mcause`、`mtval`、`mscratch`、`mcycle`、`minstret`、
  `CSR[csr_addr]` 的读写值——只存与转发；`csr_stage.{addr, wdata}`；硬连组无存储

## ⑥ 接口——按消费者分侧

### 执行侧（对端 csr_fu，库外）

- 组合读(in)
  - 地址；`csr_addr`(12) —— 软件读口选中哪个寄存器
- 组合读(out)；`CSR[csr_addr]`(64) 旧值
- 组合读(out)；`current_priv` —— 特权检查入参（M-only 下恒 M，检查退化为只读位判断）

**csr_fu 行为契约**（库外单元，集成层登记；FU_Group = 1，见 [[ISQ_Group0微架构文档.md]]）：

- 收 issue：`rs1_data`、uimm（`imm` 通道）、`csr_addr`（子码段）、子码、`self_tag`
- 执行拍经本读口**组合读旧值**——串行化保证执行时全机只有它一条在飞，
  旧值必为架构当前值，读无竞争
- 算两样：`result_data` = 旧值（回 rd，上 completion lane 0）；
  写意图 `csr_wdata` / `csr_write_enable`（CSRRW = rs1、CSRRS = old | rs1、CSRRC = old & ~rs1；
  S/C 型在 rs1 = x0 / uimm = 0 时不置写使能）
- 非法判据：未实现地址、或只读 CSR（`csr_addr[11:10] == 11`）且要写
  → `exception_flag` / `cause` = Illegal Instruction，且 `we = 0`
- 非流水：执行中或 P3 仲裁 hold 时 `FU_ready[1] = 0`
- **flush 拍作废在飞工作**（FU flush 契约，[[p3_arbiter_G0微架构文档.md]] ④）
- **绝不当场写任何 CSR**——写意图上 lane 0，由本模块 `csr_stage` 捕获、
  提交拍 apply 才落笔；被 flush 则蒸发

### 写回侧（直接监听 p3_arbiter_G0 的 lane 0）

本接口是 G0 completion 的 CSR 专用旁带连接，不经过 [[CompletionScoreboard微架构文档.md]]，
也不由该模块保存或转发。

- capture（announce ×1，监听 writeback lane 0）
  - move；`csr_addr`(12)、`csr_wdata`(64) —— 存入 `csr_stage`
    - broadcast；`is_csr`(1)、`csr_write_enable`(1) —— capture 判据，不留存
    - 触发；`Result_valid[0]`(1)
    - 地址；`tag_out[0]`(4) —— 存入 `csr_stage.tag`
    - `Result_valid[0] ∧ is_csr ∧ csr_write_enable ∧ !global_flush_late` 时 capture：
      `tag_out[0]` 标识这条 CSR 指令；`csr_addr` / `csr_wdata` 是其待退休写入地址和值。
      `is_csr` 区分 G0 上的 CSR 与 ALU/BRU/DIV completion；`csr_write_enable` 区分
      只读 CSR 操作与实际写意图

### 退休侧（对端 CompletionSCB）

- commit（announce，**2 lane**）
  - broadcast；`commit_valid[k]`(1，k∈{0,1})、`commit_tag[k]`(4，k∈{0,1}) ——
      与 `csr_stage.tag` 比对，不留存
    - broadcast；`commit_count`(2) —— `minstret` 自增量

### flush 侧（对端 flush_model）

- `trap_state_write`（announce ×1）
  - move；`epc`(64)、`cause`、`tval` —— 分别写进 `mepc` / `mcause` / `mtval`
      （`mret_update` 下本模块不采样这三个）
    - 选通；`kind`(2) —— 选 `trap_entry` 还是 `mret_update`；本模块既不存它也不算它
    - 触发；`valid`(1) —— 本拍要不要更新架构态
- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，**只清 `csr_stage.valid`**，架构寄存器不动
- 组合读(in)
  - broadcast；`cause` —— `trap_vector` 读口的入参，在 `(cause << 2)` 里被算
    - 选通；`is_interrupt`(1) —— `trap_vector` 的第二个入参，选 vectored 还是 direct
- 组合读(out)；`trap_vector(cause, is_interrupt)`(64) —— 带外部参数，故不入 Static Info

### 顶层

- broadcast；`mip` 的外部中断位 —— 电平直驱，**无 fire**，不存进本模块的任何 event

**Static Info：**

无 fire、无外部参数，由自身状态导出：

- `interrupt_pending`(1) —— `mstatus.MIE` / `mie` / `mip` 的组合投影，
  **含顶层直驱的外部电平 `mip`**（消费者：SCB 判定链第一步分支 4）
- `interrupt_cause` —— `priority_encode(mie & mip)`，同样**含 `mip`**（消费者：flush_model）
- `mepc`(64) —— 架构寄存器本体，按名读、无地址（消费者：flush_model 的 MRET 恢复 PC）。
  与 flush_model 按 tag 读 PC_File 得到的 trap epc **同名不同物**——后者只是注释性称呼，
  全库无名为 trap_epc 的导出信号
