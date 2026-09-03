# Module `FP_tag_mapping`

`FP_tag_mapping`：32-entry FP register rename table（`NUM_FPR=32`、`TAG_W=4`）。

## Submodule
无。

## FSM
### State
#### Per-entry State
1. `IDLE`：对应 FP register 没有未提交 producer。
2. `BUSY`：对应 FP register 由 `entry.tag` 指向未提交 producer。
### State Transition & Condition Name
1. `ANY -> IDLE`：`reset`
2. `BUSY -> IDLE`：`flush`
3. `IDLE -> BUSY`：`alloc`
4. `BUSY -> IDLE`：`commit_clear`
### Detailed Condition Description
1. `reset`：清零 rename table。
   - Fire来源：`reset.fire = ¬rst_n`。
   - State update：所有 `entry.busy=0`、`entry.tag=0`。
2. `flush`：清除 speculative rename 状态。
   - Fire来源：`flush.fire = global_flush_late`。
   - State update：所有 `entry.busy=0`；tag 保持。
3. `alloc`：为 FP destination 建立 producer tag。
   - Fire来源：`alloc[s].fire = accept[s] ∧ alloc_rd_is_fp[s] ∧ alloc_rd_write_enable[s] ∧ (alloc_rd_idx[s] != 0)`。
   - State update：`entry.busy[alloc_rd_idx[s]]=1`；`entry.tag[alloc_rd_idx[s]]=self_tag[s]`。
4. `commit_clear`：提交后释放匹配 producer。
   - Fire来源：`commit_clear[k].fire = commit_valid[k] ∧ commit_rd_is_fp[k] ∧ commit_rd_write_enable[k] ∧ (entry.tag[commit_rd_idx[k]] == commit_tag[k])`。
   - State update：`entry.busy[commit_rd_idx[k]]=0`。

## Data structure
### State
`entry.busy[0:31]`：1 bit x 32；`IDLE/BUSY`；reset=0；alloc 置 1，commit_clear/flush 清 0。
### Header
`entry.tag[0:31]`：`TAG_W=4 bit x 32`；commit_clear 匹配字段；alloc 更新。
### Payload
无。

## Data Path
- `alloc[s] -> entry.busy/tag[alloc_rd_idx[s]]`：tag/valid；alloc fire 时写入。
- `commit_clear[k] -> entry.busy[commit_rd_idx[k]]`：`∅`；commit_clear fire 时清除。
- `entry.tag/busy[fp_read_idx[x]] -> rename_read[x]`：tag/busy；组合读。

## Interface
### In-event
- `alloc[s]`：Notify，`s∈{0,1}`，payload=`self_tag[s]`、`alloc_rd_idx[s]`、FP write qualifiers。
- `commit_clear[k]`：Notify，`k∈{0,1}`，payload=`commit_tag[k]`、completed destination qualifiers。
- `flush`：Notify，payload=`∅`。
- `reset`：异步 Event，payload=`∅`。
### In Static Info
- `fp_read_idx[x]`：5 bit x 3；FP read addresses。
### Out-event
无。
### Out Static Info
- `rename_read[x]`：`{tag:4,busy:1}`，`x∈{1,2,3}`；`entry.tag/busy[fp_read_idx[x]]`。
### Interface Timing
`clk` 同步写入；`rst_n` 异步复位；rename read 为组合输出。
