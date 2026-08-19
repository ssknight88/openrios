# FP_tag_mapping · 32 entry · `{busy, latest_tag}`

## ① per-entry state

`IDLE / BUSY`

- `busy` 1 bit。
- 1 = 存在producer；提交拍解除busy（commit）、flush 全部解绑。正文 `tag` 即 `latest_tag`
- **entry 0 是普通格**：RISC-V F/D 里 `f0` 没有零语义，它照常重命名、照常置 busy、照常被写。
  硬连规则是**整数专有**的

## ② state transition & condition（event 名）

- IDLE → BUSY：alloc
- BUSY → IDLE：commit
- BUSY → BUSY：alloc（同一格被更年轻的指令重命名，只换 `tag`，不是阶段转移）
- ANY → IDLE：flush

## ③ condition 细化

- **alloc[s]** = `accept[s]` ∧ `rd_write_enable[s]` ∧ `rd_is_fp[s]` → `{busy:1, tag}`
  - **每拍至多一笔**，故只需 **1 个写口**：上游的有效接收集合一拍至多含一条触碰 FP RF
      的指令；两个候选同时为 FP 时 slot1 不产生消费者
- **commit[k]** = `commit_valid[k]` ∧ `rd_write_enable[k]` ∧ `rd_is_fp[k]`
  ∧ `entry[rd_idx[k]].tag == commit_tag[k]` → `busy ← 0`
  - **`tag` 相等这一项不可省**：该格可能已被更年轻的指令重命名
    - **1 个清除口**：双FP提交阻塞 > 依据：[[CompletionScoreboard微架构文档.md]] ④ 第三步
- **flush** = `global_flush_late` → 所有 entry 回到 IDLE，`busy ← 0`
- **写口次序**：commit 先 → 同格上更年轻的 alloc 覆盖它 → flush 压掉 alloc，全表回 IDLE

**端口数**：双FP指令阻塞 > 依据：[[dispatch_logic微架构文档.md]] ④

### ④ data path

#### 1. `entry.tag` / `entry.busy`

```text
alloc 输入端口             → entry[rd_idx[s]]   self_tag[s] → idx 的 tag
entry[fp_read_idx[1:3]]   → 读出端口            tag、busy（3 读口）
```

commit 只写 `busy ← 0`、`tag` 不动，载荷宽度为零，不构成一条运值边。

### ⑤ data structure（schema + 字段三角色）

- **state**：`busy`
- **header**：`tag`——`alloc` 写入；`commit` 拿它跟 `commit_tag` 比对
- **payload**：**无**

### ⑥ 接口

**in-event** `→ FP_tag_mapping`

- alloc（announce，**1 写口**）
  - move；`self_tag[s]`(4，s∈{0,1}) —— 存入 `entry[rd_idx[s]]` 的 `tag`
    - broadcast；`rd_write_enable[s]`(1，s∈{0,1})、`rd_is_fp[s]`(1，s∈{0,1}) —— 只进本模块 ③ 的 alloc判定
    - 地址；`rd_idx[s]`(5，s∈{0,1}) —— 写第几entry

- commit（announce，**1 清除口**）
  - broadcast；`commit_tag[k]`(4，k∈{0,1})、`rd_is_fp[k]`(1，k∈{0,1})、`rd_write_enable[k]`(1，k∈{0,1})
      —— 只进本模块 ③ 的清除判定，`commit_tag[k]` 与entry内 `tag` 比对
    - 触发；`commit_valid[k]`(1，k∈{0,1}) —— 本拍是否触发合法commit（双FP提交阻塞保证至多一笔）
    - 地址；`rd_idx[k]`(5，k∈{0,1}) —— 清第几entry的 `busy`

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，`busy`全清

- 组合读(in)
  - 地址；`fp_read_idx[1:3]`(5×3) —— 三个读口

**out-event** `FP_tag_mapping →`

- 组合读(out)；`tag`(4)、`busy`(1)

**Static Info：**

无。
