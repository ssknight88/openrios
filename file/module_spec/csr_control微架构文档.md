# csr_control · 串行化追踪器 + 架构 CSR 与特权态

本模块含两块彼此独立的状态，**flush 的处理完全相反**：

```text
A 串行化 tracker    csr_inflight_valid + csr_inflight_tag       flush 清 0
B 架构 CSR 与特权级  mstatus / mepc / mcause / mtval / mtvec /   flush 不动
                    mie / mip / mscratch / current_priv
```

## ① per-entry state

### A. 串行化 tracker —— `IDLE / INFLIGHT`

- 就是 `csr_inflight_valid` 一位。**全后端只有这一份**，不是 per-tag 数组
- **没有 pending 缓冲**：串行指令的 CSR 写字段住在 Buffer 表项里，
  由执行侧写入、提交拍读走送回本模块

### B. 架构态 —— **无阶段**

- 一组**离散命名寄存器**，不是按地址索引的 RAM
- 每个寄存器两条独立更新通路：软件写（按 `csr_addr` 译码选中一个）与
  硬件写（`trap_entry` / `mret_update`，同拍写多个固定寄存器）
- `mip` 的外部中断位由顶层电平**直接驱动**，不经任何 event；软件可写位才走软件写
- **flush 不动**——没有投机成分，无可回滚

## ② state transition & condition（event 名）

### A. tracker

- IDLE → INFLIGHT：set
- INFLIGHT → IDLE：clear
- INFLIGHT → IDLE：flush

### B. 架构态

**无阶段转移**，三个跨界写 event：`arch_csr_write` / `trap_entry` / `mret_update`。

## ③ condition 细化

### A. tracker

- **set** = `accept[0] ∧ serial0` → `{valid:1, tag = self_tag[0]}`
  - **串行指令只能从 slot0 收** > 依据：[[p1_dsp微架构文档.md]] ④ `slot0_guard_ok`
- **clear** = `csr_clear` ∧ `commit_tag[k] == csr_inflight_tag` → `valid ← 0`
  - **`commit_tag` 相等这一项不可省**：串行指令独占 Buffer 时它必是最老那条，
      但 tag 比对是身份凭据，不能靠"反正只有一条"来省。
      这一项**只能由本模块做**——`csr_inflight_tag` 只有本模块有
    - **对 `csr_clear` 的契约**：它的门控集合必须与本模块 `set` 的置位集合**逐位相等**。
      `set` 用的是含 `is_sys` 的 `serial0`，所以 `csr_clear` 必须用同样口径的
      `is_serial`，**不能是 `is_csr ∨ is_mret`**——否则一条 `is_sys` 指令置位后
      **永远清不掉**，`csr_inflight_valid` 挡死全部派发 = **全机停摆**。
      本模块不自己判这个门控（`is_serial` 住在别处的 entry 里），只提出这条要求
- **flush** = `global_flush_late` → `valid ← 0`
  - **只清 A。架构 CSR 与 `current_priv` 不受影响**
    - 这条同时承担 `ECALL` / `EBREAK` / 任何被 flush 掉的串行指令的 tracker 清除

### B. 架构态写入

```text
arch_csr_write   → CSR[csr_addr] ← csr_wdata
```

串行化保证 CSR/SYS 指令独占 Buffer，故同拍至多一个 lane 满足条件，且必为 lane 0。

```text
trap_entry    kind ∈ {EXCEPTION, INTERRUPT}
    mepc ← epc；mcause ← cause；mtval ← tval
    mstatus.MPIE ← mstatus.MIE；mstatus.MIE ← 0；mstatus.MPP ← current_priv
    current_priv ← M

mret_update   kind == MRET
    mstatus.MIE ← mstatus.MPIE；mstatus.MPIE ← 1
    current_priv ← mstatus.MPP；mstatus.MPP ← （含 U 模式的实现写 U；M-only 写 M）
```

- 这两条是本模块**唯一**的 `mstatus` 与 `current_priv` 更新路径；`MISPREDICT` 不触碰架构态
- **`mret_update` 只消费 `kind`**：`epc` / `cause` / `tval` 虽在总线上有值，本模块不采样。
  **MRET 不写 `mepc`**——它正要读 `mepc` 作恢复 PC

各场景下两条 CSR 写路径的取舍：异常 / 中断只发生 trap 侧写入（异常指令与被中断的指令都不提交，
或提交的那条 `is_csr = 0`）；MRET 只执行 `mret_update`；MISPREDICT 两条都不写；
正常提交 CSR 指令只执行 `arch_csr_write`。

## ④ data path

### 1. `csr_inflight_tag` / 架构寄存器组

```text
set 输入端口            → tracker            self_tag[0] → csr_inflight_tag
arch_csr_write 输入端口 → CSR[csr_addr]      csr_wdata            （单写口）
trap 输入端口           → mepc / mcause / mtval  epc / cause / tval
顶层电平                → mip 的外部中断位     不落盘，直接参与 C 的组合
CSR[csr_addr]          → 读出端口            旧值                 （1 读口）
mepc / interrupt_cause → 读出端口            见 ⑥ 的 Static Info
```

clear 与 flush 只写 `valid ← 0`，载荷宽度为零，不构成运值边。

### 2. `trap_vector` / `interrupt_pending` / `interrupt_cause`(output)

```text
trap_vector(cause, is_interrupt) =
    (mtvec.MODE == VECTORED) ∧ is_interrupt ? {mtvec.BASE, 2'b00} + (cause << 2)
                                            : {mtvec.BASE, 2'b00}

interrupt_pending = mstatus.MIE ∧ |(mie & mip)
interrupt_cause   = priority_encode(mie & mip)        // MEI > MSI > MTI
```

`interrupt_pending` 是**已经综合完**的一根线，消费者直接用，**不再自行组合**
`mie` / `mip` / `mstatus.MIE`。

## ⑤ data structure（schema + 字段三角色）

### A. 串行化 tracker

- **state**：`csr_inflight_valid`
- **header**：`csr_inflight_tag`——`set` 写入即定；`clear` 时与 `commit_tag` 核对
- **payload**：**无**

### B. 架构态

- **state**：`current_priv`
- **header**：`mstatus`（MIE / MPIE / MPP）、`mie`、`mip`、`mtvec`——
  被本模块的派生逻辑当谓词读
- **payload**：`mepc`、`mcause`、`mtval`、`mscratch`、`CSR[csr_addr]` 的读写值——
  本模块不对它们求任何谓词，只存与转发

> **待补**：支持 F/D 还需要 `fcsr`（含 `frm` / `fflags`）与 `mstatus.FS`，
> 两者当前都不在上面的清单里。`fflags` 的回写路径同样缺失。

## ⑥ 接口

**in-event** `→ csr_control`

- set（Transaction ×1；ready = `!csr_inflight_valid`，已被上游吸收）
  - move；`self_tag[0]`(4) —— 存入 `csr_inflight_tag`
    - 触发；`set`(1) —— 单线使能，tracker 置位

- clear（announce ×1；门控契约见 ③）
  - broadcast；`commit_tag[k]`(4，k∈{0,1}) —— 与 `csr_inflight_tag` 比对，不留存
    - 触发；`csr_clear`(1) —— 本拍要不要清 tracker

- `arch_csr_write`（announce ×1，**单写口**）
  - move；`csr_wdata`(64) —— 写进 `CSR[csr_addr]`
    - 地址；`csr_addr`(12) —— 写哪个架构 CSR
    - 触发；`arch_csr_write`(1) —— 单线使能

- `trap_entry` / `mret_update`（announce ×1）
  - move；`epc`(64)、`cause`、`tval` —— 分别写进 `mepc` / `mcause` / `mtval`
      （`mret_update` 下本模块不采样这三个）
    - 选通；`kind`(2) —— 选 `trap_entry` 还是 `mret_update` 这条更新路径；
      本模块既不存它也不算它
    - 触发；`valid`(1) —— 本拍要不要更新架构态

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，只清 tracker，架构 CSR 不动，无载荷

- 组合读(in)
  - broadcast；`mip` 的外部中断位 —— 顶层电平直驱，**无 fire**，不存进本模块
    - broadcast；`cause` —— 本模块 `trap_vector` 读口的入参，在 `(cause << 2)` 里被算
    - 选通；`is_interrupt`(1) —— `trap_vector` 的第二个入参，选 vectored 还是 direct
    - 地址；`csr_addr`(12) —— CSR 软件读口选中哪个寄存器

**out-event** `csr_control →`

- 组合读(out)；`CSR[csr_addr]`(64) 旧值
- 组合读(out)；`trap_vector(cause, is_interrupt)`(64) —— 带外部参数，故不入 Static Info

**Static Info：**

无 fire、无外部参数，由自身状态导出：

- `csr_inflight_valid`(1) —— tracker state 本体
- `interrupt_pending`(1) —— `mstatus.MIE` / `mie` / `mip` 的组合投影，
  **含顶层直驱的外部电平 `mip`**
- `interrupt_cause` —— `priority_encode(mie & mip)`，同样**含 `mip`**
- `mepc`(64) —— 架构寄存器本体，按名读、无地址。
  **与按 tag 索引表给出的 `trap_epc` 同名不同物**
