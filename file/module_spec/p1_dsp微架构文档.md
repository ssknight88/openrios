# p1_dsp · 纯组合 · guard 汇总与最终准入

P1 的最终准入边界：汇总 Buffer、ISQ、CSR、flush、FP 配对和 missed-wakeup guard，
**唯一生成 `accept[0/1]`**。保持纯组合 fire 语义，本边界不插 pipeline register。

## ① per-entry state

**无。** 纯组合，无存储。

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。** 零状态，无 FSM。全部组合逻辑见 ④。

## ④ data path

本模块无存储，只列推导。

### 1. `accept[0]` / `accept[1]`(output)

```text
serial0_ok = !serial0 ∨ buffer_empty

slot0_guard_ok =
      can_alloc_1
    ∧ isq_free_for_dispatch[slot_ISQGroup[0]]
    ∧ !csr_inflight_valid
    ∧ serial0_ok
    ∧ !slot_missed_wakeup[0]
    ∧ !global_flush_late

slot0_fire_candidate = slot0_present ∧ slot0_guard_ok
accept[0]            = slot0_fire_candidate

slot1_guard_ok =
      can_alloc_2
    ∧ isq_free_for_dispatch[slot_ISQGroup[1]]
    ∧ groups_distinct
    ∧ !(fp0 ∧ fp1)
    ∧ !serial_inst
    ∧ !slot_missed_wakeup[1]
    ∧ !global_flush_late

accept[1] = accept[0] ∧ slot1_present ∧ slot1_guard_ok
```

- **双FP指令阻塞**：`slot1_guard_ok` 中的 `!(fp0 ∧ fp1)` 即双FP指令阻塞（同拍两 slot 不得同时为 FP）。
- 由定义得 **`accept[1] ⇒ accept[0]`**，故 `10` 这种接受组合被结构排除；
  `accept[0] = 0` 时 slot1 的 group、源解析结果与 payload 即使有组合值也不形成任何状态更新
- **采样约定（两者相反，不可类推）**：`can_alloc_1` / `can_alloc_2` / `buffer_empty` 是
  Buffer 的**拍初值**；`isq_free_for_dispatch` **含同拍 `issue`**
- `global_flush_late` 只屏蔽当拍新 fire，本模块不保存 flush 状态
- `serial0_ok` / `slot0_guard_ok` / `slot1_guard_ok` 是内部中间量，无跨界消费者

### 2. `ib_dequeue[s]` / `isq_wr_en[g]` / `set`(output)

```text
ib_dequeue[s] = accept[s]
isq_wr_en[g]  = (accept[0] ∧ select_payload[g][0]) ∨ (accept[1] ∧ select_payload[g][1])
set           = accept[0] ∧ serial0
```

## ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

## ⑥ 接口

**in-event** `→ p1_dsp`

- 组合读(in)
  - broadcast；`slot0_present`(1)、`slot1_present`(1)、`serial0`(1)、`serial_inst`(1)、
      `fp0`(1)、`fp1`(1)、`slot_missed_wakeup[0/1]`(1×2) —— 全部进 ④ 的准入 guard
    - broadcast；`groups_distinct`(1) —— 进 `slot1_guard_ok`
    - broadcast；`can_alloc_1`(1)、`can_alloc_2`(1)、`buffer_empty`(1)（**拍初值**）
    - broadcast；`isq_free_for_dispatch[G0..G3]`(1×4)（**含同拍 issue**）
    - broadcast；`csr_inflight_valid`(1) —— 串行指令在飞时挡死全部派发
    - 选通；`slot_ISQGroup[0/1]`(2×2) —— 每个 slot 该进哪个 ISQ 实例
    - 选通；`select_payload[G0..G3][0/1]`(1×8) —— group × slot 的 onehot0，
      本模块据此把 `accept[s]` 译码成 `isq_wr_en[g]`

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，本拍屏蔽全部 accept，无载荷

**out-event** `p1_dsp →`

- `accept[s]`；`accept[s]`(1×2)
- `ib_dequeue[s]`；`ib_dequeue[s]`(1×2)
- `isq_wr_en[g]`；`isq_wr_en[g]`(1×4)
- `set`；`set`(1)
- 组合读(out)；`slot0_fire_candidate`(1)

四条自产信号的推导与 ready 吸收关系见 ④，本节不重复。

**Static Info：**

无。
