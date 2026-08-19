# CompletionScoreboard · 裁决中枢 · 环指针 + 16 entry per-tag + 按序退休判定链

v2 把三样东西收进同一个退休权威：v1 CompletionScoreboard 的 per-tag 生命周期、
v1 commit_unit 的整条判定链、v1 Buffer 的控制侧（head/tail 指针、alloc 批、writeback 事件批）。
数据平面留在外面——`result_data` 在 [[Buffer微架构文档.md]]、`inst_pc` 在
[[PC_File微架构文档.md]]，三个 16 格阵列共用本模块 `tail` 的 4-bit tag 地址算术，
分配位置天然一致。

### ① per-entry state

`FREE / INFLIGHT / DONE / DRAINING / DRAINED`

- **valid 不逐格存**：`FREE / 非 FREE` 压缩进 `head` / `tail` 指针，per-entry valid 是
  `[head, tail)` 区间的**解码投影**。v1"乱序寻址，state 不可压缩"的论断只对 `exec_done` /
  drain 两位成立——valid 的置与清全部发生在按序端点（alloc@tail、commit@head、flush 指针落位），
  本就可压缩；v1 里 `headK_present ∧ scoreboard_valid_bits[headK_tag]` 的双重编码互检随之消失
- 逐格存三位：`exec_done` / `store_drain_requested` / `store_drain_done`——
  这三位才是乱序寻址的 per-entry FSM
- `head` / `tail` = **5-bit** `{loopbit, index[3:0]}`，与 [[IB微架构文档.md]] 的
  `wptr` / `rptr` 同款；指针加法按 mod32 自然回绕，**寻址与对外 tag 一律取 `index[3:0]`**
- CSR 写意图暂存 `csr_stage` **不在本模块**——已迁 [[system_instruction_handler微架构文档.md]]

### ② state transition & condition（event 名）

- FREE → INFLIGHT：alloc
- INFLIGHT → DONE：writeback（exec_done）
- DONE → DRAINING：drain_req（仅 store，判定链自产）
- DRAINING → DRAINED：drain_done
- DONE / DRAINED → FREE：commit（判定链自产）
- ANY → FREE：flush（判定链自产，指针落位）

### ③ condition 细化

- **alloc[s]** = `accept[s]` → `tail += 1/2`；`entry[self_tag[s]]` 写 alloc 批，
  并把 `exec_done` / drain 两位**清零**
    - 寻址 tag 与本模块 `tail` 同源（`self_tag[s] = tail + s`，由
      [[dependency_check微架构文档.md]] 导出，信号名沿用 `Buffer_tail`）
    - **alloc 拍清零是正确性义务**：flush 不清 per-tag 位（见下），复用格的旧位全靠这次清零
    - **采样约定**：`occupancy = tail - head`（0..16）、`can_alloc_1/2 = (16 - occupancy ≥ 1/2)`、
      `buffer_empty = (occupancy == 0)`——全部**拍初值**
      （v1 的 `rob_empty` 名字消亡，统一为 `buffer_empty`）
- **writeback** = `Result_valid[g]` ∧ `!global_flush_late` → `exec_done ← 1`，
  事件批与 `fpu_fflags` 写进 `entry[tag_out[g]]`（`fpu_fflags` 只 G2 非零，其余 lane 写 0）
    - **4 组并发、随机寻址**；四个 `tag_out` 属四个不同在飞 tag，地址正交
    - **store 的 `exec_done` 只表示 store buffer 收下了**，不代表已 drain、更不代表已退休
    - `!global_flush_late` 只盖 flush 当拍；**迟到完成由 FU flush 契约挡**
      （flush 拍 FU 作废在飞指令，此后不得对旧 tag 再发 `Result_valid`；
      该契约是 FU 自身的行为，归 FU 微架构文档）
- **drain_req** = 判定链第四步命中 → `entry[head0_tag].store_drain_requested ← 1`
    - 每拍至多一条，且只对队头最老那条发
- **drain_done** = `store_done_valid` ∧ 命中（活 tag、已请求、未完成）
  → `entry[store_done_tag].store_drain_done ← 1`
    - 判据统一为这一处（v1 commit_unit"与 head0_tag 比对"的说法与此等价——
      drain 请求只对 head0 发过）
- **commit** = 判定链结论（见 ④）→ `head += commit_count`；
  `[head, head+commit_count)` 的投影 valid 随指针前移自然清除
    - 本模块**自产自校**：v1"SCB 不校验被提交 tag 合法性、由判定链保证"的跨模块信任契约，
      合并后成为模块内不变量
- **flush** = 判定链产生 `flush_valid` → 同一时钟边界**严格按此次序**：

```text
head_new = head + commit_count      // 先落下当拍提交——"清除不是取消提交"
tail_new = head_new                 // 再回滚
// per-tag 三位不清：复用格由 alloc 清零；投影 valid 随指针落位自动归零
```

- 不产生独立 `serial_clear` 事件：SerialInstructionTracker 以 commit lanes 的 tag 比对重置
  （[[SerialInstructionTracker微架构文档.md]] ③）

### ④ data path

#### 1. 投影与聚合（output）

```text
scoreboard_valid_bits[t]      = t ∈ [head, tail)         解码投影，t ∈ {0..15}
scoreboard_exec_done_bits[t]  = entry[t].exec_done        存储位聚合
```

- `[head, tail)` 是**环形区间**——`head` / `tail` 是 5-bit 带 loopbit 的指针，
  区间跨回绕时（如 head.index = 14、tail.index = 2）有效 tag 仍是 {14, 15, 0, 1}。
  投影须按 5-bit 指针求，**不得退化为 4-bit 数值比较**，
  否则回绕与满窗都会被投影成空窗

#### 2. 队头资格中间量

```text
head0_tag     = head.index;   head1_tag = head.index + 1     // 4-bit mod16
headK_present = (occupancy ≥ K+1)
headK_valid   = headK_present                 // 投影下与 valid 位恒等，v1 的双重互检消失
headK_done    = headK_valid ∧ entry[headK_tag].exec_done
```

**采样约定**：`occupancy` 取**拍初值**。

#### 3. 判定链——一条链一次定出全部退休侧输出

**第一步 · head0 判定**（六个分支，自上而下首个命中者胜）

```text
1  !head0_valid ∨ !head0_done   提交 0，且【不评估 head1】
2  exception                    head0 不提交，从 head0 起 flush
3  store drain                  head0 是未 drain 的 store：发请求、提交 0、停在 head0
4  外部中断                      interrupt_pending 且在合格边界上可取时：
                                  可作废的 head0           提交 0，flush_tag = head0
                                  不可作废的 head0 且 head1_valid
                                                          只提交 head0，flush_tag = head1
                                  !head1_valid 时本步不命中，落到 5/6 按普通指令处理
5  FENCE.I / mispredict / MRET  head0 提交，然后 flush
                                 判据分别为 entry[head0].is_fence_i（alloc 批）/
                                 mispredict_flag / is_mret（事件批）
                                 kind 分别为 FENCE_I / MISPREDICT / MRET
6  其余                          正常提交 head0
```

**「不可作废」的判据**——head0 已产生**不可回滚的存储器副作用**：

```text
不可作废的 head0 = 已 drain 且**无故障**的 store
                 ∨ 已 exec_done 的原子指令（LR / SC / AMO，静态由 exe_subop 分类）
```

作废这样一条 head0 会让它在 handler 返回后**重新执行**，内存被改两次。
store 侧原本就有这条保护，本次补全把它推广成一个类别，**不是给原子指令开特例**。

`LR` 本身没有内存写，纳入这一类是为了让"原子指令"是一个整体、少一个例外；
过度保护的唯一后果是把中断推迟一拍，架构上永远合法。

**`!head1_valid` 时本步不命中 ⇒ 中断被推迟**，本拍 head0 照常提交，
下一拍以新的 head0 重新评估。中断没有时序义务，推迟合法；代价是当退休窗口只剩一条
不可作废指令时，中断要多等若干拍。想让中断永远即刻取，得让本模块直接输出
`trap_epc`（分三种情形算下一条架构可执行 PC），那需要 per-tag 存 `instr_len`。
**本次不做**，理由见 `../walkthrough.md` §1.20。

- **exception 排在 store drain 之前**——所以一条出错的 store 永远不会 drain
- **外部中断压过 head0 的 FENCE.I / mispredict / MRET**；**MRET 不是 exception**
- **`is_fence_i` 是本模块唯一的 flush 触发源里不来自事件批的那个。**
  没有它，FENCE.I 会落到第 6 步「其余，正常提交」——**flush 与重取根本不会发生**，
  那些在 I-cache 失效之前就取好的更年轻指令会继续执行，而它们可能是旧代码。
  这不是标注问题，是功能不发生
- **FENCE.I 不进第 4 步的"不可作废"类**：原子指令要保护是因为改了内存不可回滚；
  FENCE.I 什么也没改，被中断作废后重执行完全等价（LSU 侧的可见性工作是幂等的），
  且 `frontend_icache_invalidate` 由 `flush_model` 在提交拍产生，那一拍没发生就没清，
  不存在"清了却没重取"的中间态
- `interrupt_pending` 是 [[system_instruction_handler微架构文档.md]] **已综合完**的一根线，
  本模块直接用，**不再自行组合** `mie` / `mip` / `mstatus.MIE`

**第二步 · head1 判定**（只在 head0 正常提交后评估，**head1 永不越过 head0**）

```text
0  !head1_valid ∨ !head1_done   head1 不提交，且不读它的任何字段
1  is_store        head1 不提交。store 只能在 head0 位置走 drain 子流程
2  exception       head1 不提交，产生 EXCEPTION flush，flush_tag = head1_tag，commit_count = 1
3  mispredict      提交，然后 flush
4  其余             正常提交
```

**head1 不可能是串行指令**：串行指令要求派遣时窗口空，且被接受后挡死全部更年轻的派发
⇒ 它必然独占退休窗口 ⇒ `occupancy == 1` ⇒ `head1_valid == 0`。

**第三步 · 双FP提交阻塞**

最终提交集合若会产生两笔 `rd_write_enable ∧ rd_is_fp` 的写，**缩到 1 条**（head1 留到下一拍）。
这一条反过来是 FP 侧单写口 / 单清除口的依据。
**阻塞只能减提交条数**，不许丢掉一笔写、也不许提前 flush 来绕开它。

**第四步 · store drain 流程**

- 每拍至多一条 drain 请求，且**只有 head0 能发**
- head0 是 `exec_done` 且未请求的 store（`!entry[head0_tag].store_drain_requested`）
  → 发 1 拍脉冲，停在 head0
- `store_done` 命中且 **`store_done_exception = 0`** 时置完成位；此后该 store 可正常提交（**不写 ARF**）
- **更年轻的非 store 不得越过一条在等 `store_done` 的 head store**
- **drain 期故障**（`store_done_exception = 1`）：**不置完成位**，改为把
  `store_done_cause` / `store_done_tval` 写进该 tag 的**事件批**（与执行拍的异常写同一组字段）。

```text
store_done_exception = 1  ⇒  entry[store_done_tag].exception_flag ← 1
                             entry[store_done_tag].exception_cause ← store_done_cause
                             entry[store_done_tag].exception_tval  ← store_done_tval
```

  **不新增判定链分支**：下一拍第二步（exception）就把它当普通异常抓住——不提交、EXCEPTION flush。
  **也不会重发 drain**：第二步排在第三步之前，事件批一旦有异常，第三步永远到不了。
  **"不可作废"保护自动正确**：完成位没置 ⇒ 这条 store 不在受保护类别里，
  而它的写本来就没发生（LSU 侧契约：drain 期报故障时**不得修改内存**）。
  这是**事件批的第二个写者**——第一个是执行拍的 writeback，两者对同一 tag 严格先后，
  且 store_done 只可能把"无异常"升级为"有异常"，不存在竞争

**第五步 · 提交动作**

对每个有效 lane：按 `rd_write_enable` / `rd_is_fp`（从本表 alloc 批按 headK 读出）
选 INT/FP ARF 写；清目的 tag_mapping 对应格的 `busy`（要求该格 `tag == commit_tag[k]`）。
CSR 写意图的捕获与落笔在 [[system_instruction_handler微架构文档.md]]
（监听 lane 0 capture、commit lane tag 比对 apply），本模块不参与。

**判定结论**

```text
commit_valid[0] = head0 判定链允许本拍退休
commit_tag[0]   = commit_valid[0] ? head0_tag : 0
commit_valid[1] = head1 判定链允许本拍退休           // 前提：commit_valid[0] ∧ head1_valid ∧ head1_done
commit_tag[1]   = commit_valid[1] ? head1_tag : 0
commit_count    = commit_valid[0] + commit_valid[1]  // 0..2

store_drain_tag = head0_tag

flush_valid / flush_tag / recovery_kind              // 由判定链直接给出
recovery_kind(3)：0 = MISPREDICT  1 = EXCEPTION  2 = MRET  3 = INTERRUPT  4 = FENCE_I
同一分支内事件位并存时按 exception > MRET > FENCE_I > mispredict 取
```

`commit_valid[k]` / `commit_tag[k]` 由判定链内部形成，**不是任何上游给的输入**；
异常、store drain、mispredict、中断等分支只改变这两个 valid 的结果与 flush 输出，
**不另造第二套提交信号**。

#### 4. commit 事件的完整字段集

```text
per lane：  commit_valid[k]、commit_tag[k]、rd_idx[k]、rd_is_fp[k]、rd_write_enable[k]、
            commit_fflags[k]
非 per-lane：commit_count
数据：      commit_data[k] —— 不经本模块，由 Buffer 队头读口直接给出
            （本模块只供 head0_tag / head1_tag 作队头读地址；这对地址扇出给几个
              按 tag 索引的阵列，由集成层决定，不是本模块的事）
```

- `commit_fflags[k]` 从本表 writeback 批按 headK 读出，随 commit 事件送出；只 G2 非零
- `rd_*` 三样从本表 alloc 批按 headK 读出，随 commit 事件送 ARF 写口与重命名表清除口
  （修复 v1 commit_unit ⑥ 漏列 `rd_*` 的信号悬空）
- **lane 0 恒为 head0、lane 1 恒为 head1，不做压缩**。`commit_valid[1] ⇒ commit_valid[0]`，
  消费者可按前缀 valid 处理
- `commit_valid[k] = 0` 时该 lane 的 `tag` / `rd_*` / `commit_data` 仅为无效占位，
  **消费者必须先检查 valid**（Buffer 的队头读口是裸 RAM 读，无置 0 门控）
- **P1 侧只用 `valid` / `tag` / `data` 三样**——`rd_*` 是 ARF / 重命名表的菜，不进 P1
- `commit_count` 的 v1 消费者（Buffer 指针推进）已内化；对外保留的消费者是
  [[system_instruction_handler微架构文档.md]] 的 `minstret` 自增，兼作顶层观测
- **`Commit CDB` 只是这组线的总称**，不是一个结构体；公式与接口一律用信号名

#### 5. `flush_tag` 与 `commit_count` 的区别

`flush_tag` 是**恢复上下文的读地址**，`commit_count` 是**回滚边界**，两者通路不同：
`commit_count` 用于本模块的指针落位，同时直达 SIH 供 `minstret` 自增，**不经 flush 侧**。

```text
MISPREDICT @head0   已退休   commit_count = 1
MISPREDICT @head1   两条都已退休，flush_tag = head1，commit_count = 2
EXCEPTION  @head0   未退休   commit_count = 0
EXCEPTION  @head1   head0 已提交、该条未退休，flush_tag = head1，commit_count = 1
MRET                已退休   flush_tag 不参与恢复地址选择，commit_count = 1
INTERRUPT 非 store  未退休   commit_count = 0
INTERRUPT 已 drain store    未退休，flush_tag = head1，commit_count = 1
```

**指针回滚只看 `commit_count`，绝不看 `flush_tag`**——
MISPREDICT / MRET 下后者指向的是已退休的条目，用它落位会把已退休的条目也丢掉。

#### 6. 恢复读口（为 flush_model）

```text
entry[flush_tag] → 恢复读出端口    mispredict_target_pc、exception_cause、exception_tval
```

### ⑤ data structure（schema + 字段三角色）

- **state**：`exec_done` / `store_drain_requested` / `store_drain_done`（per-tag 三位）；
  `head` / `tail`（valid 的压缩本体）
- **header**
    - alloc 批：`rd_idx`(5)、`rd_is_fp`(1)、`rd_write_enable`(1)、`is_store`(1)、
      `is_fence_i`(1)——判定链与提交动作读作谓词 / 地址；alloc 写入即定，**P3 不得覆盖**
    - `is_fence_i` **放 alloc 批而非事件批**：它是译码期就定死的静态属性，不需要等 FU 算。
      事件批那组只在 `exec_done = 1` 时有效，而判定链第 5 步本来就排在第 1 步
      （`head0_done`）之后，两种放法时序等价——那就选便宜的那个：
      alloc 批不动完成通路，**保住"G3 事件字段恒 0"这条不变量**
    - 事件批（writeback 写入）：`mispredict_flag`、`exception_flag`、`is_mret`——判定链谓词。
      只在 `exec_done = 1` 时有效：alloc 不清这组位，陈旧值靠判定链的 done 门挡住
- **payload**
    - `mispredict_target_pc`(64)、`exception_cause`(63)、`exception_tval`(64)——
      恢复读口转发，本模块不求谓词
    - `fpu_fflags`(5)——writeback 批写入、随 commit 转发，本模块不求谓词；只 G2 非零
- per-tag valid 由 `[head, tail)` 指针区间投影，不单独存储。
- 本模块不存 `is_serial`；SerialInstructionTracker 以自身保存的 tag 自清。

### ⑥ 接口

**in-event** `→ CompletionScoreboard`

- alloc（Transaction，**2 写口**，per slot；ready = `can_alloc_1` / `can_alloc_2`，已被上游吸收）
    - move；`rd_idx[s]`(5)、`rd_is_fp[s]`(1)、`rd_write_enable[s]`(1)、`is_store[s]`(1)、
      `is_fence_i[s]`(1)
      —— 整批存进 `entry[self_tag[s]]`，写入即定。
      **本批多源**：前四样来自 IB 与 `dependency_check`，`is_fence_i` 来自 `dispatch_logic`
      （它是 `exe_subop` 的纯函数，按 §1.8 的先例不进 payload，由 dispatch 就地导出）
    - 触发；`accept[s]`(1，s∈{0,1}) —— alloc[s] = accept[s]（判据见 ③）
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 与本模块 `tail` 同源

- writeback（announce ×4，**4 写口、随机寻址**）
    - 本模块收的是四条 lane 的公共层 `completion_common`；lane 0 另带的
      `csr_sideband`（CSR 写意图）**不进本模块**，它是旁带、直连宿主
    - 触发；`Result_valid[g]`(1，g∈{0..3}) —— 本拍这条 lane 要不要写回
    - 地址；`tag_out[g]`(4，g∈{0..3}) —— 写第几格
    - 当 `Result_valid[g] ∧ !global_flush_late` 时：`entry[tag_out[g]].exec_done ← 1`，并写入
      `mispredict_flag`(1)、`mispredict_target_pc`(64)、`exception_flag`(1)、
      `exception_cause`(63)、`exception_tval`(64)、`is_mret`(1) 这组事件字段，
      以及 `fpu_fflags`(5)
    - lane 约束：G0 可产生 `mispredict`、`exception`、`MRET`；G1（ALU1/MUL）的事件字段固定为 0；
      **G2（FPU）的 exception / mispredict / is_mret 固定为 0，但驱动 `fpu_fflags`**
      （IEEE 标志，非事件字段）；G3 只产生访存同步异常
  （地址不对齐、访问越界），且必须在**收下这条 store 之前**判完——这是"出错的 store
  永远不会 drain"；`mispredict_flag` / `is_mret` 固定为 0。异常指令不提交

- flush（announce）
    - 触发；`global_flush_late`(1) —— 对端 flush_model；**只作 writeback / capture 的 guard**
      （③ 的 `!global_flush_late` 项）。指针落位不由它驱动——由判定链自产的
      `flush_valid` 按 ③ 的 flush 次序完成

- store_done（announce）
    - 触发；`store_done_valid`(1) —— 本拍 LSU 是否交回一条 drain 完成
    - 地址；`store_done_tag`(4) —— 置 `store_drain_done` 位（判据见 ③）
    - broadcast；`store_done_exception`(1)、`store_done_cause`(63)、`store_done_tval`(64)
      —— drain 期访存故障（access fault 号段 7）。为 1 时**不置完成位**，
      改写该 tag 的事件批，由第二步的普通异常分支处置（判据见 ③ 第四步）

- 组合读(in)
    - broadcast；`interrupt_pending`(1) —— system_instruction_handler 已综合单线，进判定链第一步分支 4
    - 地址；`flush_tag`(4) —— 恢复读口下标，由 flush_model 回送（与 PC_File 同源，
      对应 out 的恢复读口 mispredict_target_pc / exception_cause / exception_tval）

**out-event** `CompletionScoreboard →`

- commit；`commit_valid[k]`(1×2)、`commit_tag[k]`(4×2)、`rd_idx[k]`(5×2)、`rd_is_fp[k]`(1×2)、
  `rd_write_enable[k]`(1×2)、`commit_fflags[k]`(5×2)、`commit_count`(2)
- `store_drain_req`；`store_drain_req_valid`(1)、`store_drain_tag`(4) ——
  1 拍脉冲，对端无条件收下，无 ready 回送；每拍至多一条且只对 head0 发（判据见 ③）
- flush；`flush_valid`(1)、`flush_tag`(4)、`recovery_kind`(3) —— 对端 flush_model
- 组合读(out)；`head0_tag`(4)、`head1_tag`(4) —— 队头两格的读地址（多个消费者，见集成层）
- 组合读(out)；`mispredict_target_pc`(64)、`exception_cause`(63)、`exception_tval`(64) ——
  恢复读口，按 `flush_tag` 索引（对端 flush_model）

**Static Info**

- `scoreboard_valid_bits[16]`、`scoreboard_exec_done_bits[16]` ——
  供 P1 判唤醒窗口是否已错过
- `Buffer_tail`(4) —— 供 `dependency_check` 计算 `self_tag` 的基址
- `can_alloc_1` / `can_alloc_2`(1×2)、`buffer_empty`(1) —— 供 `dispatch_logic` 准入判断

`head`、`occupancy` 和 `Buffer_head` 是本模块内部状态/中间量，不是对外 Static Info。
其中 `occupancy` 只用于推导上述准入投影及本模块内部的队头判定，`Buffer_head` 不登记为
任何跨模块消费者。
