# SerialInstructionTracker · {valid, tag}

### ① per-entry state

`IDLE / INFLIGHT`

- 就是 `serial_inflight_valid` 一位。**全后端只有这一份**，不是 per-tag 数组
- **没有 pending 缓冲**：CSR 写意图住在 system_instruction_handler 的 `csr_stage`
  单寄存器（[[system_instruction_handler微架构文档.md]] ③）

### ② state transition & condition（event 名）

- IDLE → INFLIGHT：serial_set
- INFLIGHT → IDLE：clear/commit（tag 比对自证）
- INFLIGHT → IDLE：flush

### ③ condition 细化

- **serial_set** = `accept[0] ∧ serial0`（[[dispatch_logic微架构文档.md]] 唯一产生）
  → `{valid:1, tag = self_tag[0]}`
    - **串行指令只能从 slot0 收** > 依据：[[dispatch_logic微架构文档.md]] ④ `slot0_guard_ok`
    - ready = `!serial_inflight_valid`，已被上游 guard 吸收
- **clear/commit** = `serial_inflight_valid` ∧ `commit_valid[k]` ∧ `commit_tag[k] == serial_inflight_tag`
  → `valid ← 0`

      ① tag 唯一归属——`serial_inflight_tag` 从置位起属于那条串行指令，直到它退休或被 flush，
      期间不会被任何其他在飞指令持有；
      ② 串行独占——它在飞期间全机只有它一条指令，commit lane 上**根本不可能出现别的 tag**
    - set 拍必无 commit（set 要求 `buffer_empty` 拍初值成立）⇒ set 与 clear **不可能同拍**；
      新 set 又被 `serial_inflight_valid` 的拍初值挡住 ⇒ 无置位 / 清除竞争

- **flush** = `global_flush_late` → `valid ← 0`
    - 承担一切**不提交**路径的解除：非法 CSR 异常、队头被中断抢占、
      原子指令或 FENCE 在飞期间的任意 flush
    - `ECALL` / `EBREAK` **不走此口**——它们 `is_serial = 0`，从不置位本模块
    - MRET 提交后 flush：clear 与 flush 同拍都写 `valid ← 0`，次态一致
### ④ data path

#### 1. `serial_inflight_tag`

```text
serial_set 输入端口 → serial_inflight_tag     self_tag[0]
```

clear 与 flush 只写 `valid ← 0`，载荷宽度为零，不构成运值边。

### ⑤ data structure（schema + 字段三角色）

- **state**：`serial_inflight_valid`
- **header**：`serial_inflight_tag`——`serial_set` 写入即定；`clear` 时与 `commit_tag[k]` 比对
- **payload**：**无**

### ⑥ 接口

**in-event** `→ SerialInstructionTracker`

- serial_set（Transaction ×1；ready = `!serial_inflight_valid`，已被上游吸收）
    - move；`self_tag[0]`(4) —— 存入 `serial_inflight_tag`
    - 触发；`serial_set`(1) —— 单线使能，tracker 置位

- commit（announce，**2 lane**）
    - broadcast；`commit_valid[k]`(1，k∈{0,1})、`commit_tag[k]`(4，k∈{0,1}) ——
      与 `serial_inflight_tag` 比对，不留存；**无独立触发线**——lane valid ∧ 比对命中即 clear

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，`valid ← 0`，无载荷

**out-event** `SerialInstructionTracker →`

无

**Static Info**

- `serial_inflight_valid`(1) —— state 本体，[[dispatch_logic微架构文档.md]] 的派发 guard
