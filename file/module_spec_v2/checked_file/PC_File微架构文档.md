# PC_File · 16 entry × 64 bit

### ① per-entry state

**无**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

```text
pc_write[s] = accept[s]
```

- `pc_write[s]` 与 CompletionScoreboard 的 `alloc[s]` 同拍同 slot；只有被接受并分配
  `self_tag[s]` 的指令才写入 `inst_pc`，从而保持 `PC_File[tag]` 与 SCB 生命周期一致。

### ④ data path

#### 1. `entry.inst_pc`

```text
pc_write[s]          → entry[self_tag[s]]    pc[s]
entry[flush_tag]   → 恢复读出端口
entry[head0_tag]   → trace 读出端口
entry[head1_tag]   → trace 读出端口
```

三个读口互相独立、同拍并发，读地址各由对端给，本模块不做仲裁。
两个 trace 读口只旁路读出，不影响存储内容与写入次序。

### ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：无
- **payload**：`inst_pc`(64)。`write` 写入，直到同一个 tag 被重新分配时整格覆盖

### ⑥ 接口

**in-event** `→ PC_File`

- write（Announce，**2 写口**，per slot；无反压）
    - move；`pc[s]`(64，s∈{0,1}) —— 存进 `entry[self_tag[s]]` 的 `inst_pc`
    - 触发；`accept[s]`(1，s∈{0,1}) —— 即 `pc_write[s]`，本拍该 slot 是否已被接收并分配 tag
    - 地址；`self_tag[s]`(4，s∈{0,1}) —— 写第几格

- 组合读(in)
    - 地址；`flush_tag`(4) —— 恢复读口pointer
    - 地址；`head0_tag`(4)、`head1_tag`(4) —— 提交点 trace 读口 ×2

**out-event** `PC_File →`

- 组合读(out)；`inst_pc`(64) —— `flush_tag` 口
- 组合读(out)；`trace_pc[k]`(64×2) —— `head0_tag` / `head1_tag` 口，
  随 `commit_valid[k]` 有效


**Static Info**

无。
