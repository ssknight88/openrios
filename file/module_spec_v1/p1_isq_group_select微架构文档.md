# p1_isq_group_select · 纯组合 · route_class 到 ISQ group 的选择

只负责 slot → ISQ group 的组合映射和同拍 group 资源扣除。
不产生准入 event，不修改 `FU_Group`，也不搬运 payload。

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `slot_ISQGroup[0/1]` / `groups_distinct`(output)

**第一步 · route_class 映射**

```text
select_group(route_class, free_view) =
    route_class == INT_ALU ? (free_view[G0] ? G0 : G1)
                           : fixed_group(route_class)

fixed_group：BRU / MRET / CSR / DIV → G0    MUL → G1    FPU → G2    LSU → G3
```

固定类别的 `FU_Group` 由上游按下表携带，本模块**不重写**：

```text
INT_ALU     slot_ISQGroup ∈ {G0, G1}    FU_Group = 0
BRU / MRET  slot_ISQGroup = G0          FU_Group = 0
CSR         slot_ISQGroup = G0          FU_Group = 1
DIV         slot_ISQGroup = G0          FU_Group = 2
MUL         slot_ISQGroup = G1          FU_Group = 1
FPU         slot_ISQGroup = G2          FU_Group = 0
LSU         slot_ISQGroup = G3          FU_Group = 0
```

`select_group` 只返回确定的 group 编号，**不返回额外 valid**：固定 group 不可用时仍返回其固定编号，
INT_ALU 在 G0、G1 都不可用时确定返回 G1——两种情形都由下游的 `isq_free_for_dispatch` guard 否决。

**第二步 · slot0 / slot1 两级选择**

```text
slot_ISQGroup[0]         = select_group(route_class[0], isq_free_for_dispatch)

free_view_after_slot0[g] = isq_free_for_dispatch[g]
                         ∧ !(slot0_fire_candidate ∧ (g == slot_ISQGroup[0]))

slot_ISQGroup[1]         = select_group(route_class[1], free_view_after_slot0)

groups_distinct          = (slot_ISQGroup[1] != slot_ISQGroup[0])
```

- **采样约定**：`isq_free_for_dispatch[g]` **含同拍 `issue`**，
  与 Buffer 的 `can_alloc_1/2`、IB 的 `room_q`（两者皆拍初值）**取相反约定，不可类推**
- slot0 用**未扣除**的原始投影，slot1 用**扣除 slot0 实际准入 group 后**的 `free_view_after_slot0`
- `groups_distinct` 约束的是**实际生成的 group 编号**，不是 IB 携带的静态类别
- `FU_Group` 始终是组内 FU 索引，INT_ALU 在 G0/G1 迁移时仍保持索引 0
- **无环约束**：`slot0_fire_candidate` 是 slot0-only 的准入预判，本模块只把它当输入用。
  它**不得**依赖 `slot_ISQGroup[1]`、`groups_distinct` 或最终 `accept[1]`——
  否则本模块与其产生方之间形成组合环

#### 2. `select_payload[G0..G3][0/1]`(output)

```text
select_payload[g][0] = (slot_ISQGroup[0] == g)
select_payload[g][1] = groups_distinct ∧ (slot_ISQGroup[1] == g)
```

对每个 group 是 **onehot0** 的组合选择码，**不是 valid、也不是 write enable**。
group 冲突时固定保留 slot0 作为候选；`groups_distinct = 0` 同时阻止 slot1 准入。

本模块**不产生** group 级 write enable。

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ p1_isq_group_select`

- 组合读(in)
    - 选通；`route_class[0/1]`(3×2) —— 决定走动态 INT 选组还是 `fixed_group()` 固定映射
    - broadcast；`isq_free_for_dispatch[G0..G3]`(1×4) —— 选组时避开已占用的组
      （**含同拍 issue**）
    - broadcast；`slot0_fire_candidate`(1) —— slot1 选组时要知道 slot0 会不会占位

**out-event** `p1_isq_group_select →`

- 组合读(out)；`slot_ISQGroup[0/1]`(2×2)、`groups_distinct`(1)、
  `select_payload[G0..G3][0/1]`(1×8)

**Static Info**

无。
