# IB · 8 slot FIFO（指令缓冲）

### ① per-entry state

`IDLE / RESIDENT`

### ② state transition & condition（event 名）

- IDLE → RESIDENT：enqueue
- RESIDENT → IDLE：dequeue
- ANY → IDLE：flush

### ③ condition 细化

- **enqueue**：**采样约定——含同拍 dequeue 释放的空位**

```text
free_slot        = 8 - (valid_count - deq_count)            // 含同拍 dequeue
accepted_slot[0] = fe_valid[0] ∧ (free_slot >= 1) ∧ !global_flush_late
accepted_slot[1] = fe_valid[1] ∧ accepted_slot[0] ∧ (free_slot >= 2) ∧ !global_flush_late
enq_count        = accepted_slot[0] + accepted_slot[1]      // wptr += enq_count
```

- `fe_valid` 须满足 `fe_valid[1] ⇒ fe_valid[0]`（两位前缀 valid）
- `accepted_slot` 合法取值 `00 / 01 / 11`——**`10` 非法**
- **上一拍满、本拍出队 2 条时，本拍即可收 2 条**，不吃气泡。
  拿拍初余量去限流等于白丢一个周期
- `free_slot` 是**本模块的内部量，不导出**。FE 不需要、也不应当知道本模块还剩几格：
  它只管把手上有的摆上总线，读回 `accepted_slot` 再滑窗（见下）

**这条口径的代价**：`deq_count` 来自 `ib_dequeue[s]` = dispatch 的 `accept[s]`，
而 `accept[s]` 经 `isq_free_for_dispatch`（含同拍 issue）依赖各 FU 的 `FU_ready`。
于是 `FU_ready → accept → deq_count → free_slot → accepted_slot` 成为一条
**穿到 FE 接口的组合路径**，时序收敛时须重点核。

**无环**：`deq_count` 只依赖本模块**拍初**的 `inst_valid`（由 `valid_count` 投影），
不依赖本拍的 `enq_count`，故 enqueue 与 dequeue 之间不构成环。

**同格读写安全**：满队列同拍收发时，写入的目标格正是本拍被读出的队头格。
队头输出是**持续组合值**、本拍已被下游取走，边沿写入不破坏该次读出。

非 flush 拍，FE 必须保留未接受候选的有序后缀，并在下一拍将其
压缩到候选序列前缀重新提交，payload 与程序顺序保持不变。
例如 `fe_valid=11`、`accepted_slot=01` 时，原 slot1 必须在下一拍
作为新的 slot0 重新提交。

flush 拍 `accepted_slot=00`；redirect 取消上述保持义务，旧路径候选
丢弃，FE 从 `redirect_pc` 重新取指。

- **dequeue[s]** = `inst_valid[s]` ∧ `ib_dequeue[s]`

```text
inst_valid[0] = (valid_count >= 1)
inst_valid[1] = (valid_count >= 2)        // inst_valid[1] ⇒ inst_valid[0]
deq_count     = dequeue[0] + dequeue[1]     // rptr += deq_count
```
- `valid_count = (wptr - rptr) mod 16`，两个指针都是拍初寄存值，
  故其差值就是**拍初**已占用条数；次态 `valid_count = valid_count + enq_count - deq_count`
- `ib_dequeue[1] ⇒ ib_dequeue[0]`，故 dequeue 集合只能是 `00 / 01 / 11`，连续队头不跳过 slot0
- 队头两个 slot 对应 `rptr` 与 `rptr + 1` 的连续 entry

- **flush** = `global_flush_late`：优先级最高，`accepted_slot = 00`、`ib_dequeue = 00`，
  指针复位（含 loopbit）且次态 `valid_count = 0`
- 非 flush 拍按 enqueue / dequeue 的净变化更新 `valid_count`

### ④ data path

端点为**输入端口 / entry / 输出端口**三者。

#### 1. `entry.IB_Payload`

```text
enqueue 输入端口 → entry[wptr + n]    整条 IB_Payload
entry            → 队头输出端口        整条 IB_Payload（队头 2 slot 持续输出）
```

- 队头输出是**持续组合候选值**，不由 `dequeue` 选通；`dequeue` 只推进 `rptr`

#### 2. `inst_valid[1:0]` / `accepted_slot[1:0]`(output)

```text
inst_valid[1:0]    ← ③
accepted_slot[1:0] ← ③ 的接受判定
free_slot             ← 内部量，见 ③；**不导出**
```

### ⑤ data structure（schema + 字段三角色）

- **state**：`IDLE / RESIDENT`，压缩进 `wptr` / `rptr`
  - 压缩进两个 4-bit 指针 `wptr` / `rptr` = `{loopbit, index[2:0]}`：
  低 3 bit 是 8 个 entry 的地址，高 1 bit 是环绕标志。per-entry valid 是区间**解码投影**
  - 逻辑有效区间 `[rptr, wptr)`；entry 不跳洞、不重排
- **header**：**无**——本模块不对 entry 内容做任何判断
- **payload**：整条 `IB_Payload`，`enqueue` 写入、原样进原样出：

```text
pc、inst_bits、is_compressed、is_serial、is_fp_instruction、
rs1/2/3_idx、use_rs1/2/3、rs1/2/3_is_fp、
rd_idx、use_rd、rd_is_fp、is_store、mem_funct3、
imm_valid、imm_data、pred_taken、pred_target_pc、
exe_subop(24)、full_decode(17)
```

按现有字段宽度，`IB_Payload` 总逻辑宽度为 **302 bit**；本文件不规定 packed 字段顺序。

- `exe_subop[23:0]` 是 decode 后的具体指令 ID，编码为
  `{format[1:0], opcode_or_op[6:0], funct3[2:0], high_fixed[11:0]}`；
  `format=01` 为普通 32-bit，`format=10` 为 RVC。FP `.S/.D` 的精度已经由
  subop 的固定高位区分。
- `full_decode[16:0]` 编码为 `{csr_write_intent, illegal, rm[2:0], csr_addr[11:0]}`。
  `illegal=1` 时使用 `SUBOP_INVALID` 兜底并由 dispatch 固定送 G0 BRU/ILLEGAL；
  有效指令的 `illegal=0`。`rm` 与 `csr_addr` 只在适用指令上解释。
- `dispatch_route_class` 是 dispatch 的内部分类量，不再进入 IB payload。dispatch 根据 `exe_subop`（以及
  `full_decode.illegal`）在本地分类：ALU 为 `{G0,G1}` 动态二选一，
  `BRU/CSR/DIV/MUL/FPU/LSU` 分别固定到 `G0/G0/G0/G1/G2/G3`。
  **MRET** 属 BRU 类并由 `is_serial` 独立标注；`ILLEGAL` 固定走 BRU。
- `FU_Group` 不经过 IB：dispatch 从 `exe_subop` 导出 2-bit `slot_FU_Group`，
  再由装配逻辑写入 ISQ payload。它是**组内 FU 索引**（ALU 为 0，CSR/DIV/MUL
  分别为 1/2/1，BRU（含 MRET）/FPU/LSU 为 0），**不是全局组编号**
- `is_serial` 覆盖四类：**CSR 指令（CSRRW/S/C 及立即数型）、MRET、
  `FENCE` / `FENCE.I`、以及全部 22 条原子指令（LR / SC / AMO）**。
  前两类是因为要读写架构状态，后两类是因为要在访存序上取得"更早的访存已全部退休"
  这个结构性前提。`ECALL` / `EBREAK` / `WFI` **不在其中**
- `is_compressed` 标记本条是不是压缩指令，**只有 BRU 用**：链接地址与分支
  fall-through 目标要按指令长度算（压缩取 `pc + 2`、否则 `pc + 4`）。
  它是所有指令都有、单一消费者的通用属性，故与 `pc` 同类单列，**不进子码段**
- `inst_bits`(32) 是**本条指令的原始编码**，与 `pc` 同属"指令身份"、随指令走。
  压缩指令只用低 16 位、高位置零，由 `is_compressed` 指明有效宽度。
  唯一消费者是 G0 的 ILLEGAL 子码：非法指令的 `tval` 要写出错指令的编码，
  该值只能从这里取——`imm_data` 装的是**已译码的立即数**，不保证是原始编码，
  压缩指令的 16 位编码更与立即数无对应关系，故不复用那条通道
- `mem_funct3` 是**访存类型**，同时承载宽度、符号扩展与 FP 三件事，load 与 store 共用。
  load 侧七种取值装不进 2 bit，故为 3 bit；名字取自它的编码来源，不另起名
- `full_decode.rm` 是 **FP 专有**的舍入模式字段；FP `.S/.D` 精度由 `exe_subop` 区分。
- `full_decode.csr_addr` 指定 CSR 指令访问的寄存器。立即数型的 `uimm` 占着 `imm` 通道，
  两者同拍在场，故不能合用一条通道
- **系统指令五条的译码属性**（`ECALL` / `EBREAK` / `WFI` / `FENCE` / `FENCE.I`）：

```text
ECALL    G0 · SYS    use_rs/rd = 0   is_serial = 0   完成时 exception_flag=1, cause=11, tval=0
EBREAK   G0 · SYS    use_rs/rd = 0   is_serial = 0   完成时 exception_flag=1, cause=3,  tval=0
WFI      G0 · SYS    use_rs/rd = 0   is_serial = 0   完成时无异常、无 rd —— 实现为 NOP
FENCE    G3 · FENCE  use_rs/rd = 0   is_serial = 1   LSU 屏障，见下
FENCE.I  G3 · FENCE  use_rs/rd = 0   is_serial = 1   LSU 屏障 + 退休侧重取，见下
```

  `ECALL` / `EBREAK` 与 ILLEGAL 共用 G0 的 requester 0 与同一条异常完成路径，
  **只有 cause 不同**——三者都是"无源操作数、不写 rd、效应全在退休侧"的同形指令。
  `is_serial = 0` 的理由与 ILLEGAL 相同：顺序由按序退休保证，不需要派遣期独占。

  `FENCE` / `FENCE.I` **必须 `is_serial = 1`**：有 store buffer 时 FENCE 不能是 NOP，
  它要等更早的访存与 store drain 全部可见；串行化让"更早的访存已全部退休"成为结构性事实，
  LSU 侧的屏障退化成"排空自己的 store buffer"。`FENCE.I` 额外要求前序代码 store 已可见，
  再在按序退休时发 `FENCE_I` 恢复事件（宿主见 [[flush_model微架构文档.md]] ④）。

- **原子指令的译码属性**（`LR` / `SC` / 9 种 `AMO`，各 `.W`/`.D`，共 22 条）：

```text
G3 · ATOMIC   is_serial = 1   is_store = 0   use_rd = 1
              rs1 = 地址；AMO/SC 另用 rs2 = 操作数 / 写数据；imm 恒 0（原子指令无 offset）
              mem_funct3 只承载宽度（.W / .D）；op 由 exe_subop 唯一解码
              aq / rl 一律按 1 实现（全 acquire+release），不进 payload —— 见 ⑤ 末的架构决策
```

  **`is_store = 0` 是刻意的**：`is_store` 专指"走 SCB drain 子流程的普通缓冲 store"。
  原子指令不走 `store_drain_req` / `store_done`，它们的 `exec_done` 直接意味着
  **不可回滚的原子事务已经完成**，按普通完成项按序提交。
  **`is_serial = 1` 是 A 扩展的正确性依据**，不是性能取舍：串行化让原子指令发射时
  机器里没有别的指令，写内存因而非投机，且更早的 store 必然已经落内存。
  理由链见 `../../walkthrough.md` §1.19。

- **真正非法的指令**仍走 ILLEGAL 兜底——**不能只写"trap"**。
  非法指令一旦被接受就占住一个 tag，而 `exec_done` 只能由完成 lane 置位；
  若没有任何 FU 为它发 `Result_valid`，队头就永远等不到 `exec_done`，按序退休直接卡死。
  所以兜底路径必须是一条**可发射、可完成**的指令，即 **ILLEGAL** 子码：

```text
dispatch_route_class = BRU 固定 G0；不能用 ALU（动态类会落到 G1，而 G1 发不出异常）
FU_Group    = 0            与 ALU0/BRU、MRET 共用 requester 0，不新增第四个 requester
子码        = ILLEGAL      非法指令兜底；cause 由子码硬编码，不进 payload
use_rs1/2/3 = 0            无源操作数 ⇒ 进 ISQ_G0 后立即可发射，不会因等操作数卡住
use_rd      = 0            不写目的寄存器，也就不进任何 tag_mapping
is_serial   = 0            它不读写架构状态，效应全在退休侧的 EXCEPTION flush；
                           顺序由按序退休保证，不需要派遣期独占
                           （MRET 之所以串行，是因为它读架构 mepc 作恢复 PC，不是因为"会 flush"）
lane 0 完成  exception_flag = 1、cause = 非法指令(2)
             tval = 普通指令 inst_bits(32)；压缩指令 {48'b0, inst_bits[15:0]}
```

  译码期只负责判定"它是非法的"，**不产生任何异常效应**；异常在退休拍按序发生。
  ILLEGAL 的完成同样会上 bypass 广播，但 `use_rd = 0` ⇒ 它没在任何 tag_mapping 里留过映射
  ⇒ 不可能有 ISQ entry 在等这个 tag，广播无消费者，无害。
  **被静态配置关掉的扩展也走这条路**：`ENABLE_A = 0` 时的原子子码、`ENABLE_C = 0` 时的
  `SUBOP_C_*`，decode 一律置 `illegal = 1`，从而正确报 cause 2。
  **不能改用 `subop_supported_now = 0`**——那条的后果是"不得 `accept`"，
  该 slot 会永远停在队头，是挂死不是陷入。
  全库的 cause 号段与各自的 `tval` 口径见 `../../异常与trap语义.md`

### ⑥ 接口

**in-event** `→ IB`

- enqueue（Transaction，**2 写口**；ready 由本模块回送的
  `accepted_slot[n]` 承担，见 ③）
    - move；`IB_Payload[n]`(整条，n∈{0,1}) —— 存进 `entry[wptr + n]`
    - 触发；`fe_valid[n]`(1，n∈{0,1}) —— 本拍 FE 给几条（两位前缀），决定写几格

- ib_dequeue（Transaction，两位前缀单向选通，per slot；
  ready 已被对端吸收，本模块不重组第二份握手）
    - 触发；`ib_dequeue[s]`(1，s∈{0,1}) —— per slot 使能，推进 `rptr`，无载荷

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，指针复位（含 loopbit），无载荷

**out-event** `IB →`

- 组合读(out)；队头 2 slot 的整条 `IB_Payload`（字段清单见 ⑤）
- 组合读(out)；`inst_valid[1:0]`(2)
- 组合读(out)；`accepted_slot[1:0]`(2) —— 回压回送，见 ③ 的契约

**Static Info**

无。

> `free_slot` 曾作为 Static Info 导出给 FE，**已删**。FE 不需要知道本模块还剩几格——
> 它盲发、读回 `accepted_slot` 再滑窗即可。理由见 `../../walkthrough.md` §1.29。
