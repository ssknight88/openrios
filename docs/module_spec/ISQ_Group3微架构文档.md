# ISQ_Group3 · LSU 组 · 单 entry

组内只有 LSU 一个 FU，`FU_Group` 恒为 0。
**带访存字段**的一组（`is_store` / `store_size`）。

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

- **dispatch** = `wr_en`
  - `payload_in` 在 `wr_en = 1` 时捕获
- **issue** = `issue_valid` ∧ `FU_ready` ∧ `!global_flush_late`
  - `issue_valid` = `isq_valid` ∧ `operand_ready`
    - `operand_ready` = `(rs1_ready ∨ fast_ready_rs1) ∧ (rs2_ready ∨ fast_ready_rs2)`
      —— **本组不用 `rs3`**，不参与取与。`rs1` 是基址、`rs2` 是 store 数据
    - `fast_ready_rsX` = `!rsX_ready` ∧ OR over b∈{0..3} (`bypass_valid[b]` ∧ `rsX_wait_tag == bypass_tag[b]`)
      - **四条 bypass lane 全监听**——bypass 是全局广播
    - `FU_ready` 组内单成员，**无索引**
- **bypass_capture** = `isq_valid` ∧ `!global_flush_late` ∧ `!issue`
  ∧ (`fast_ready_rs1` ∨ `fast_ready_rs2`)
  - 同拍 issue 时不捕获，只向 LSU 前递
- **flush** = `global_flush_late`
  - 优先级最高：flush 拍不 dispatch、不 issue、不 capture，`isq_valid ← 0`

**`FU_ready` 契约**

```text
FU_ready = LSU 本拍能接收一条新访存指令
LSU 的一切内部反压（地址队列 / store buffer 余量 / 执行段占用）
都必须折进这一位，本模块不另设第二条反压通路
```

> **待补**：`g3_lsu_iface` 尚无文档。上面这条契约是按"反压全折进 `FU_ready`"写的模板，
> 若 LSU 另有独立的 issue 侧约束（如 store buffer 满须单独挡 store），
> 本节 `issue` 的判据要相应增项。

**采样约定**：对外的空闲投影

```text
isq_free_for_dispatch = !isq_valid ∨ issue        // 含同拍 issue
```

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

- 末两条对同一个 `rsX` 互斥；两个源可同拍并行
- 最后一条**绕过 entry 直接前递**，该值不落进本 entry
- `bypass_capture` 命中时只置 `rsX_ready`，`rsX_wait_tag` 不改——否则下一拍会拿新 tag 重新匹配
- `payload_in` 给的是完整 payload，本模块**只捕获 ⑤ 列出的字段**，其余丢弃

## ⑤ data structure（schema + 字段三角色）

- **state**：`isq_valid`
- **header**
  - `rs1_ready` / `rs2_ready`：`dispatch` 写初值；`bypass_capture` 命中对应源时置 1
    - `rs1_wait_tag` / `rs2_wait_tag`：`dispatch` 写入，`bypass_capture` 不改
- **payload**
  - `rs1_data` / `rs2_data`：`dispatch` 写初值，`bypass_capture` 命中时更新
    - `imm_valid + imm_data`：`dispatch` 写入（访存偏移）
    - `is_store + store_size`：`dispatch` 写入，本模块不查
      - `store_size` 为 3 bit 访存宽度编码，保留原始 decode 宽度信息
    - `self_tag`：`dispatch` 写入，本模块不查
    - **子码 / Full Decode 控制信号**：`dispatch` 写入，**位宽与编码待定**

**本组不存的字段**（`payload_in` 上有，本组丢弃）：

```text
rs3_ready / rs3_wait_tag / rs3_data   本组无三源指令
FU_Group                              组内单成员，恒 0，无须存
pc / pred_taken / pred_target_pc      分支预测字段，只有 BRU 用
```

## ⑥ 接口

**in-event** `→ ISQ_Group3`

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

**out-event** `ISQ_Group3 →`

- issue；`rs1_data`(64)、`rs2_data`(64)、`imm_valid`(1)、`imm_data`(64)、
  `is_store`(1)、`store_size`(3)、`self_tag`(4)、子码

`issue` 的判据（含 `FU_ready` 与 `!global_flush_late`）在 ③；
它送往库外的 LSU，交付语义与 ready 归集成层登记。

**Static Info：**

- `isq_free_for_dispatch`(1) —— `isq_valid` 与本拍 `issue` 的投影，**含同拍 `issue`**（见 ③）
