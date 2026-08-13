# dispatch_logic

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. Slot选择ISQ_Group：`slot_ISQGroup[0/1]`

**第一步 · route_class 映射**——左列 `route_class` 是选组的**输入**；右两列是查表**输出**。
`FU_Group` 只是组内 FU 编号（ALU/BRU/FPU/LSU 全是 0），**不能当选组的选择子**。

```text
ALU         slot_ISQGroup ∈ {G0, G1}    FU_Group = 0    ← 唯一动态类；G0/G1 迁移不改 FU_Group
BRU         slot_ISQGroup = G0          FU_Group = 0
CSR         slot_ISQGroup = G0          FU_Group = 1
DIV         slot_ISQGroup = G0          FU_Group = 2
MUL         slot_ISQGroup = G1          FU_Group = 1
FPU         slot_ISQGroup = G2          FU_Group = 0
LSU         slot_ISQGroup = G3          FU_Group = 0
```

**第二步 · 选组**——两条 slot 各一行，无函数抽象

```text
slot_ISQGroup[0] = (route_class[0] == ALU) ? (isq_free_for_dispatch[G0] ? G0 : G1)
                                           : 第一步表中的固定组

slot0_takes_G0   = slot0_fire_candidate ∧ (slot_ISQGroup[0] == G0)
                   // 当拍 ISQ_G0 还空着，但 slot0 本拍将写入；
                   // slot0 发不出去（candidate=0）就不算占

slot_ISQGroup[1] = (route_class[1] == ALU)
                     ? ((isq_free_for_dispatch[G0] ∧ !slot0_takes_G0) ? G0 : G1)
                     : 第一步表中的固定组

groups_distinct  = (slot_ISQGroup[1] != slot_ISQGroup[0])
```

**分工**：选组只回答"该去哪"，永远给出确定编号——ALU 在 G0/G1 **都满时照样报 G1**，撞组由 `groups_distinct` 阻拦。

#### 2. `accept[0]` / `accept[1]`(output)

```text
serial0_ok = !serial0 ∨ buffer_empty

slot0_guard_ok =
      can_alloc_1
    ∧ isq_free_for_dispatch[slot_ISQGroup[0]]
    ∧ !serial_inflight_valid
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

- **双FP指令阻塞**：`slot1_guard_ok` 中的 `!(fp0 ∧ fp1)` 即双FP指令阻塞（同拍两 slot 不得同时为 FP）
- 由定义得 **`accept[1] ⇒ accept[0]`**，故 `10` 这种接受组合被结构排除；
  `accept[0] = 0` 时 slot1 的 group、源解析结果与 payload 即使有组合值也不形成任何状态更新
- `can_alloc_1` / `can_alloc_2` / `buffer_empty` 是
  CompletionScoreboard 的**拍初值**；`isq_free_for_dispatch` **含同拍 `issue`**

- `global_flush_late` 只屏蔽当拍新 fire，本模块不保存 flush 状态
- `serial0_ok` / `slot0_guard_ok` / `slot1_guard_ok` / `slot0_fire_candidate` /
  `slot_ISQGroup` / `groups_distinct` 全部是内部中间量，无跨界消费者

#### 3. `select_payload[G0..G3][0/1]`(output)

```text
select_payload[g][0] = (slot_ISQGroup[0] == g)
select_payload[g][1] = groups_distinct ∧ (slot_ISQGroup[1] == g)
```

#### 4. `ib_dequeue[s]` / `isq_wr_en[g]` / `serial_set`(output)

```text
ib_dequeue[s] = accept[s]
isq_wr_en[g]  = (accept[0] ∧ select_payload[g][0]) ∨ (accept[1] ∧ select_payload[g][1])
serial_set    = accept[0] ∧ serial0
```

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ dispatch_logic`

- 组合读(in)
    - broadcast；`slot0_present`(1)、`slot1_present`(1)、`serial0`(1)、`serial_inst`(1)、
      `fp0`(1)、`fp1`(1)、`slot_missed_wakeup[0/1]`(1×2) —— 全部进 ④#2 的准入 guard
    - 选通；`route_class[0/1]`(3×2) —— 选组的选择子：动态类（ALU）还是走第一步表的固定映射
    - broadcast；`can_alloc_1`(1)、`can_alloc_2`(1)、`buffer_empty`(1)（**拍初值**）
    - broadcast；`isq_free_for_dispatch[G0..G3]`(1×4)（**含同拍 issue**）
    - broadcast；`serial_inflight_valid`(1) —— 串行指令在飞时全部stall
    - broadcast；`self_tag[0]`(4) 仅作为 `serial_set` 的 payload

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，本拍屏蔽全部 accept

**out-event** `dispatch_logic →`

- `accept[s]`；`accept[s]`(1×2)
- `ib_dequeue[s]`；`ib_dequeue[s]`(1×2)
- `isq_wr_en[g]`；`isq_wr_en[g]`(1×4)
- `serial_set`；`serial_set`(1)、`self_tag[0]`(4) —— 本模块产生 trigger，转发该 tag 给
  SerialInstructionTracker
- 组合读(out)；`select_payload[G0..G3][0/1]`(1×8) —— 对端 p1_ISQ_input_mux ×4

**Static Info**

无。


