# PCFile · 16 Entry × 64 bit

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

```text
pc_write[s] = accept[s]
```

- `pc_write[s]` 与 CompletionScoreboard 的 `alloc[s]` 同拍同 slot；只有被接受并分配
  `self_tag[s]` 的指令才写入 `inst_pc`，从而保持 `PC_File[tag]` 与 SCB 生命周期一致。

## ④ data path

### 1. `entry.inst_pc`

```text
pc_write[s]          → entry[self_tag[s]]    pc[s]
entry[flush_tag]   → 读出端口
```

## ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：无
- **payload**：`inst_pc`(64)。`write` 写入，直到同一个 tag 被重新分配时整格覆盖

## ⑥ 接口

**in-event** `→ PC_File`

- write（Announce，**2 写口**，per slot；无反压）
  - move；`pc[s]`(64，s∈{0,1}) —— 存进 `entry[self_tag[s]]` 的 `inst_pc`
    - 触发；`accept[s]`(1，s∈{0,1}) —— 即 `pc_write[s]`，本拍该 slot 是否已被接收并分配 tag
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 写第几格

- 组合读(in)
  - 地址；`flush_tag`(4) —— 恢复读口pointer

**out-event** `PC_File →`

- 组合读(out)；`inst_pc`(64)

**Static Info：**

无。
