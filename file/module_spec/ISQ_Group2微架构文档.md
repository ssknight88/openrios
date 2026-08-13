# ISQ_Group2 · FPU 组 · 单 entry

组内只有 FPU 一个 FU，`FU_Group` 恒为 0。
**四组中唯一使用 `rs3` 的一组**——FMA 类指令需要三个源。

## ① per-entry state

`FREE / RESIDENT`

- 就是 `isq_valid` 一位：0 = FREE，1 = RESIDENT。只有一个 entry，无指针

## ② state transition & condition（event 名）

- FREE → RESIDENT：dispatch
- RESIDENT → RESIDENT：dispatch（同拍发射）
- RESIDENT → RESIDENT：bypass_capture
- RESIDENT → FREE：issue（本拍无 dispatch 时）
- RESIDENT → FREE：flush

## ③ condition 细化

- **dispatch** = `wr_en`（单向选通 fire）
  - 写使能已在上游吸收 `isq_free_for_dispatch`，本模块**不重组第二份 ready/valid 握手**
    - `payload_in` 是持续组合 D 输入，只在 `wr_en = 1` 时捕获
- **issue** = `issue_valid` ∧ `FU_ready` ∧ `!global_flush_late`
  - `issue_valid` = `isq_valid` ∧ `operand_ready`
    - `operand_ready` = `(rs1_ready ∨ fast_ready_rs1) ∧ (rs2_ready ∨ fast_ready_rs2)`
      `∧ (rs3_ready ∨ fast_ready_rs3)` —— **三源全参与**
    - `fast_ready_rsX` = `!rsX_ready` ∧ OR over b∈{0..3} (`bypass_valid[b]` ∧ `rsX_wait_tag == bypass_tag[b]`)
      - `!rsX_ready` 不可省：ready 后 `wait_tag` 保持不变，且 tag 0 是合法 tag
        - **四条 bypass lane 全监听**——bypass 是全局广播，不按组收窄
    - `FU_ready` 是 FPU 的电平输入。组内单成员，**无索引**
- **bypass_capture** = `isq_valid` ∧ `!global_flush_late` ∧ `!issue`
  ∧ (`fast_ready_rs1` ∨ `fast_ready_rs2` ∨ `fast_ready_rs3`)
  - 同拍 issue 时不捕获，只向 FPU 前递
- **flush** = `global_flush_late`
  - 优先级最高：flush 拍不 dispatch、不 issue、不 capture，`isq_valid ← 0`

**采样约定**：对外的空闲投影

```text
isq_free_for_dispatch = !isq_valid ∨ issue        // 含同拍 issue
```

**含同拍 `issue`**，与 [[Buffer微架构文档.md]] 的 `can_alloc_1/2`、[[IB微架构文档.md]] 的
`room_q`（两者皆**拍初值**）取相反约定，**三处逐个查，不可类推**。
代价：该投影的组合深度包含 `FU_ready` —— `FU_ready → issue → isq_free_for_dispatch`，
消费者的准入判定要等 `FU_ready` 稳定才成立。

## ④ data path

### 1. `entry` 的捕获与发射

```text
dispatch 输入端口 → entry           本组 schema 的全部字段（见 ⑤）
bypass 输入端口   → entry           bypass_data[b] —— 写命中源的 rsX_data
issue_valid       ← ③ 的 issue 判据 // 引用式登记，判据在 ③
entry            → issue 输出端口   除源数据外的全部 payload 字段
entry            → issue 输出端口   rsX_data —— 仅 rsX_ready 时
bypass 输入端口   → issue 输出端口   bypass_data[b] —— 仅 !rsX_ready ∧ fast_ready_rsX 时
```

- 末两条对同一个 `rsX` 互斥；三个源可同拍并行
- 最后一条**绕过 entry 直接前递**，该值不落进本 entry
- `bypass_capture` 命中时只置 `rsX_ready`，`rsX_wait_tag` 不改——否则下一拍会拿新 tag 重新匹配
- `payload_in` 给的是完整 payload，本模块**只捕获 ⑤ 列出的字段**，其余丢弃

### ⑤ data structure（schema + 字段三角色）

- **state**：`isq_valid`
- **header**
  - `rs1_ready` / `rs2_ready` / `rs3_ready`：`dispatch` 写初值；`bypass_capture` 命中对应源时置 1
    - `rs1_wait_tag` / `rs2_wait_tag` / `rs3_wait_tag`：`dispatch` 写入，`bypass_capture` 不改
- **payload**
  - `rs1_data` / `rs2_data` / `rs3_data`：`dispatch` 写初值，`bypass_capture` 命中时更新
    - `self_tag`：`dispatch` 写入，本模块不查
    - **子码 / Full Decode 控制信号**：`dispatch` 写入，本模块不查。
      **位宽与编码待定**——取决于 FU 侧哪个值对应哪个操作。
      F/D 的 `rm`（bits[14:12]，算术指令是舍入模式、FSGNJ/FMIN/FEQ 类是操作选择）
      也归在此处

**本组不存的字段**（`payload_in` 上有，本组丢弃）：

```text
FU_Group                          组内单成员，恒 0，无须存
pc / pred_taken / pred_target_pc  分支预测字段，只有 BRU 用
is_store / store_size             访存字段，只有 LSU 用
imm_valid / imm_data              FP 运算指令无立即数；FLD/FSD 属 LSU 组
```

### ⑥ 接口

**in-event** `→ ISQ_Group2`

- dispatch（Transaction，单向选通；ready = `isq_free_for_dispatch`，已被上游吸收；**1 写口**）
  - move；⑤ 列出的全部字段 —— 从 `payload_in` 捕获进 entry
    - 触发；`wr_en`(1) —— 本拍要不要捕获 `payload_in`

- bypass_capture（announce，**4 lane**）
  - move；`bypass_data[b]`(64，b∈{0..3}) —— 命中源的 `rsX_data` 写进 entry
    - broadcast；`bypass_valid[b]`(1，b∈{0..3})、`bypass_tag[b]`(4，b∈{0..3}) —— 与 `rsX_wait_tag` 比对，不留存

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，`isq_valid ← 0`，无载荷

- 组合读(in)
  - broadcast；`FU_ready`(1) —— 进 `issue` 判据，不留存

**out-event** `ISQ_Group2 →`

- issue；`rs1_data`(64)、`rs2_data`(64)、`rs3_data`(64)、`self_tag`(4)、子码

`issue` 的判据（含 `FU_ready` 与 `!global_flush_late`）在 ③；
它送往库外的 FPU，交付语义与 ready 归集成层登记。

**Static Info：**

- `isq_free_for_dispatch`(1) —— `isq_valid` 与本拍 `issue` 的投影，**含同拍 `issue`**（见 ③）
