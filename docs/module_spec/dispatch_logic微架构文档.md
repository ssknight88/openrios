# dispatch_logic

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. Slot选择ISQ_Group：`slot_ISQGroup[0/1]`

**第一步 · `exe_subop` 分类**——`dispatch_route_class` 是 dispatch 的内部中间量，
由 `exe_subop[23:0]` 和 `full_decode.illegal` 生成，不进入 IB payload。
`FU_Group` 只是组内 FU 编号（ALU/BRU/FPU/LSU 全是 0），**不能当选组的选择子**。

分类依据为用户补充 `subop/exe_subop_pkg.sv` 的具体 subop 集合；先生成
`subop_supported_now`，再生成 `dispatch_route_class`。`illegal=1` 优先作为可完成的
ILLEGAL 指令固定归 BRU/G0；仅当 `illegal=0` 时，`SUBOP_INVALID` 或未被当前集合
覆盖的 `exe_subop` 才令 `subop_supported_now = 0`，不得分配 group、不得 `accept`。

**扩展的启用/禁用门控不在本模块，在 decode**——静态配置 `ENABLE_A` / `ENABLE_C`
为 0 时，decode 对相应子码置 `illegal = 1`：

```text
ENABLE_A = 0  ⇒  decode 对 is_g3_atomic_subop 全体置 illegal = 1
ENABLE_C = 0  ⇒  decode 对全部 SUBOP_C_* 置 illegal = 1
```

**FP 指令的动态非法检查也在本模块**——decode 看不到架构状态，只能拦静态保留值：

```text
frm_illegal = (frm > 3'b100)          // frm 只允许 000..100；101/110/111 都不是有效模式

rm_illegal  = uses_rm(exe_subop)
              ∧ ( rm == 3'b101 ∨ rm == 3'b110 ∨ (rm == 3'b111 ∧ frm_illegal) )

fp_illegal  = is_fp_instruction ∧ ( !fs_enabled ∨ rm_illegal )

illegal_effective = full_decode.illegal ∨ fp_illegal
```

`illegal_effective` 取代原来的 `full_decode.illegal` 参与分类：命中即固定送 G0 的
ILLEGAL 完成路径，`tval` 取 `inst_bits`（G0 本来就存）。

**三条容易写错的**：

- **`uses_rm` 必须由 `exe_subop` 静态分类，不能对所有 FP 指令盲查 `rm`**。
  算术类（FADD/FSUB/FMUL/FDIV/FSQRT、四条 FMADD 族）与转换类（FCVT.*）用舍入模式；
  **符号注入 FSGNJ*、最值 FMIN/FMAX、比较 FEQ/FLT/FLE、分类 FCLASS、搬移 FMV.* 都不用**——
  它们编码里那三位是别的意思，盲查会把合法指令判成非法
- **`frm == 3'b111` 同样非法**。`rm = DYN` 是让 FPU 去取 `frm`，而 `frm` 自己取 111 时
  解不出有效模式，不是"再动态一次"
- **`is_fp_instruction` 覆盖 G3 的 `FLW`/`FLD`/`FSW`/`FSD`**，不能用 `rd_is_fp` 代替
  （FP store 不写 rd）。`FS == Off` 时 FP load/store 同样非法

**为什么放在派遣侧而不是让 G2 发异常**：G2 的事件字段因此可以继续恒 0、lane 2 契约一字不改；
`ISQ_Group2` 不必增存 `inst_bits`（而 `tval` 要写指令编码）；复用一条已经核过的异常路径。
理由链见 `../../walkthrough.md` §1.22。

**在派遣拍读架构状态为什么安全**：`FS` 与 `frm` **只可能在退休窗口空时改变**——
改它们的只有 CSR 指令（`is_serial`）与 trap/mret（随 flush 清窗）；
提交拍的 `fflags_accrue` 只做 `→ Dirty`，**既造不出假的 `FS == Off`、也解不掉真的**。
所以一条 FP 指令派遣时读到的值，与它退休时的值必然相同。

**`effective_rm` 在本模块定格**：

```text
effective_rm = (rm == 3'b111) ? frm : rm      // 只对送往 G2 的指令有意义
```

送进 ISQ_G2 的 payload，**FPU 不再读实时 `frm`**。快照比实时读稳健：G2 entry 可能驻留多拍，
而快照把"用哪个舍入模式"钉死在派遣拍——那一拍的值经上面的论证是确定的。

**必须走 `illegal` 而不是 `subop_supported_now`**：后者的后果是"不得 `accept`"，
该 slot 会**永远停在队头等下去**——这是挂死，不是陷入。RISC-V 要求未实现的指令
报非法指令异常，只有 `illegal = 1` 的 ILLEGAL 完成路径能做到。
`subop_supported_now = 0` 只保留给 `SUBOP_INVALID` 与真正未被任何集合覆盖的编码，
是"decode 出错"的兜底，正常运行中不该命中。

`ENABLE_*` 同时驱动 `misa`、库外的 FE / LSU 与 decode，三者必须同源；
翻位的前置条件见 `../../异常与trap语义.md` §6，本模块不重复。

```text
ALU         见下：分「可分流」与「G0-only」两档          FU_Group = 0
BRU         slot_ISQGroup = G0                          FU_Group = 0
CSR         slot_ISQGroup = G0                          FU_Group = 1
DIV         slot_ISQGroup = G0                          FU_Group = 2
MUL         slot_ISQGroup = G1                          FU_Group = 1
FPU         slot_ISQGroup = G2                          FU_Group = 0
LSU         slot_ISQGroup = G3                          FU_Group = 0
ATOMIC      slot_ISQGroup = G3                          FU_Group = 0
FENCE       slot_ISQGroup = G3                          FU_Group = 0
SYS         slot_ISQGroup = G0                          FU_Group = 0
```

后三类是本次补全新增的分类，各自的 subop 集合：

```text
ATOMIC   is_g3_atomic_subop     LR / SC / 9 种 AMO，各 .W/.D，共 22 条
FENCE    is_g3_fence_subop      FENCE / FENCE.I
SYS      is_g0_sys_subop        ECALL / EBREAK / WFI
```

**`FETCH_FAULT` 子码与 `ILLEGAL` 归同一档**——`dispatch_route_class = BRU`、固定 G0、
requester 0、无源操作数、不写 rd、不串行。两者唯二的不同在 FU 侧（cause 1 vs 2、
`tval` 取 `pc` vs `inst_bits`），**对本模块完全同形，不另立分类**。
`illegal_effective` 不覆盖它——取指故障不是"非法指令"，它有自己的 cause。

`ATOMIC` 与 `FENCE` 落 G3 是因为它们都是访存序上的操作，只有 LSU 能执行；
`SYS` 落 G0 是因为 ECALL / EBREAK 与 ILLEGAL 同形——共用 G0 的 requester 0 与同一条异常
完成路径，只是 cause 不同。**它们必须固定分组，不能进 ALU 那档动态分流：
G1 一条异常也产生不了**（G1 的完成事件字段恒 0）。
`FENCE.I` 虽属 `is_g3_fence_subop`，但它的重取效应在退休侧，见 `flush_model` 的 `FENCE_I`。

**`ATOMIC` 与 `FENCE` 到达本模块时 `is_serial = 1`**（由 decode 置、经 IB 送来，
本模块只消费不生成）。本模块 ④#2 的 `serial0_ok = !serial0 ∨ buffer_empty` 因此
自动保证这两类**在退休窗口全空时才派遣**，且 `serial_inflight_valid` 挡死更年轻的派遣。

这一条是 A 扩展正确性的**结构性依据**，不是性能取舍：原子指令发射时机器里没有别的指令，
所以它在执行拍写内存是**非投机**的；更早的 store 也必然已经 drain 完毕，
LSU 不需要为原子指令做 store-buffer forwarding。理由链见 `../../walkthrough.md` §1.19。

**ALU 类不是整类可分流**。能否迁到 G1 由 `exe_subop` 本身决定：

```text
alu_g1_capable = is_g1_alu1_subop(exe_subop)     // 包提供的集合

alu_g1_capable = 1   可分流：slot_ISQGroup ∈ {G0, G1}
alu_g1_capable = 0   G0-only：slot_ISQGroup = G0
```

**`AUIPC` 属 G0-only**——它要算 `pc + imm`，而 PC 只在 G0 侧可得
（`ISQ_Group1` 的「本组不存的字段」明确丢弃 `pc`）。包里 `is_g0_alu0_subop` 含
`SUBOP_AUIPC`、`is_g1_alu1_subop` 不含，两档划分与包一致，本表不另立名单。
`LUI` 两个集合都在，属可分流。

`dispatch_route_class` 与 `alu_g1_capable` 只在本模块内部存在；
`slot_ISQGroup` 仍由第二步结合 ISQ 空闲状态决定。

`slot_FU_Group[s]` 也由同一分类表导出，供集成层 §2.1 装配 ISQ payload：

```text
ALU / BRU / FPU / LSU / ILLEGAL  -> 0
ATOMIC / FENCE / SYS             -> 0
CSR                              -> 1
DIV                              -> 2
MUL                              -> 1
```

它是 2-bit 的组内 FU 索引；当 `subop_supported_now = 0` 时其值无效，因为该 slot 不会 `accept`。

**`is_fence_i[s]` 也由同一分类导出**，送 `CompletionScoreboard` 的 alloc 批：

```text
is_fence_i[s] = (exe_subop[s] == SUBOP_FENCEI)
```

**为什么由本模块导出而不进 IB payload**：它是 `exe_subop` 的**纯函数**，
按 §1.8 对 `FU_Group` 的同一条先例——纯函数再走一遍 payload 是冗余。

**SCB 拿它干什么**：判定链第 5 步靠它认出"队头是 FENCE.I，要提交后 flush"。
SCB 能触发 flush 的谓词只有 exception / mispredict / is_mret / 外部中断四个，
**一个都不匹配 FENCE.I**；没有这一位，FENCE.I 会落到第 6 步「其余，正常提交」，
**flush 与重取根本不会发生**。
`ATOMIC` / `FENCE` 与 `LSU` 同组同索引——G3 组内只有 LSU 一个 FU，三类共用它；
`SYS` 与 `BRU` / `ILLEGAL` 共用 G0 的 requester 0，**不新增第四个 requester**。

**第二步 · 选组**——两条 slot 各一行，无函数抽象

```text
slot_ISQGroup[0] = (dispatch_route_class[0] == ALU ∧ alu_g1_capable[0])
                     ? (isq_free_for_dispatch[G0] ? G0 : G1)
                     : 第一步表中的固定组      // 含 ALU 的 G0-only 档（AUIPC 等）

slot0_takes_G0   = slot0_fire_candidate ∧ (slot_ISQGroup[0] == G0)
                   // 当拍 ISQ_G0 还空着，但 slot0 本拍将写入；
                   // slot0 发不出去（candidate=0）就不算占

slot_ISQGroup[1] = (dispatch_route_class[1] == ALU ∧ alu_g1_capable[1])
                     ? ((isq_free_for_dispatch[G0] ∧ !slot0_takes_G0) ? G0 : G1)
                     : 第一步表中的固定组      // 含 ALU 的 G0-only 档

groups_distinct  = (slot_ISQGroup[1] != slot_ISQGroup[0])
```

**分工**：选组只回答"该去哪"，永远给出确定编号——可分流 ALU 在 G0/G1 **都满时照样报 G1**，
撞组由 `groups_distinct` 阻拦。G0-only 档（含 AUIPC）永远报 G0，两条 slot 同为 G0-only 时
`groups_distinct = 0`，slot1 本拍不被接受、留到下一拍。

#### 2. `accept[0]` / `accept[1]`(output)

```text
serial0_ok = !serial0 ∨ buffer_empty

slot0_guard_ok =
      subop_supported_now[0]
    ∧ can_alloc_1
    ∧ isq_free_for_dispatch[slot_ISQGroup[0]]
    ∧ !serial_inflight_valid
    ∧ serial0_ok
    ∧ !slot_missed_wakeup[0]
    ∧ !global_flush_late

slot0_fire_candidate = slot0_present ∧ slot0_guard_ok
accept[0]            = slot0_fire_candidate

slot1_guard_ok =
      subop_supported_now[1]
    ∧ can_alloc_2
    ∧ isq_free_for_dispatch[slot_ISQGroup[1]]
    ∧ groups_distinct
    ∧ !(fp0 ∧ fp1)
    ∧ !serial_inst
    ∧ !slot_missed_wakeup[1]
    ∧ !global_flush_late

accept[1] = accept[0] ∧ slot1_present ∧ slot1_guard_ok
```

- **双FP指令阻塞**：`slot1_guard_ok` 中的 `!(fp0 ∧ fp1)` 即双FP指令阻塞（同拍两 slot 不得同时为 FP）
- 由定义得 **`accept[1] ⇒ accept[0]`**，故 `10` 这种接受组合被结构排除；
  `accept[0] = 0` 时 slot1 的 group、源解析结果与 payload 即使有组合值也不形成任何状态更新
- `can_alloc_1` / `can_alloc_2` / `buffer_empty` 是
  CompletionScoreboard 的**拍初值**；`isq_free_for_dispatch` **含同拍 `issue`**

- `global_flush_late` 只屏蔽当拍新 fire，本模块不保存 flush 状态
- `serial0_ok` / `slot0_guard_ok` / `slot1_guard_ok` / `slot0_fire_candidate` /
  `slot_ISQGroup` / `groups_distinct` 全部是内部中间量，无跨界消费者

#### 3. `select_payload[G0..G3][0/1]`(output)

```text
select_payload[g][0] = accept[0] ∧ (slot_ISQGroup[0] == g)
select_payload[g][1] = accept[1] ∧ (slot_ISQGroup[1] == g)
```

`select_payload` 是**有效候选选择**，不是仅路由选择。`00` 表示本拍没有被接受、
送往该组的候选；因此对端 mux 输出全零。`accept[1]` 已包含 `groups_distinct`，
不在此处重复门控。

#### 4. `ib_dequeue[s]` / `isq_wr_en[g]` / `serial_set`(output)

```text
ib_dequeue[s] = accept[s]
isq_wr_en[g]  = select_payload[g][0] ∨ select_payload[g][1]
serial_set    = accept[0] ∧ serial0
```

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ dispatch_logic`

- 组合读(in)
    - broadcast；`slot0_present`(1)、`slot1_present`(1)、`serial0`(1)、`serial_inst`(1)、
      `fp0`(1)、`fp1`(1)、`slot_missed_wakeup[0/1]`(1×2) —— 全部进 ④#2 的准入 guard
    - broadcast；`exe_subop[0/1]`(24×2)、`full_decode.illegal[0/1]`(1×2) ——
      生成内部 `subop_supported_now` / `dispatch_route_class` / `alu_g1_capable`，
      再执行第二步选组
    - broadcast；`is_fp_instruction[0/1]`(1×2)、`full_decode.rm[0/1]`(3×2) ——
      进 ④#1 的 `fp_illegal` 与 `effective_rm`
    - broadcast；`fs_enabled`(1)、`frm`(3) —— 架构状态，来自
      [[system_instruction_handler微架构文档.md]]；只在派遣拍采样，不留存。
      `fs_enabled` = (`mstatus.FS != Off`)
    - broadcast；`can_alloc_1`(1)、`can_alloc_2`(1)、`buffer_empty`(1)（**拍初值**）
    - broadcast；`isq_free_for_dispatch[G0..G3]`(1×4)（**含同拍 issue**）
    - broadcast；`serial_inflight_valid`(1) —— 串行指令在飞时全部stall
    - broadcast；`self_tag[0]`(4) 仅作为 `serial_set` 的 payload

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，本拍屏蔽全部 accept

**out-event** `dispatch_logic →`

- `accept[s]`；`accept[s]`(1×2)
- `ib_dequeue[s]`；`ib_dequeue[s]`(1×2)
- `isq_wr_en[g]`；`isq_wr_en[g]`(1×4)
- 组合读(out)；`slot_FU_Group[0/1]`(2×2) —— 对端 §2.1 ISQ_Payload 装配
- 组合读(out)；`effective_rm[0/1]`(3×2) —— 对端 §2.1 装配，覆写 payload 的 `rm` 字段；
  只有 G2 消费
- 组合读(out)；`is_fence_i[0/1]`(1×2) —— 对端 CompletionScoreboard 的 alloc 批，
  随 `accept[s]` 同拍写进 `entry[self_tag[s]]`
- `serial_set`；`serial_set`(1)、`self_tag[0]`(4) —— 本模块产生 trigger，转发该 tag 给
  SerialInstructionTracker
- 组合读(out)；`select_payload[G0..G3][0/1]`(1×8) —— 对端 p1_ISQ_input_mux ×4

**Static Info**

无。
