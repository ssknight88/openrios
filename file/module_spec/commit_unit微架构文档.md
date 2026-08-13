# commit_unit · 纯组合 · 按序退休、store drain、flush 事件裁定

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `head0_tag` / `head1_tag`(output) 与队头资格中间量

```text
head0_tag     = Buffer_head;   head1_tag = Buffer_head + 1     // 4-bit mod16
headK_present = (occupancy ≥ K+1)
headK_valid   = headK_present ∧ scoreboard_valid_bits[headK_tag]
headK_done    = headK_valid   ∧ scoreboard_exec_done_bits[headK_tag]
```

**采样约定**：`occupancy` 是 Buffer 的**拍初值**。

### 2. `commit_valid[k]` / `commit_tag[k]` / `commit_count` / `csr_clear` / `arch_csr_write` / `store_drain_tag` / `flush_valid` / `flush_tag` / `flush_kind`(output)

**一条判定链一次定出这九项**，故并进同一节。

**第一步 · head0 判定：**

```text
1  !head0_valid ∨ !head0_done   提交 0，且【不评估 head1】
2  exception                    head0 不提交，从 head0 起 flush
3  store drain                  head0 是未 drain 的 store：发请求、提交 0、停在 head0
4  外部中断                      在合格边界上可取时：
                                  非 store 的 head0        提交 0，flush_tag = head0
                                  已 drain 的 store 且 head1_valid
                                                          只提交 head0，flush_tag = head1
                                  !head1_valid 时本步不命中，落到 5/6 按普通指令处理
5  mispredict / MRET            head0 提交，然后 flush
6  其余                          正常提交 head0
```

- **exception 排在 store drain 之前**——所以一条出错的 store 永远不会 drain
- **外部中断压过 head0 的 mispredict / MRET**；**MRET 不是 exception**

**第二步 · head1 判定**（只在 head0 正常提交后评估，**head1 永不越过 head0**）

```text
1  is_store        head1 不提交。store 只能在 head0 位置走 drain 子流程
2  exception       head1 不提交，产生 EXCEPTION flush，flush_tag = head1_tag，commit_count = 1
3  mispredict      提交，然后 flush
4  其余             正常提交
```

**head1 不可能是 CSR / SYS**：串行指令要求派遣时 Buffer 空，且被接受后挡死全部更年轻的派发
⇒ 它在 Buffer 里必然独占一格 ⇒ `occupancy == 1` ⇒ `head1_valid == 0`。

**第三步 · 双FP提交阻塞：**

最终提交集合若会产生两笔 `rd_write_enable ∧ rd_is_fp` 的写，**缩到 1 条**（head1 留到下一拍）。
这一条反过来是 FP 侧单写口 / 单清除口的依据。
**阻塞只能减提交条数**，不许丢掉一笔写、也不许提前 flush 来绕开它。

**第四步 · store drain 流程：**

- 每拍至多一条 drain 请求，且**只有 head0 能发**
- head0 是 `exec_done` 且未请求的 store（`!scoreboard_drain_req_bits[head0_tag]`）
  → 发 1 拍脉冲，停在 head0
- `store_done` 命中后置完成位；此后该 store 可正常提交（**不写 ARF**）
- **更年轻的非 store 不得越过一条在等 `store_done` 的 head store**
- `store_done_exception` / `store_done_cause` 保留未实现，预期恒 0

**第五步 · 提交动作：**

对每个有效 lane：按 `rd_write_enable` / `rd_is_fp` 选 INT/FP ARF 写；
清目的重命名表对应格的 `busy`（要求该格 `tag == commit_tag[k]`）；
`is_serial` 命中时发 `csr_clear`；`is_csr ∧ csr_write_enable` 时发 `arch_csr_write`。

**`csr_clear` 的门控必须用 `is_serial`，不能用 `is_csr ∨ is_mret`**——
它必须与串行化 tracker 的**置位集合逐位相等**。置位用的是含 `is_sys` 的判据；
若这里只覆盖 `is_csr ∨ is_mret`，一条 `is_sys` 指令置位后**永远清不掉**，
tracker 会挡死全部派发 = **全机停摆**。
`is_serial` 在 alloc 拍就已写进队头 entry，与 FU 行为无关；
而 `is_csr` / `is_mret` 是 writeback 覆盖的，来不及。
（MRET 编码在 ALU 子码空间里，执行时只置 `is_mret`，它的 `is_csr` 是 **0**。）

**判定结论：**

```text
commit_valid[0] = head0 判定链允许本拍退休
commit_tag[0]   = commit_valid[0] ? head0_tag : 0
commit_valid[1] = head1 判定链允许本拍退休           // 以 commit_valid[0] 为前提
commit_tag[1]   = commit_valid[1] ? head1_tag : 0
commit_count    = commit_valid[0] + commit_valid[1]  // 0..2

csr_clear       = commit_valid[k] ∧ Buffer[headK_tag].is_serial
arch_csr_write  = commit_valid[k] ∧ Buffer[headK_tag].is_csr
                                  ∧ Buffer[headK_tag].csr_write_enable

store_drain_tag = head0_tag

flush_valid / flush_tag / flush_kind                 // 由判定链直接给出
flush_kind：0 = MISPREDICT   1 = EXCEPTION   2 = MRET   3 = INTERRUPT
```

`commit_valid[k]` / `commit_tag[k]` **由本模块内部形成，不是任何上游给的输入**；
异常、store drain、mispredict、中断等分支只改变这两个 valid 的结果与 flush 输出，
**不另造第二套提交信号**。

#### 3. `commit_data[k]`(output) —— commit 的 P1 侧载荷

```text
commit_data[k] = commit_valid[k] ? Buffer[headK_tag].result_data : 0
```

`commit_valid[k]` / `commit_tag[k]` 上面已定义，P1 侧与提交侧用的是同一根线。

- **`Commit CDB` 只是这三组线的总称**，不是一个结构体；公式与接口一律用信号名
  `commit_valid[k]` / `commit_tag[k]` / `commit_data[k]`
- **lane 0 恒为 head0、lane 1 恒为 head1，不做压缩**。`commit_valid[1] ⇒ commit_valid[0]`，
  故消费者可按前缀 valid 处理
- **P1 侧只用 `valid` / `tag` / `data` 三样**——`rd_*`、事件位、CSR 字段都是本模块的本地字段，
  不上 CDB；P1 的源解析只需要"这个 tag 的值现在可取"
- `data` 直接取自队头读出值，本模块不加工。INT 与 FP 共用同一条 64 位线
- `commit_valid[k] = 0` 时该 lane 的 `tag` / `data` 仅为无效占位，**消费者必须先检查 valid**
- **它不是独立 event**——它是 `commit` 这一个 event 在 P1 侧的载荷

#### 4. `flush_tag` 与 `commit_count` 的区别

`flush_tag` 是**恢复上下文的读地址**，`commit_count` 是**回滚边界**，两者通路不同：
`commit_count` 随 commit 直达 Buffer、**不经 flush 侧**。

`flush_tag` 指向产生控制事件的 head；**是否指向本拍已退休的条目**取决于 kind 与位置：

```text
MISPREDICT @head0   已退休   commit_count = 1
MISPREDICT @head1   两条都已退休，flush_tag = head1，commit_count = 2
EXCEPTION  @head0   未退休   commit_count = 0
EXCEPTION  @head1   head0 已提交、该条未退休，flush_tag = head1，commit_count = 1
MRET                已退休   flush_tag 不参与恢复地址选择，commit_count = 1
INTERRUPT 非 store  未退休   commit_count = 0
INTERRUPT 已 drain store    未退休，flush_tag = head1，commit_count = 1
```

**Buffer 的 `tail` 回滚只看 `commit_count`，绝不看 `flush_tag`**——
MISPREDICT / MRET 下后者指向的是已退休的条目，用它落位会把已退休的条目也丢掉。

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ commit_unit`

- 组合读(in)
  - broadcast；`Buffer[headK_tag]` 的整条 payload（`K ∈ {0,1}`）—— **2 读口**：
      `result_data`(64)、`rd_idx`(5)、`rd_is_fp`(1)、`rd_write_enable`(1)、`is_store`(1)、
      `is_serial`(1)、事件位、CSR 字段
    - broadcast；`occupancy`(5)（**拍初值**）—— 判 `headK_present`
    - broadcast；`scoreboard_valid_bits[16]`、`scoreboard_exec_done_bits[16]`、
      `scoreboard_drain_req_bits[16]`、`scoreboard_drain_done_bits[16]` —— 判队头资格与 drain 进度
    - broadcast；`interrupt_pending`(1) —— 已综合完的一根线，
      本模块**不再自行组合** `mie` / `mip` / `mstatus.MIE`
    - broadcast；`Buffer_head`(4)：`head0_tag = Buffer_head`、
      `head1_tag = Buffer_head + 1`。

- `store_done`（announce）
  - broadcast；`store_done_tag`(4) —— 与 `head0_tag` 比对，置完成位，不留存

**out-event** `commit_unit →`

- commit；`commit_valid[k]`(1×2)、`commit_tag[k]`(4×2)、`commit_data[k]`(64×2)、
  `commit_count`(2)
- `arch_csr_write`；`arch_csr_write`(1)
- `csr_clear`；`csr_clear`(1)
- `store_drain_req`；`store_drain_tag`(4)
- flush；`flush_valid`(1)、`flush_tag`(4)、`flush_kind`(2)
- 组合读(out)；`head0_tag`(4)、`head1_tag`(4)

`commit_count` 是**非 per-lane** 字段，与 `commit_valid/tag/data` 同属 `commit` 这一个 event。

**Static Info：**

无。
