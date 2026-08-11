# CompletionScoreboard · 16 格 · 按 tag 索引，只存生命周期

### ① per-entry state

`FREE / INFLIGHT / DONE / DRAINING / DRAINED`

- 逐格存四位：`valid` / `exec_done` / `store_drain_requested` / `store_drain_done`。
  乱序寻址，state 不可压缩——**per-entry FSM**

### ② state transition & condition（event 名）

- FREE → INFLIGHT：alloc
- INFLIGHT → DONE：exec_done
- DONE → DRAINING：drain_req（仅 store）
- DRAINING → DRAINED：drain_done（仅 store）
- DONE / DRAINED → FREE：commit
- ANY → FREE：flush

### ③ condition 细化

- **alloc** = `accept[s]` → `entry[self_tag[s]]` ← `{valid:1, exec_done:0, drain 两位:0}`
    - 寻址 tag 与 Buffer 的 `tail` 同源，故两表的分配位置天然一致
- **exec_done** = `Result_valid[g]` ∧ `!global_flush_late` → `exec_done ← 1`
    - **4 组并发、随机寻址**；四个 `tag_out` 属四个不同在飞 tag，地址正交
    - **store 的 `exec_done` 只表示 store buffer 收下了**，不代表已 drain、更不代表已退休
- **drain_req** = 收到 drain 请求 → `entry[store_drain_tag].store_drain_requested ← 1`
    - 每拍至多一条，且只对按序退休的最老那条发
- **drain_done** = `store_done` 命中（活 tag、已请求、未完成）→ `entry[store_done_tag].store_drain_done ← 1`
- **commit** = `commit_valid[k]` ∧ `commit_tag[k]` 命中 → `valid ← 0`
    - 本模块**不校验**被提交的 tag 是否处在合法退休态。
      `DONE / DRAINED → FREE` 的前提由提交侧的判定链保证
- **flush** = `global_flush_late` → 同一时钟边界**先应用 commit tag 清除，再清其余仍活跃的 tag**
  的四位；同拍已退休 tag 不再参与 flush 清除
    - 这样"清除不是取消提交"：**提交路径拥有同拍 tag 的优先级**
    - 本模块的 flush **不使用任何 tag**：所有未退休的活跃 tag 一律清除，
      回滚边界的语义由 Buffer 的指针落位承担

### ④ data path

#### 1. `scoreboard_valid_bits[16]` (output)

```text
scoreboard_valid_bits[t]      = entry[t].valid                  t ∈ {0..15}
scoreboard_exec_done_bits[t]  = entry[t].exec_done
scoreboard_drain_req_bits[t]  = entry[t].store_drain_requested
scoreboard_drain_done_bits[t] = entry[t].store_drain_done
```


### ⑤ data structure（schema + 字段三角色）

- **state**：`valid` / `exec_done` / `store_drain_requested` / `store_drain_done`——四位全是 state
- **header**：**无**
- **payload**：**无**

### ⑥ 接口

**in-event** `→ CompletionScoreboard`

- alloc（Transaction，**2 写口**，per slot）
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 置 `valid` 位的表项下标。**零载荷**：本模块无 payload

- exec_done（announce ×4）
    - 触发；`Result_valid[g]`(1，g∈{0..3}) —— 本拍这条 lane 要不要置位
    - 地址；`tag_out[g]`(4，g∈{0..3}) —— 置 `exec_done` 位的下标

- drain_req（announce，单线脉冲）
    - 地址；`store_drain_tag`(4) —— 置 `store_drain_requested` 位的下标

- drain_done（announce）
    - 地址；`store_done_tag`(4) —— 置 `store_drain_done` 位的下标

- commit（announce，**2 清除口**）
    - 触发；`commit_valid[k]`(1，k∈{0,1}) —— 本拍这个 lane 要不要清
    - 地址；`commit_tag[k]`(4，k∈{0,1}) —— 清四位的表项下标

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，全表清 `valid`，无载荷

**out-event** `CompletionScoreboard →`

无出向边——本模块的全部对外输出都是 Static Info。

**Static Info**

四条向量**全部 16 位宽、按 4-bit tag 索引**，是 per-entry 四位的聚合投影：

- `scoreboard_valid_bits[16]`（`bit[tag] = valid`）
- `scoreboard_exec_done_bits[16]`（`bit[tag] = exec_done`）
- `scoreboard_drain_req_bits[16]`（`bit[tag] = store_drain_requested`）
- `scoreboard_drain_done_bits[16]`（`bit[tag] = store_drain_done`）
