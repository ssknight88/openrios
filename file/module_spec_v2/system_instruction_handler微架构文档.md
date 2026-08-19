# system_instruction_handler · 系统指令退休效应宿主 · 架构 CSR / 特权态 + csr_stage

scoreboard 组的第四个子模块（与 CompletionSCB、flush_model、SerialInstructionTracker 并列）。
系统指令的**退休效应**在此落笔——裁决仍在 [[CompletionScoreboard微架构文档.md]] 的判定链，
本模块只负责"生效"。由原 csr_file（架构 CSR 寄存器堆与特权态）与原 SCB 的 `csr_stage`
（CSR 写意图暂存）合并而成：**架构寄存器 flush 不动；`csr_stage` 是本模块唯一投机寄存器，
随 flush 作废。**

### ① per-entry state

`EMPTY / STAGED` —— **本模块只有 `csr_stage` 有状态**。

- 就是 `csr_stage.valid` 一位：0 = EMPTY，1 = STAGED。它是全库唯一的 CSR 写意图暂存，
  也是本模块唯一的投机寄存器，随 flush 作废
- **单寄存器容量的依据**：串行化 ⇒ 写意图同时存在量至多为 1，per-tag ×16 是纯浪费
- **架构寄存器组无阶段**——它们只有值、没有生命周期，flush 一律不动。
  寄存器清单与三角色见 ⑤

### ② state transition & condition（event 名）

- csr_stage：EMPTY → STAGED：capture；STAGED → EMPTY：apply / flush
- 架构组**无阶段转移**，写 event 四类：apply（软件写落笔）/ `trap_entry` / `mret_update` /
  `fflags_accrue`（FP 退休累加）；另计数器自增（内部）

### ③ condition 细化

#### capture（csr_stage）

```text
capture = Result_valid[0] ∧ is_csr ∧ csr_write_enable ∧ !global_flush_late
          → csr_stage ← {valid:1, tag: tag_out[0], addr: csr_addr, wdata: csr_wdata}
```

- **只监听 lane 0**——CSR 固定路由 G0；`is_csr` / `csr_write_enable` 只当 lane 线用
  （lane 0 的字段清单见 [[p3_arbiter_G0微架构文档.md]] ⑥）
- MRET 的 `is_csr = 0` ⇒ capture 不被 MRET 误触发；非法 CSR 由 csr_fu 置 `we = 0`
  不 capture（就算 capture 了也有 flush 兜底）
- 单寄存器容量依据：串行化 ⇒ **写意图同时存在量至多为 1**，per-tag ×16 是纯浪费

#### apply（软件写落笔）

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
- **本模块不复判合法性**：非法写在执行侧已被 csr_fu 判为异常
- **命中硬连组时写被静默忽略**（WARL 口径）：`misa` 等在可写地址空间且已实现，
  csr_fu 的非法判据拦不住——该写合法到达，但硬连组无存储，落笔即丢弃
- 命中 `mcycle` / `minstret` 时**软件写当拍覆盖自增**

**apply 不是整字覆盖**——逐寄存器按可写位掩码落笔，未列位保持原值或读 0：

```text
mstatus   可写 MIE(3)、MPIE(7)、FS(14:13)
          MPP(12:11) 写任何值均钳到 M（M-only；U 态落地前不接受其它值）
          SD(63) 是派生只读位 = (FS == Dirty)，**不是存储位、不得 sticky**
mie       只实现 MEIE(11) / MTIE(7) / MSIE(3)，其余位读 0
mtvec     只实现 Direct 模式 ⇒ 写入规范化为 {wdata[63:2], 2'b00}
          不得出现"读回 MODE=1 却无 vectored 语义"
mepc      可写位由 IALIGN 决定，与 ENABLE_C 同源：
          ENABLE_C = 1（IALIGN=16）⇒ 可写 [63:1]，只有 [0] 恒 0
          ENABLE_C = 0（IALIGN=32）⇒ 可写 [63:2]，[1:0] 恒 0
mcause / mtval / mscratch / mcycle / minstret     全字可写
mip       全只读（见 ③ 电平节），csrw 静默忽略
硬连只读组（mhartid / mvendorid / marchid / mimpid / misa）   写静默忽略
```

**`mepc[1]` 那一位不是可选放宽，是 C 的硬要求**：启用 C 之后指令可以落在 2 字节边界上，
`mepc` 必须能表示这种 PC，否则从压缩指令上取的 trap 返回地址会被截错。

#### 硬件写（trap 边界，flush_model 的 `trap_state_write` 驱动）

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

#### FP 退休累加（`fflags_accrue`）

```text
提交拍对每条有效 commit lane 的 fflags 按位或进架构 fflags：
fflags ← fflags | (commit_valid[0] ? commit_fflags[0] : 0)
                | (commit_valid[1] ? commit_fflags[1] : 0)

fp_dirty = (commit_valid[0] ∧ ((rd_write_enable[0] ∧ rd_is_fp[0]) ∨ commit_fflags[0] != 0))
         ∨ (commit_valid[1] ∧ ((rd_write_enable[1] ∧ rd_is_fp[1]) ∨ commit_fflags[1] != 0))
mstatus.FS ← fp_dirty ? Dirty : mstatus.FS
mstatus.SD    派生只读，恒 = (mstatus.FS == Dirty)，不参与本次写
```

- **两条 lane 直接按位或、无需仲裁**：fflags 是 sticky OR、可交换；同拍两条 lane
  都可能非零（写整数 rd 的 FP 比较 / 转换也产标志），OR 合并天然正确
- **FS 脏判据**：**真的写了** FP 寄存器（`rd_write_enable ∧ rd_is_fp`）或产生了非零 fflags。
  `FMV.X.W` / `FCLASS`（rd 整数、fflags=0）不置脏；FP store（`use_rd = 0`）也不置脏——
  **必须用 `rd_write_enable` 限定**，否则不写 rd 的指令上一个无意义的 `rd_is_fp`
  会误置脏。误置脏在架构上无害（只是多存一次 FP 上下文），但判据要写准
- **`FS` 只做单向的 `→ Dirty`**：本路径永远不会把 `FS` 置成 `Off`，也解不掉 `Off`。
  这一条是 `dispatch_logic` 在派遣拍读 `fs_enabled` 得以安全的依据之一——
  详见该文档 ④#1 的时序论证
- **陷入 Illegal 的 FP 指令不更新 `fflags` / `FS`**：它已改道 G0 的 ILLEGAL 路径，
  `fpu_fflags` 恒 0 且不提交，两条路都到不了这里
- **`trap_entry` / `mret_update` 不触碰 `FS` 与 `frm`**：见 ④ 的硬件写节，
  两者只动 `mstatus` 的 MIE/MPIE/MPP 与 trap 三样
- **软件写 `fflags` / `frm` / `fcsr` 地址时**，apply 路径自身置 `FS ← Dirty`；CSR 读不置脏
- **单写口够用**：CSR 指令串行 ⇒ 其提交拍不会有 FP 指令同拍退休累加，软件写与累加不撞同拍

#### 计数器

```text
mcycle   每拍 += 1
minstret 每拍 += commit_count        // SCB 的退休条数，0..2
```

软件写命中当拍，写值覆盖自增结果。

#### 电平（`mip`）

**M-only 下 `mip` 整个只读、无存储**——它是三根顶层电平的组合视图，`csrw mip` 静默忽略
（与硬连组同口径）。RISC-V 里 `mip` 可软件写的只有 S 态那几位，本实现没有 S 态。

```text
mip[11] = MEIP      外部中断
mip[7]  = MTIP      定时器中断
mip[3]  = MSIP      软件中断
其余位读 0；mie 也只实现 MEIE(11) / MTIE(7) / MSIE(3) 三位
```

- **顶层供三根电平**，未接的顶层置 0（当前只接外部中断时，`interrupt_cause` 自然恒为 MEI）
- **电平的稳定性契约**（顶层义务）：送进来的三根必须**已跨时钟域同步**；
  源若可能是短脉冲，须在上游锁存成 pending level。否则会漏中断
- **cause 必须在选中拍锁存**：SCB 判定链选中中断时，`interrupt_cause` 要随 flush / trap event
  一并锁存，**不得等到 `trap_entry` 拍再重新组合 `mie & mip`**——电平在这两拍之间可能已变，
  重新组合会取到错的 cause

#### flush

```text
flush = global_flush_late → csr_stage.valid_d ← 0      // 架构寄存器不动
```

- 未退休且未发生 `apply_fire` 的 CSR 写意图在 flush 时蒸发；中断抢占后重取重执行、重新 capture——架构正确
- 架构寄存器没有投机成分，无可回滚

### ④ data path

#### 1. 写通路

```text
capture 输入端口（lane 0）→ csr_stage                {tag, addr, wdata}
csr_stage                 → CSR[csr_stage.addr]      apply 拍落笔（单写口）
trap 输入端口             → mepc / mcause / mtval     epc / cause / tval
commit_count             → minstret                  自增量
顶层电平                  → mip 的外部中断位           不落盘，直接参与组合
```

#### 2. 派生组合（output）

```text
trap_vector(cause, is_interrupt) =
    (mtvec.MODE == VECTORED) ∧ is_interrupt ? {mtvec.BASE, 2'b00} + (cause << 2)
                                            : {mtvec.BASE, 2'b00}

interrupt_pending = mstatus.MIE ∧ |(mie & mip)
interrupt_cause   = priority_encode(mie & mip)        // MEI > MSI > MTI
```

`interrupt_pending` 是**已经综合完**的一根线，消费者（SCB 判定链）直接用，
**不再自行组合** `mie` / `mip` / `mstatus.MIE`。

#### 3. 软件读口

```text
CSR[csr_addr] → 读出端口    旧值（1 读口）
```

- 硬连组按地址返回常量；trap 组 / 计数器返回寄存器现值
- 未实现地址的读出值为 0——但**该读永远不该被采用**：csr_fu 在执行侧已判非法

### ⑤ data structure（schema + 字段三角色）

架构寄存器分三组，**flush 一律不动**（无投机成分，无可回滚）；`csr_stage` 是唯一投机寄存器。

- **state**：`csr_stage.valid`(1) —— 见 ①，本模块唯一的生命周期位

- **header**（被派生逻辑或判据当谓词读）
    - `mstatus` 的 `MIE` / `MPIE` / `MPP`、`mie`、`mip`、`mtvec` —— 派生 `interrupt_pending`、
      `interrupt_cause`、`trap_vector`
    - `mstatus.FS`(2) —— FP 单元脏标记。`mstatus.SD` **不是存储位**，
      是 `(FS == Dirty)` 的派生只读投影
    - `current_priv` —— 特权检查入参，送 csr_fu。**它不是 CSR**：无 12-bit 地址、
      软件读写不到（RISC-V 故意不提供"当前特权级"查询口），只随 trap / MRET 变化。
      **当前实现恒 M**；U 态待补
    - `csr_stage.tag`(4) —— apply 时与 `commit_tag[k]` 比对

- **payload**（只存与转发，本模块不对其求谓词）
    - trap 组：`mepc`、`mcause`、`mtval`、`mscratch`
    - 计数器：`mcycle` / `minstret` —— 真 64 位，可软件写（软件写当拍覆盖自增）
    - FP 组：`fflags`(5，地址 0x001)、`frm`(3，地址 0x002)。
      `fcsr`(地址 0x003) **不是独立寄存器**，是 `{frm, fflags}` 的组合视图。
      `fflags` 是粘性标志，FP 指令退休时按位或累加（见 ③）；`frm` 供 `dispatch_logic`
      在派遣拍算 `effective_rm`（**不直供 FPU**，见 ⑥）
    - `csr_stage.{csr_addr(12), csr_wdata(64)}`
    - `CSR[csr_addr]` 的读写值

- **硬连只读组，无存储**
    - `mhartid` / `mvendorid` / `marchid` / `mimpid` —— 读 0（`mhartid = 0` 即 hart 0）
    - `misa` —— **不是常量，是由静态配置打包出来的只读值**。MXL 恒为 2（RV64，bits[63:62]）；
      扩展位由同一组 `ENABLE_*` 参数导出，与 decode、FE、LSU、FPU 同源：

```text
ENABLE_A  →  bit 0  (A)     ENABLE_C  →  bit 2  (C)
ENABLE_FD →  bit 3  (D) 与 bit 5 (F)
恒置      →  bit 8  (I)     bit 12 (M)

全部启用   misa = 64'h8000_0000_0000_112D    RV64IMAFDC
仅 IMFD    misa = 64'h8000_0000_0000_1128    A、C 两位为 0
```

      **某个扩展的库外契约未闭合时，对应位必须为 0**——`misa` 报告的是构建配置**已经实现**
      的 ISA，不是开关、也不是路线图。翻位的前置条件见 `../异常与trap语义.md` §6。
      该值须与 lockstep 用的 ISS `--isa` 一致：全启用时为 `rv64imafdc_zicsr_zifencei`

### ⑥ 接口

**in-event** `→ system_instruction_handler`

- capture（announce ×1，监听 p3_arbiter_G0 的 lane 0）
    - move；`csr_addr`(12)、`csr_wdata`(64) —— 存入 `csr_stage`
    - broadcast；`is_csr`(1)、`csr_write_enable`(1) —— capture 判据，不留存
    - 触发；`Result_valid[0]`(1)
    - 地址；`tag_out[0]`(4) —— 存入 `csr_stage.tag`
    - 收的是 lane 0 专有的 `csr_sideband` 层，加公共层 `completion_common` 里的
      `Result_valid` 与 `tag_out` 两样作触发与身份。`csr_sideband` **不经过**
      [[CompletionScoreboard微架构文档.md]]，也不由该模块保存或转发；其余 lane 不携带这组字段。
      `is_csr` 区分 G0 上的 CSR 与 ALU/BRU/DIV completion；`csr_write_enable` 区分
      只读 CSR 操作与实际写意图

- commit（announce，**2 lane**）
    - broadcast；`commit_valid[k]`(1，k∈{0,1})、`commit_tag[k]`(4，k∈{0,1}) ——
      与 `csr_stage.tag` 比对，不留存
    - broadcast；`commit_fflags[k]`(5，k∈{0,1})、`rd_is_fp[k]`(1，k∈{0,1})、
      `rd_write_enable[k]`(1，k∈{0,1}) ——
      `fflags_accrue`：fflags 按位或、FS 脏判据（见 ③）。
      `rd_write_enable` 用来限定"真的写了 FP 寄存器"，缺它会误置脏
    - broadcast；`commit_count`(2) —— `minstret` 自增量

- `trap_state_write`（announce ×1）
    - move；`epc`(64)、`cause`(63)、`tval`(64) —— 分别写进 `mepc` / `mcause` / `mtval`
      （`mret_update` 下本模块不采样这三个）
    - 选通；`kind`(3) —— 选 `trap_entry` 还是 `mret_update`；本模块既不存它也不算它。
      `MISPREDICT` / `FENCE_I` 两种 kind 下对端的 `valid = 0`，整包不到达本模块
    - 触发；`valid`(1) —— 本拍要不要更新架构态

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，**只清 `csr_stage.valid`**，架构寄存器不动

- 组合读(in)
    - 地址；`csr_addr`(12) —— 软件读口选中哪个寄存器
    - broadcast；`cause`(63) —— `trap_vector` 读口的入参，在 `(cause << 2)` 里被算
    - 选通；`is_interrupt`(1) —— `trap_vector` 的第二个入参，选 vectored 还是 direct
    - broadcast；`mip` 的外部中断位 —— 顶层电平直驱，**无 fire**，不存进本模块的任何 event

**out-event** `system_instruction_handler →`

- 组合读(out)；`CSR[csr_addr]`(64) —— 软件读口旧值
- 组合读(out)；`current_priv` —— 特权检查入参（M-only 下恒 M，检查退化为只读位判断）
- 组合读(out)；`frm`(3) —— 供 `dispatch_logic` 在派遣拍算 `effective_rm` 与 `frm_illegal`。
  **不再直供 FPU**：舍入模式在派遣拍定格后随 payload 走，FPU 不读实时值
- 组合读(out)；`fs_enabled`(1) —— `= (mstatus.FS != Off)`。两个消费者：
  `dispatch_logic` 判 `fp_illegal`、csr_fu 判 `fcsr`/`fflags`/`frm` 三个地址是否可访问
- 组合读(out)；`trap_vector(cause, is_interrupt)`(64) —— 带外部参数，故不入 Static Info

**Static Info**

无 fire、无外部参数，由自身状态导出：

- `interrupt_pending`(1) —— `mstatus.MIE` / `mie` / `mip` 的组合投影，
  **含顶层直驱的外部电平 `mip`**（消费者：SCB 判定链第一步分支 4）
- `interrupt_cause` —— `priority_encode(mie & mip)`，同样**含 `mip`**（消费者：flush_model）
- `mepc`(64) —— 架构寄存器本体，按名读、无地址（消费者：flush_model 的 MRET 恢复 PC）。
  与 flush_model 按 tag 读 PC_File 得到的 trap epc **同名不同物**——后者只是注释性称呼，
  全库无名为 trap_epc 的导出信号
