# Buffer · 16 entry × 64 bit

### ① per-entry state

**无**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**
### ④ data path

#### 1. `entry.result_data`

```text
writeback 输入端口     → entry[tag_out[g]]    result_data（4 写口、按tag_out寻址）
entry[head0/1_tag]    → 队头读出端口          commit_data[k]（2 读口）
```

- 4 条完成 lane 同拍写 4 个不同 tag，地址由 SCB 的分配保证
- 队头读地址 `head0_tag` / `head1_tag` 由 SCB 给出；读出值点对点直连消费端——
  `commit_data[k]` 接 INT/FP ARF 写数据口与 Commit CDB 的 `data`，INT 与 FP 共用同一条 64 位线

### ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：**无**
- **payload**：`result_data`(64)。writeback 写入

### ⑥ 接口

**in-event** `→ Buffer`

- writeback（announce ×4，**4 写口、随机寻址**）
    - move；`result_data`(64) —— 写进 `entry[tag_out[g]]`
    - 触发；`Result_valid[g]`(1，g∈{0..3}) —— 本拍这条 lane 要不要写
    - 地址；`tag_out[g]`(4，g∈{0..3}) —— 写第几格

- 组合读(in)
    - 地址；`head0_tag`、`head1_tag`(4×2) —— 两个队头读口的pointer，由 SCB 给出

**out-event** `Buffer →`

- 组合读(out)；`commit_data[k]`(64×2) —— head0/head1的 `result_data`

**Static Info**

无。