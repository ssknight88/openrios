# Module `dispatch_logic`

`dispatch_logic`：2-slot dispatch 的准入、路由和 ISQ 选择组合逻辑（`ISSUE_WIDTH=2`、`NUM_GROUP=4`、`FU_GROUP_W=2`、`TAG_W=4`、`EXE_SUBOP_W=24`）。

## Submodule

无。

## FSM

### State

#### Per-entry State

无。

### State Transition & Condition Name

无。

### Detailed Condition Description

无。

## Data structure

### State

无。

### Header

无。

### Payload

无。

## Data Path

- `decode` static info -> `dispatch_route_class[s]`：`exe_subop/full_decode/is_fp_instruction`；组合路由。
- `dispatch_route_class[s]`、dependency static info、scoreboard static info、ISQ credit -> `accept[s]`：组合准入。
- `accept[s]`、`slot_ISQGroup[s]` -> `ib_dequeue_request[s]`：控制 Static Info。
- `accept[s]`、`slot_ISQGroup[s]` -> `isq_select_request[g]`：控制 Static Info。
- `accept[0]`、`serial0`、`self_tag[0]` -> `serial_set_request`、`serial_set_tag`：控制 Static Info。
- `full_decode[s].rm`、`frm` -> `effective_rm[s]`：3-bit rounding-mode Static Info。

## Interface

### In-event

无。

### In Static Info

- `slot_present[s]`：2 slot；head payload 是否存在。
- `serial0`、`serial_inst`：1 bit；serial 指令属性。
- `fp0`、`fp1`、`is_fp_instruction[s]`：2 slot；FP 指令属性。
- `slot_missed_wakeup[s]`：1 bit x 2；missed-wakeup 状态。
- `exe_subop[s]`：`EXE_SUBOP_W=24 bit` x 2；执行子码。
- `full_decode[s]`：`FULL_DECODE_W=17 bit` x 2；illegal/rm/CSR 控制字段。
- `fs_enabled`：1 bit；FP 状态允许标志。
- `frm`：`rm_e=3 bit`；当前动态舍入模式。
- `can_alloc_1`、`can_alloc_2`、`buffer_empty`：1 bit；scoreboard 分配条件。
- `isq_free_for_dispatch[g]`：1 bit x 4；ISQ group 当前 credit。
- `serial_inflight_valid`：1 bit；serial tracker 当前状态。
- `self_tag[0:1]`：`TAG_W=4 bit` x 2；分配 tag。
- `global_flush_late`：1 bit；flush 当拍屏蔽条件。

### Out-event

无。

### Out Static Info

- `accept[s]`：1 bit x 2；当前 slot 是否被 dispatch 接收。
  - `slot0_guard_ok`：slot0 的全部准入条件。
    - `slot0_guard_ok = subop_supported_now[0] ∧ can_alloc_1 ∧ isq_free_for_dispatch[slot_ISQGroup[0]] ∧ ¬serial_inflight_valid ∧ serial0_ok ∧ ¬slot_missed_wakeup[0] ∧ ¬global_flush_late`
  - `accept[0] = slot_present[0] ∧ slot0_guard_ok`
  - `slot1_guard_ok`：slot1 的全部准入条件。
    - `slot1_guard_ok = subop_supported_now[1] ∧ can_alloc_2 ∧ isq_free_for_dispatch[slot_ISQGroup[1]] ∧ groups_distinct ∧ ¬(fp0 ∧ fp1) ∧ ¬serial_inst ∧ ¬slot_missed_wakeup[1] ∧ ¬global_flush_late`
  - `accept[1] = accept[0] ∧ slot_present[1] ∧ slot1_guard_ok`
  - `serial0_ok`：slot0 为 serial 指令时是否满足 buffer empty；`serial0_ok = ¬serial0 ∨ buffer_empty`。
  - `groups_distinct`：两个 slot 的目标 group 是否不同；`groups_distinct = slot_ISQGroup[1] != slot_ISQGroup[0]`。
- `ib_dequeue_request[s]`：1 bit x 2；`accept[s]`。
- `isq_select_request[g]`：1 bit x 4；`select_payload[g][0] ∨ select_payload[g][1]`。
- `serial_set_request`：1 bit；`accept[0] ∧ serial0`。
- `serial_set_tag`：`TAG_W=4 bit`；`self_tag[0]`。
- `slot_FU_Group[s]`：`FU_GROUP_W=2 bit` x 2；route 对应的 group 内 FU 编号。
- `slot_ISQGroup[s]`：group index x 2；ALU split 和 fixed route 选择结果。
- `effective_rm[s]`：`rm_e=3 bit` x 2；`full_decode[s].rm == RM_DYN ? frm : full_decode[s].rm`。
- `is_fence_i[s]`：1 bit x 2；`exe_subop[s] == SUBOP_FENCEI`。
- `may_flush[s]`：1 bit x 2；`may_flush_before_resolution(exe_subop[s], illegal_effective[s])`。
- `is_atomic[s]`：1 bit x 2；`is_g3_atomic_subop(exe_subop[s])`。
- `select_payload[g][s]`：1 bit x 4 x 2；`accept[s] ∧ (slot_ISQGroup[s] == g)`；每个 group 满足 onehot0。
- `illegal_effective[s]`：指令是否因 decode 或当前 FP 状态非法。
    - `frm_illegal = frm in {RM_RSV5, RM_RSV6, RM_DYN}`
    - `rm_illegal[s] = uses_rm(exe_subop[s]) ∧ (rm_is_reserved(full_decode[s].rm) ∨ (full_decode[s].rm == RM_DYN ∧ frm_illegal))`
    - `fp_illegal[s] = is_fp_instruction[s] ∧ (¬fs_enabled ∨ rm_illegal[s])`
    - `illegal_effective[s] = full_decode[s].illegal ∨ fp_illegal[s]`
- `dispatch_route_class[s]`：按优先级选择 `ROUTE_BRU`、`ROUTE_UNSUPPORTED`、`ROUTE_ATOMIC`、`ROUTE_FENCE`、`ROUTE_LSU`、`ROUTE_SYS`、`ROUTE_CSR`、`ROUTE_DIV`、`ROUTE_MUL`、`ROUTE_FPU` 或 `ROUTE_ALU`。
- `fixed_group[s]`：MUL -> G1，FPU -> G2，LSU/ATOMIC/FENCE -> G3，其余 -> G0。

### Interface Timing

所有输出由当前拍输入组合产生；无时钟、复位和本地存储。`global_flush_late=1` 时 `accept`、`ib_dequeue_request`、`isq_select_request` 和 `serial_set_request` 均为 0。


