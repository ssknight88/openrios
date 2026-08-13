# INT_DST_REG · 32 格 · 整数重命名表，每格 `{busy, tag}`

## ① per-entry state

`FREE / BUSY`

- 就是 `busy` 一位。逐格存，无指针
- **entry 0 硬连 `{busy:0, tag:0}`**：alloc / commit-clear / flush 都不写它，永远读作就绪。
  `tag` 也接 0 而不是悬空，免得传出 X
- 因为 entry 0 硬连，整数 `x0` 走的是普通解析路径（`busy = 0` → 读 ARF → 0），
  源解析逻辑里**没有 `x0` 特例**

## ② state transition & condition（event 名）

- FREE → BUSY：alloc
- BUSY → FREE：commit-clear
- BUSY → BUSY：alloc（同一格被更年轻的指令重命名，只换 `tag`，不是阶段转移）
- ANY → FREE：flush

## ③ condition 细化

- **alloc[s]** = `accept[s]` ∧ `rd_write_enable[s]` ∧ `!rd_is_fp[s]` → `{busy:1, tag}`
  - **同拍 WAW**：两个 slot 写同一格时，次态留**更年轻**那个（slot1）的 `tag`
- **commit-clear[k]** = `commit_valid[k]` ∧ `rd_write_enable[k]` ∧ `!rd_is_fp[k]`
  ∧ `rd_idx[k] != 0` ∧ `entry[rd_idx[k]].tag == commit_tag[k]` → `busy ← 0`
  - **`tag` 相等这一项不可省**：该格可能已被更年轻的指令重命名，
      此时清了就会放行一个还在飞的依赖
- **flush** = `global_flush_late` → 所有 entry 回到 FREE，`busy ← 0`
- **写口次序**：commit-clear 先 → 同格上更年轻的 alloc 覆盖它 → flush 压掉 alloc，全表回 FREE
  - 结果是同拍里更年轻的 alloc 赢过 tag 命中的 commit-clear，
      而那条提交在架构上仍然生效

## ④ data path

### 1. `entry.tag` / `entry.busy`

```text
alloc 输入端口              → entry[rd_idx[s]]   self_tag[s] → entry 的 tag
entry[slot0/1.rs1/2_idx]   → 读出端口            tag、busy（4 读口）
```

commit-clear 只写 `busy ← 0`、`tag` 不动，载荷宽度为零，不构成一条运值边。

## ⑤ data structure（schema + 字段三角色）

- **state**：`busy`
- **header**：`tag`——`alloc` 写入即定；`commit-clear` 拿它跟 `commit_tag` 比对
- **payload**：**无**

## ⑥ 接口

**in-event** `→ INT_DST_REG`

- alloc（Transaction，**2 写口**，per slot）
  - move；`self_tag[s]`(4，s∈{0,1}) —— 存入 `entry[rd_idx[s]]` 的 `tag`
    - broadcast；`rd_write_enable[s]`(1，s∈{0,1})、`rd_is_fp[s]`(1，s∈{0,1}) —— 只进本模块 ③ 的 alloc guard
    - 地址；`rd_idx[s]`(5，s∈{0,1}) —— 写第几格

- commit-clear（announce，**2 清除口**）
  - broadcast；`commit_tag[k]`(4，k∈{0,1})、`rd_is_fp[k]`(1，k∈{0,1})、`rd_write_enable[k]`(1，k∈{0,1})
      —— 只进本模块 ③ 的清除 guard，`commit_tag[k]` 与格内 `tag` 比对
    - 触发；`commit_valid[k]`(1，k∈{0,1}) —— 本拍这个 lane 要不要清
    - 地址；`rd_idx[k]`(5，k∈{0,1}) —— 清第几格的 `busy`

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，全表清 `busy`，无载荷

- 组合读(in)
  - 地址；`slot0/1.rs1/2_idx`(5×4) —— 四个读口的下标

**out-event** `INT_DST_REG →`

- 组合读(out)；`tag`(4)、`busy`(1)

**Static Info：**

无。
