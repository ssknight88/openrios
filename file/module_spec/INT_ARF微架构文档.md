# INT_ARF · 32 格 × 64 位 · 整数架构寄存器堆

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `entry.ARF`

```text
write 输入端口              → entry[rd_idx[k]]   result_data
entry[slot0/1.rs1/2_idx]   → 读出端口            ARF 值
```

### 2. `write[k]`(写使能)

```text
write[k] = commit_valid[k] ∧ rd_write_enable[k] ∧ !rd_is_fp[k] ∧ rd_idx[k] != 0
```

- **只有提交能写**。执行完成写的是别处，不进这里；写进这里就等于让投机结果落到架构状态上
- 同拍两条写同一格是可能的（WAW），次态留更年轻那条
- `rd_idx != 0` 是**冗余保险**：上游的 `rd_write_enable` 已在重命名时抑制了 INT `x0` 的写。
  它与"entry 0 硬连 0"、重命名表 entry 0 的硬连**是三重独立防线，三者都保留**
- **读无 fire 判据**，读地址由上游直连驱动。
  `rs3` 永不走 INT（上游契约 `use_rs3[s] ⇒ rs3_is_fp[s]`），故只有 4 个读口
- **flush 不动本表**：架构状态没有投机成分，无可回滚

## ⑤ data structure（schema + 字段三角色）

- **state**：无
- **header**：**无**——写使能全部在本模块的 ④ 里本地评估，不落进 entry
- **payload**：`ARF[idx]`(64)。`write` 写入；`entry 0` 恒为 0

## ⑥ 接口

**in-event** `→ INT_ARF`

- commit（announce，**2 写口**）
  - move；`result_data[k]`(64，k∈{0,1}) —— 写进 `entry[rd_idx[k]]`
    - broadcast；`rd_is_fp[k]`(1，k∈{0,1})、`rd_write_enable[k]`(1，k∈{0,1}) —— 只进本模块 ④ 的写使能判据
    - 触发；`commit_valid[k]`(1，k∈{0,1}) —— 本拍这个 lane 要不要写
    - 地址；`rd_idx[k]`(5，k∈{0,1}) —— 写第几格

- 组合读(in)
  - 地址；`slot0/1.rs1/2_idx`(5×4) —— 四个读口的下标

**out-event** `INT_ARF →`

- 组合读(out)；`ARF[idx]`(64)

**Static Info：**

无。
