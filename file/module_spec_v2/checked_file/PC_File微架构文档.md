# PCFile · 16 Entry × 64 bit

### ① per-entry state

**无**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `entry.inst_pc`

```text
write 输入端口      → entry[self_tag[s]]
entry[flush_tag]   → 读出端口
```

### ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：无
- **payload**：`inst_pc`(64)。`write` 写入，直到同一个 tag 被重新分配时整格覆盖

### ⑥ 接口

**in-event** `→ PC_File`

- write（Announce，**2 写口**，per slot；无反压）
    - move；`pc[s]`(64，s∈{0,1}) —— 存进 `entry[self_tag[s]]` 的 `inst_pc`
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 写第几格

- 组合读(in)
    - 地址；`flush_tag`(4) —— 恢复读口pointer

**out-event** `PC_File →`

- 组合读(out)；`inst_pc`(64)


**Static Info**

无。
