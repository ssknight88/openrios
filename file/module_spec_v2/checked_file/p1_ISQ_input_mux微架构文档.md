# p1_ISQ_input_mux · 纯组合 · payload 二选一

**按 group 实例化 4 份**，每份服务一个 `ISQ_Group`。四份**结构完全相同**——
差别只在连接：第 g 份收 `select_payload[g][0/1]`，输出接 `ISQ_Group_g`。


两个候选 slot 的**完整 `ISQ_Payload`** 由上游装配好送来，本模块只按选通码二选一，
不做任何字段加工，也不做字段裁剪——裁剪在下游 entry 侧（见各 `ISQ_Group` 的 ⑤）。

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `ISQ_payload_in`(output)

```text
ISQ_payload_in = select_payload[0] ? slot_payload[0]
               : select_payload[1] ? slot_payload[1]
               : '0
```

- `select_payload[0/1]` 对本实例是 **onehot0**：两位皆 0 表示本拍本组无候选，输出全零
- 两个候选 slot 同时映射到同一组时，上游置 `select_payload[1] = 0`、固定保留 slot0；
  同一条件下 `groups_distinct = 0` 会使 slot1 不被接受，因此不会写入本组


### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ p1_ISQ_input_mux`

- 组合读(in)
    - broadcast；`slot_payload[0]`、`slot_payload[1]` —— 完整 `ISQ_Payload` ×2，原样转发不加工
    - 选通；`select_payload[0/1]`(1×2) —— onehot0，二选一挑 slot payload；两位皆 0 则输出全零

**out-event** `p1_ISQ_input_mux →`

- 组合读(out)；`ISQ_payload_in` —— 完整 `ISQ_Payload`

**Static Info**

无。
