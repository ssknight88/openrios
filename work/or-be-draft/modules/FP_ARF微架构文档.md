# FP_ARF · 32 entry × 64 bit

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `entry.ARF`

```text
write 输入端口             → entry[rd_idx[k]]   commit_data
entry[fp_read_idx[1:3]]   → 读出端口            ARF 值
```

### 2. `write[k]`(写使能)

```text
write[k] = commit_valid[k] ∧ rd_write_enable[k] ∧ rd_is_fp[k]
```

- **只有提交能写**
- **单写口反过来约束提交侧**：双FP提交阻塞 > 依据：[[CompletionScoreboard微架构文档.md]] ④ 第三步
- **读无 fire 判据**，读地址由 `fp_read_idx[1:3]` 驱动
- **3 读口够用**：双FP指令阻塞 > 依据：[[dispatch_logic微架构文档.md]] ④
- **flush 不动本表**

## ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：**无**
- **payload**：`ARF[idx]`(64)。`write` 写入

## ⑥ 接口

**in-event** `→ FP_ARF`

- commit（announce，**1 写口**）
  - move；`commit_data[k]`(64，k∈{0,1}) —— 写进 `entry[rd_idx[k]]`
    - broadcast；`rd_is_fp[k]`(1，k∈{0,1})、`rd_write_enable[k]`(1，k∈{0,1}) —— 只进本模块 ④ 的写使能判据
    - 触发；`commit_valid[k]`(1，k∈{0,1}) —— 本拍要不要写（双FP提交阻塞保证至多一笔）
    - 地址；`rd_idx[k]`(5，k∈{0,1}) —— 写第几格

- 组合读(in)
  - 地址；`fp_read_idx[1:3]`(5×3) —— 三个读口的idx

**out-event** `FP_ARF →`

- 组合读(out)；`ARF[idx]`(64)

**Static Info：**

无。
