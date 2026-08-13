# PCFile · 16 格 × 64 位 · 按 tag 索引，每格只存 `inst_pc`

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `entry.inst_pc`

```text
write 输入端口      → entry[self_tag[s]]   pc
entry[flush_tag]   → 读出端口              inst_pc
```

- **写无本地 guard**：地址与使能都由上游给，本模块不复判；每拍至多 2 笔。
  **flush 拍也不挂 guard**——上游已取消 alloc，本模块无须自己挡
- **读无 fire 判据**：给 tag 当拍给出 `inst_pc`。只有活 tag 会被读，**本模块不判活不活**
- 读不破坏，同一格可被读多次直到被重分配覆盖
- **flush 不动本表**：指针退回后落在有效范围外的记录不再被读，由后续 dispatch 整格覆盖

### ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：**无**——本模块不做任何判断
- **payload**：`inst_pc`(64)。`write` 写入即定，直到同一个 tag 被重新分配时整格覆盖

### ⑥ 接口

**in-event** `→ PCFile`

- write（Transaction，**2 写口**，per slot；无反压——tag 可用性由上游保证）
  - move；`pc[s]`(64，s∈{0,1}) —— 存进 `entry[self_tag[s]]` 的 `inst_pc`
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 写第几格

- 组合读(in)
  - 地址；`flush_tag`(4) —— 恢复读口的下标

**out-event** `PCFile →`

- 组合读(out)；`inst_pc`(64)

**Static Info：**

无。
