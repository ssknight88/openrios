# CompletionScoreboard · 裁决中枢 · 环指针 + 16 格 per-tag + 按序退休判定链

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
  事件批写进 `entry[tag_out[g]]`
    - **4 组并发、随机寻址**；四个 `tag_out` 属四个不同在飞 tag，地址正交
    - **store 的 `exec_done` 只表示 store buffer 收下了**，不代表已 drain、更不代表已退休
    - `!global_flush_late` 只盖 flush 当拍；**迟到完成由 FU flush 契约挡**
      （[[p3_arbiter_G0微架构文档.md]] ④：flush 拍 FU 作废在飞工作，
      此后不得对旧 tag 再发 `Result_valid`）
- **drain_req** = 判定链第四步命中 → `entry[head0_tag].store_drain_requested ← 1`
    - 每拍至多一条，且只对队头最老那条发
- **drain_done** = `store_done` 命中（活 tag、已请求、未完成）
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
                                  非 store 的 head0        提交 0，flush_tag = head0
                                  已 drain 的 store 且 head1_valid
                                                          只提交 head0，flush_tag = head1
                                  !head1_valid 时本步不命中，落到 5/6 按普通指令处理
5  mispredict / MRET            head0 提交，然后 flush
6  其余                          正常提交 head0
```

- **exception 排在 store drain 之前**——所以一条出错的 store 永远不会 drain
- **外部中断压过 head0 的 mispredict / MRET**；**MRET 不是 exception**
- `interrupt_pending` 是 [[system_instruction_handler微架构文档.md]] **已综合完**的一根线，
  本模块直接用，**不再自行组合** `mie` / `mip` / `mstatus.MIE`

**第二步 · head1 判定**（只在 head0 正常提交后评估，**head1 永不越过 head0**）

```text
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
- `store_done` 命中后置完成位；此后该 store 可正常提交（**不写 ARF**）
- **更年轻的非 store 不得越过一条在等 `store_done` 的 head store**
- `store_done_exception` / `store_done_cause` 保留未实现，预期恒 0

**第五步 · 提交动作**

对每个有效 lane：按 `rd_write_enable` / `rd_is_fp`（从本表 alloc 批按 headK 读出）
选 INT/FP ARF 写；清目的 tag_mapping 对应格的 `busy`（要求该格 `tag == commit_tag[k]`）。
CSR 写意图的捕获与落笔在 [[system_instruction_handler微架构文档.md]]
（监听 lane 0 capture、commit lane tag 比对 apply），本模块不参与。

**判定结论**

```text
commit_valid[0] = head0 判定链允许本拍退休
commit_tag[0]   = commit_valid[0] ? head0_tag : 0
commit_valid[1] = head1 判定链允许本拍退休           // 以 commit_valid[0] 为前提
commit_tag[1]   = commit_valid[1] ? head1_tag : 0
commit_count    = commit_valid[0] + commit_valid[1]  // 0..2

store_drain_tag = head0_tag

flush_valid / flush_tag / flush_kind                 // 由判定链直接给出
flush_kind：0 = MISPREDICT   1 = EXCEPTION   2 = MRET   3 = INTERRUPT
```

`commit_valid[k]` / `commit_tag[k]` 由判定链内部形成，**不是任何上游给的输入**；
异常、store drain、mispredict、中断等分支只改变这两个 valid 的结果与 flush 输出，
**不另造第二套提交信号**。

#### 4. commit 事件的完整字段集

```text
per lane：  commit_valid[k]、commit_tag[k]、rd_idx[k]、rd_is_fp[k]、rd_write_enable[k]
非 per-lane：commit_count
数据：      commit_data[k] —— 不经本模块，由 Buffer 队头读口直接给出
            （本模块供 head0_tag / head1_tag 作 Buffer 的读地址）
```

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
`commit_count` 只进本模块的指针落位，**不经 flush 侧**。

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
    - alloc 批：`rd_idx`(5)、`rd_is_fp`(1)、`rd_write_enable`(1)、`is_store`(1)——
      判定链与提交动作读作谓词 / 地址；alloc 写入即定，**P3 不得覆盖**
    - 事件批（writeback 写入）：`mispredict_flag`、`exception_flag`、`is_mret`——判定链谓词
- **payload**
    - `mispredict_target_pc`(64)、`exception_cause`、`exception_tval`——
      恢复读口转发，本模块不求谓词
- per-tag valid 由 `[head, tail)` 指针区间投影，不单独存储。
- 本模块不存 `is_serial`；SerialInstructionTracker 以自身保存的 tag 自清。

### ⑥ 接口

**in-event** `→ CompletionScoreboard`

- alloc（Transaction，**2 写口**，per slot；ready = `can_alloc_1` / `can_alloc_2`，已被上游吸收）
    - move；`rd_idx[s]`(5)、`rd_is_fp[s]`(1)、`rd_write_enable[s]`(1)、`is_store[s]`(1)
      —— 整批存进 `entry[self_tag[s]]`，写入即定
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 与本模块 `tail` 同源

- writeback（announce ×4，**4 写口、随机寻址**）
    - 触发；`Result_valid[g]`(1，g∈{0..3}) —— 本拍这条 lane 要不要写回
    - 地址；`tag_out[g]`(4，g∈{0..3}) —— 写第几格
    - 当 `Result_valid[g] ∧ !global_flush_late` 时：`entry[tag_out[g]].exec_done ← 1`，并写入
      `mispredict_flag`(1)、`mispredict_target_pc`(64)、`exception_flag`(1)、
      `exception_cause`、`exception_tval`、`is_mret`(1) 这组事件字段
    - lane 约束：G0 可产生 `mispredict`、`exception`、`MRET`；G1（ALU1/MUL）的事件字段固定为 0；
      G2（FPU）当前不将 IEEE flag 作为同步异常，事件字段固定为 0；G3 可产生 LSU 同步异常，
      `mispredict_flag` / `is_mret` 固定为 0。异常指令不提交

- flush（announce）
    - 触发；`global_flush_late`(1) —— 对端 flush_model；**只作 writeback / capture 的 guard**
      （③ 的 `!global_flush_late` 项）。指针落位不由它驱动——由判定链自产的
      `flush_valid` 按 ③ 的 flush 次序完成

- store_done（announce）
    - 地址；`store_done_tag`(4) —— 置 `store_drain_done` 位（判据见 ③）

- 组合读(in)
    - broadcast；`interrupt_pending`(1) —— system_instruction_handler 已综合单线，进判定链第一步分支 4

**out-event** `CompletionScoreboard →`

- commit；`commit_valid[k]`(1×2)、`commit_tag[k]`(4×2)、`rd_idx[k]`(5×2)、`rd_is_fp[k]`(1×2)、
  `rd_write_enable[k]`(1×2)、`commit_count`(2) 
- `store_drain_req`；`store_drain_tag`(4)
- flush；`flush_valid`(1)、`flush_tag`(4)、`flush_kind`(2) —— 对端 flush_model
- 组合读(out)；`head0_tag`(4)、`head1_tag`(4) —— Buffer 队头读口的地址
- 组合读(out)；`mispredict_target_pc`(64)、`exception_cause`、`exception_tval` ——
  恢复读口，按 `flush_tag` 索引（对端 flush_model）

**Static Info**

- `scoreboard_valid_bits[16]`、`scoreboard_exec_done_bits[16]` ——
  供 P1 判唤醒窗口是否已错过
- `Buffer_head`(4)、`Buffer_tail`(4)
- `occupancy`(5)、`can_alloc_1` / `can_alloc_2`(1×2)、`buffer_empty`(1)
