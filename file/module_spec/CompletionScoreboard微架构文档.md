# CompletionScoreboard 微架构文档

CompletionScoreboard，以下简称 SCB，是后端退休侧的裁决中枢。它不是只记录执行完成位的普通 scoreboard，而是按 Buffer tag 跟踪每条在飞指令的生命周期、保存精确退休和恢复所需的事件字段，并在每拍对 Buffer 队头做按序退休判定。

本文档只覆盖 SCB 自身的微架构边界与控制规则；第 12 点场景 walkthrough 暂不展开。

## 1. Overview

SCB 与 Buffer、PC File 共用 16-entry tag 空间。tag 是 Buffer entry 地址，来自同一套 4-bit index 算术；P1 分配时，Buffer、PC File、SCB 对同一条指令使用同一个 self_tag。

SCB 的核心职责有五类：

- 跟踪每个 tag 的生命周期：在飞、执行完成、store drain 请求、store drain 完成。
- 保存退休裁决所需的事件字段：branch mispredict、exception、store、serial、MRET、CSR 写回内容等。
- 每拍检查 Buffer 队头 tag，按程序顺序决定 `commit_count`。
- 产生退休侧控制事件：commit lane、CSR 架构写、serial tracker clear、store drain request、flush 三元组。
- 向 P1 提供 `valid` / `exec_done` 向量，用于 missed_wakeup 判断。

SCB 不保存普通 result data。普通结果数据在 Buffer 中按 tag 写回，并由 Buffer 队头读口送往 ARF、Commit CDB 等消费端。SCB 只保存控制与裁决相关状态。

## 2. SCB Entry Format

SCB 是 16 项按 tag 索引的表，每项建议拆成 state、header、payload 三类字段。

```text
SCBEntry[tag] {
    // lifecycle state
    valid
    exec_done
    store_drain_requested
    store_drain_done

    // instruction attributes
    is_store
    is_serial
    is_csr
    is_mret

    // recovery / event payload
    mispredict_flag
    mispredict_target_pc
    exception_flag
    exception_cause
    exception_tval

    // delayed architectural CSR write
    csr_write_enable
    csr_addr
    csr_wdata
}
```

字段角色：

- **state**：`valid`、`exec_done`、`store_drain_requested`、`store_drain_done`。这四位构成生命周期 FSM。
- **header**：`is_store`、`is_serial`、`is_csr`、`is_mret`。这些字段在 P1 allocation 时写入，之后作为退休裁决谓词。
- **payload**：mispredict、exception、CSR 写回字段。它们在执行完成或 writeback 时补写，只在对应 tag 到队头时被消费。

生命周期可抽象为：

```text
FREE / INFLIGHT / DONE / DRAINING / DRAINED

FREE      : valid = 0
INFLIGHT  : valid = 1, exec_done = 0
DONE      : valid = 1, exec_done = 1, 非 store 或 store 尚未请求 drain
DRAINING  : valid = 1, exec_done = 1, store_drain_requested = 1, store_drain_done = 0
DRAINED   : valid = 1, exec_done = 1, store_drain_requested = 1, store_drain_done = 1
```

对非 store 指令，`store_drain_requested` 和 `store_drain_done` 恒作为无效字段看待，不参与退休阻塞。

## 3. Allocation Path / P1 写入行为

P1 accept 是 SCB allocation 的唯一入口。slot0/slot1 被 `p1_dsp` 接受后，SCB 在对应 `self_tag[s]` 初始化表项。slot1 accepted 必然蕴含 slot0 accepted，但 SCB 仍按两个独立写口描述。

allocation 写入规则：

```text
alloc[s] = accept[s] && !global_flush_late

if alloc[s]:
    entry[self_tag[s]].valid                 <- 1
    entry[self_tag[s]].exec_done             <- 0
    entry[self_tag[s]].store_drain_requested <- 0
    entry[self_tag[s]].store_drain_done      <- 0
    entry[self_tag[s]].is_store              <- is_store[s]
    entry[self_tag[s]].is_serial             <- is_serial[s]
    entry[self_tag[s]].is_csr                <- is_csr[s]
    entry[self_tag[s]].is_mret               <- is_mret[s]
    entry[self_tag[s]].event payload         <- 0
```

约束：

- SCB allocation 的 tag 与 Buffer allocation 的 tag 同源，不能重新计算或重命名。
- allocation 拍必须清空该 entry 的事件 payload，避免旧 tag 的 mispredict、exception 或 CSR 写字段被新指令误用。
- `valid` 被置 1 后，该 tag 对 P1 的 `scoreboard_valid_bits` 可见。
- flush 拍不允许新 allocation 成为可见在飞项；P1 本身也应在 `global_flush_late` 下禁止 accept。SCB 侧仍保留 `!global_flush_late` 作为防线。

## 4. Completion Writeback Path

SCB 接收四条 completion lane 的随机寻址写回。每条 lane 以 `Result_valid[g]` 和 `tag_out[g]` 为基本写入条件。

普通完成写入：

```text
completion_fire[g] = Result_valid[g] && !global_flush_late

if completion_fire[g] && entry[tag_out[g]].valid:
    entry[tag_out[g]].exec_done <- 1
```

事件字段随对应 lane 写入：

- branch/BRU 完成时，如果发现预测错误，写入 `mispredict_flag` 和 `mispredict_target_pc`。
- exception 发生时，写入 `exception_flag`、`exception_cause`、`exception_tval`。
- CSR 指令完成时，写入 `csr_write_enable`、`csr_addr`、`csr_wdata`；架构 CSR 不在执行阶段更新。
- MRET 指令完成时，写入或保持 `is_mret`，实际特权态更新等到退休 flush 侧处理。
- store 执行完成时，`exec_done` 只表示 LSU/store buffer 已接收该 store，不表示 store 已 drain，也不表示它已退休。

写入约束：

- completion lane 只允许更新 valid entry。若 tag 已被 commit 或 flush 清除，completion 写入必须被屏蔽。
- 同一拍四条 lane 应对应不同在飞 tag；若存在同 tag 多写，必须在上游保证互斥，SCB 不承担合并仲裁。
- `global_flush_late` 拍的 completion 写入不生效，避免 younger 已被回滚指令在 SCB 中重新显形。

## 5. Retirement Decision Chain

SCB 每拍读取 Buffer 队头两个 tag，并按程序顺序形成 `commit_count`。队头 tag 来自 Buffer `head` 投影，SCB 不自行维护 head/tail。

基础谓词：

```text
head0_tag = Buffer_head
head1_tag = Buffer_head + 1

head0_valid = entry[head0_tag].valid
head1_valid = entry[head1_tag].valid

head0_done = head0_valid && entry[head0_tag].exec_done
head1_done = head1_valid && entry[head1_tag].exec_done

head0_store_ready = !entry[head0_tag].is_store || entry[head0_tag].store_drain_done
head1_store_ready = !entry[head1_tag].is_store || entry[head1_tag].store_drain_done

head0_retirable = head0_done && head0_store_ready
head1_retirable = head1_done && head1_store_ready
```

lane0 裁决：

- 如果 Buffer empty 或 `head0_valid == 0`，`commit_count = 0`。
- 如果 head0 未执行完成，`commit_count = 0`。
- 如果 head0 是 store 且尚未 drain done，SCB 发起或保持 store drain 请求，`commit_count = 0`。
- 如果 head0 有 precise event，仍由 lane0 独立裁决是否提交和 flush。
- 如果 head0 普通可退休，则 lane0 commit。

lane1 裁决：

- lane1 commit 必须蕴含 lane0 commit。
- lane1 只能在 head0 没有阻塞性 flush/control event 时考虑。
- head1 必须 valid、exec_done，并满足 store drain 条件。
- head1 不能越过 head0 的 exception、mispredict、MRET、interrupt 等恢复事件。
- 如果 head1 自身有 flush event，允许 `commit_count = 2` 并同时以 head1 作为 `flush_tag`，前提是 head0 已正常退休且不会改变控制流。

提交数量：

```text
commit_count = 0 / 1 / 2
commit_valid[0] = (commit_count >= 1)
commit_valid[1] = (commit_count >= 2)
commit_tag[0]   = head0_tag
commit_tag[1]   = head1_tag
```

SCB 输出的 commit tag 同时驱动：

- Buffer head 前移。
- SCB entry valid 清除。
- ARF / rename clear / Commit CDB 等提交侧消费端的本地 qualifier。
- CSR_Control 的 serial tracker clear。

## 6. Flush Arbitration

SCB 是退休侧 flush 事件的发起者，`flush_model` 是 `global_flush_late` 的唯一生成者。SCB 只输出 flush 三元组：

```text
flush_valid
flush_kind
flush_tag
```

flush kind 建议沿用 `flush_model` 文档编码：

```text
0 = MISPREDICT
1 = EXCEPTION
2 = MRET
3 = INTERRUPT
```

flush 事件来源和优先级：

- exception 是 precise trap，应优先于同一 tag 的 mispredict。
- MRET 是特权返回事件，只有到队头并完成后才可触发。
- mispredict 只有在对应 branch 到队头并允许退休时才触发。
- interrupt 若支持，应在队头退休边界注入，不能破坏已经确定提交的 older 指令。

`flush_tag` 的含义：

- `flush_tag` 是恢复上下文读地址，不是 Buffer rollback 边界。
- MISPREDICT/MRET 下，`flush_tag` 通常指向本拍已退休的那条控制指令。
- EXCEPTION/INTERRUPT 下，`flush_tag` 指向用于生成 trap epc/cause/tval 的精确边界指令。
- rollback 边界由 `commit_count` 与 Buffer 指针落位共同决定。

flush 拍的全局约定：

```text
head_new = head + commit_count
tail_new = head_new
```

也就是说，flush 拍先落下当拍 commit，Buffer head 先按 `commit_count` 前移，然后 tail 回滚到新的 head。SCB 同拍也应先清除已提交 tag，再清除其余仍 valid 的 tag。提交不是被 flush 取消的投机效果。

## 7. CSR Commit Semantics

CSR 写通路必须保持精确架构状态。执行阶段只产生候选写信息，不能直接写架构 CSR。

写入流程：

```text
CSR execute/writeback:
    entry[tag].csr_write_enable <- csr_write_enable
    entry[tag].csr_addr         <- csr_addr
    entry[tag].csr_wdata        <- csr_wdata

CSR commit:
    if commit_valid[k] && entry[commit_tag[k]].csr_write_enable:
        arch_csr_write.valid <- 1
        arch_csr_write.addr  <- entry[commit_tag[k]].csr_addr
        arch_csr_write.data  <- entry[commit_tag[k]].csr_wdata
```

规则：

- CSR 指令必须到达队头并被 retirement chain 放行，才允许输出 `arch_csr_write`。
- 若 CSR 指令在提交前被 flush，其 SCB entry 失效，暂存 CSR 写随之取消。
- `arch_csr_write` 正常情况下每拍至多一个，因为 CSR/SYS 由 `CSR_Control` tracker 串行化，且串行指令只能从 slot0 单独派发。
- `csr_clear` 必须和被接受的 serial 指令口径一致，送 `CSR_Control` 用于清除 `csr_inflight_valid`。
- MRET 不是普通 CSR 软件写；它通过 `flush_model` / `csr_control` 的 `mret_update` 路径更新特权态。

## 8. Store Drain Protocol

store 的执行完成与对外可见排空是两个阶段。SCB 需要保证 store 不被 younger 指令越过提交，并在最老 store 到达队头后驱动 LSU/store queue drain。

状态含义：

- `exec_done = 1`：store 已被 LSU/store buffer 接收。
- `store_drain_requested = 1`：SCB 已经对该最老 store 发起 drain 请求。
- `store_drain_done = 1`：LSU/store queue 已确认该 store 对外排空，可以退休。

协议：

```text
if head0 is store && head0.exec_done && !head0.store_drain_done:
    store_drain_req.valid <- !entry[head0_tag].store_drain_requested
    store_drain_req.tag   <- head0_tag
    entry[head0_tag].store_drain_requested <- 1

if store_done.valid && entry[store_done.tag].valid:
    entry[store_done.tag].store_drain_done <- 1
```

规则：

- SCB 每拍至多对一条 store 发 drain request，且只能是按程序顺序最老的 store。
- store drain 未完成时，`commit_count` 不能越过该 store。
- store drain done 后，该 store 才满足 retirement 的 store ready 条件。
- 如果 store 同时携带 exception，exception 的精确性优先；不得先让异常 store 产生不可回滚的普通提交语义。

## 9. Interface List

### 9.1 输入事件

From P1 / DSP allocation：

```text
accept[2]
self_tag[2]
is_store[2]
is_serial[2]
is_csr[2]
is_mret[2]
```

From completion lanes：

```text
Result_valid[4]
tag_out[4]
mispredict_flag[4]
mispredict_target_pc[4]
exception_flag[4]
exception_cause[4]
exception_tval[4]
csr_write_enable[4]
csr_addr[4]
csr_wdata[4]
is_mret_wb[4]          // 若 MRET 信息不在 allocation 固定，则由 writeback 补充
```

From LSU/store drain：

```text
store_done_valid
store_done_tag
```

From Buffer：

```text
Buffer_head
Buffer_occupancy
buffer_empty
head0_tag
head1_tag
```

From flush_model：

```text
global_flush_late
```

### 9.2 输出事件

To Buffer：

```text
commit_count
commit_valid[2]
commit_tag[2]
```

To CSR_Control：

```text
csr_clear
arch_csr_write.valid
arch_csr_write.addr
arch_csr_write.data
```

To LSU/store queue：

```text
store_drain_req_valid
store_drain_req_tag
```

To Flush_Model：

```text
flush_valid
flush_kind
flush_tag
```

To P1 / p1_check_resolve：

```text
scoreboard_valid_bits[16]
scoreboard_exec_done_bits[16]
```

### 9.3 Static Info

```text
scoreboard_valid_bits[tag]      = entry[tag].valid
scoreboard_exec_done_bits[tag]  = entry[tag].exec_done
scoreboard_drain_req_bits[tag]  = entry[tag].store_drain_requested
scoreboard_drain_done_bits[tag] = entry[tag].store_drain_done
```

恢复上下文可由 SCB 提供，也可按现有 `flush_model` 文档从 Buffer/PC File 读取。若后续决定把 `mispredict_target_pc`、`exception_cause`、`exception_tval` 全部迁入 SCB，则 `flush_model` 的恢复读口应相应改为读 SCB；否则 SCB 只负责输出 `flush_tag`。这一点需要在 RTL 分工时保持唯一来源，不能 Buffer 与 SCB 双写双读。

## 10. Timing / Priority Rules

同一拍事件优先级必须固定，建议采用以下规则。

### 10.1 commit 与 flush

flush 拍先应用本拍 commit，再清除其余仍 valid 的 entry。对应 Buffer 先 `head += commit_count`，再 `tail = head_new`。

```text
for each commit lane k:
    if commit_valid[k]:
        entry[commit_tag[k]].valid <- 0

if global_flush_late:
    for each tag t not in committed_tags_this_cycle:
        entry[t].valid <- 0
```

### 10.2 allocation 与 flush

`global_flush_late` 拍不产生新 allocation。若上游因为实现 bug 仍给出 `accept`，SCB 应以 flush 优先，保持对应 entry invalid。

### 10.3 completion 与 flush

`global_flush_late` 拍 completion write 被屏蔽。这样 younger 指令不会在回滚清表后重新置 `exec_done` 或事件 payload。

### 10.4 completion 与 commit 同 tag

若某条 head 指令在同一拍 completion 并满足退休条件，是否允许同拍 commit 取决于实现时序。为了避免隐含半拍路径，建议 SCB retirement chain 使用拍初 `exec_done`，completion 写入下一拍才参与退休。若 RTL 选择 completion-to-commit 同拍快路径，必须在接口与时序文档中显式声明。

### 10.5 store drain request 与 done

store drain request 只对队头最老 store 发起。若同拍收到该 tag 的 `store_done`，建议 `store_drain_done` 在时钟边界置位，下一拍再允许 commit；若要支持同拍 drain_done-to-commit，也需要显式声明快路径。

### 10.6 两条 commit lane

lane1 commit 必须以 lane0 commit 为前提。lane1 不得越过 lane0 的 exception、mispredict、MRET、interrupt、未完成 store drain 或 serial 阻塞。

### 10.7 CSR 架构写与 flush

如果某 CSR 指令在本拍被 commit，则它的 `arch_csr_write` 是提交效果，不被同拍 flush 取消。未 commit 的 CSR entry 在 flush 中失效，其暂存写内容取消。

## 11. Invariants

以下不变量建议转成 SVA 或等价验证检查。

1. 只有 `valid == 1` 的 SCB entry 可以被 completion 更新。

2. `commit_valid[1]` 必须蕴含 `commit_valid[0]`。

3. `commit_tag[0]` 必须等于当前 Buffer head tag；`commit_tag[1]` 必须等于 head+1 tag。

4. SCB 只能按 Buffer head 顺序退休，不得提交 younger tag 而跳过 older valid tag。

5. head0 未完成时，`commit_count` 必须为 0。

6. head0 store 未 drain done 时，`commit_count` 必须为 0，并且最多只允许对 head0 发 drain request。

7. head1 commit 必须满足 head1 valid、exec_done、store ready，且 head0 已 commit。

8. flush event 只能在对应事件指令到达退休裁决边界后对外发出。

9. `flush_tag` 只作为恢复上下文读地址，不作为 Buffer rollback 指针。

10. CSR 架构写只能在该 CSR 指令 commit 的同拍产生。

11. 未 commit 的 CSR entry 被 flush 后不得产生 `arch_csr_write`。

12. serial tracker 的 `csr_clear` 必须对应真实提交或 flush，不得提前清除在飞 serial 指令。

13. `scoreboard_valid_bits[tag]` 必须等于 `entry[tag].valid`。

14. `scoreboard_exec_done_bits[tag]` 必须等于 `entry[tag].exec_done`。

15. flush 拍已经 commit 的 tag 不再被视为被 flush 取消。

16. allocation 后 entry payload 必须被初始化，不能继承旧 tag 的事件字段。

17. 若 SCB 和 Buffer 对恢复字段的存放位置尚未统一，任一字段只能有一个 architectural source of truth。
