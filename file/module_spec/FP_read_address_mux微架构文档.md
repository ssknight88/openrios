# FP_read_address_mux · 纯组合 · 6 个候选地址 → 3 个 FP 读口

两个候选 slot 共有 6 个可能的 FP 源地址（`slot0/1.rs1/2/3_idx`），而 FP 侧只有 3 个读口。
本模块做这个收缩，其输出**同时驱动 FP_ARF 与 FP_DST_REG 的读地址口**。

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `fp_read_idx[1:3]`(output)

```text
fp_read_idx[k] = is_fp_instruction[0] ? slot0.rs{k}_idx : slot1.rs{k}_idx     k ∈ {1,2,3}
```

- 选通位**只有 `is_fp_instruction[0]` 一个**，slot1 的那一位不参与
- **无环约束**：**不得**改用 `accept[0/1]` 作选通位——那会形成
  `accept → 读地址 → 源解析 → accept` 的组合环
- **不做 `rsX_is_fp` 过滤**：`is_fp_instruction` 的含义是"**触碰** FP RF"，不是"所有源都在 FP RF"。
  `FLD` 的 `rs1` 是 INT 基址、`FSD` 的 `rs1` 是 INT 基址而 `rs2` 才是 FP 数据——
  这两种情形下本模块照常把 `rs1_idx` 送到 FP 侧，读出的值不会被采用
  （下游按 `rsX_is_fp[s]` 决定取 INT 还是 FP 侧）

**有效消费者唯一**——3 个读口服务 2 个 slot 的自洽性依据：

```text
设被接受的 slot s 有 rsX_is_fp[s] = 1。
由上游契约「触碰 FP RF ⇒ is_fp_instruction 为真」得 is_fp_instruction[s] = 1：
    s = 0 ⇒ 选通位 = 1                              ⇒ 选中 slot0 ✓
    s = 1 ⇒ 由双FP指令阻塞，同拍两 slot 不同时为 FP
          ⇒ 选通位 = 0                              ⇒ 选中 slot1 ✓
∴ 被接受的那个 FP slot 必然就是本模块选中的那个。
```

另两种情形不产生消费者：选通位为 1 但 slot0 未被接受时，由 `accept[1] ⇒ accept[0]` 得两个 slot
都没被接受；两位都为 0 时本拍没有任何 FP 源需要解析。

## ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

## ⑥ 接口

**in-event** `→ FP_read_address_mux`

- 组合读(in)
  - broadcast；`slot0/1.rs1/2/3_idx`(5×6) —— 6 个候选地址，本模块从中收缩出 3 个
    - 选通；`is_fp_instruction[0]`(1) —— 二选一，决定把 slot0 还是 slot1 的 rs 索引送出

**out-event** `FP_read_address_mux →`

- 组合读(out)；`fp_read_idx[1:3]`(5×3，读地址)

**Static Info：**

无。
