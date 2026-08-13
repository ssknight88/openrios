# ISQ_Group0 · ALU0/BRU/MRET + CSR + DIV 组 · 单 entry

组内三个 requester，`FU_Group` 是**组内 FU 索引**：

```text
FU_Group = 0   ALU0 / BRU / MRET   —— 三者共用一个 requester 接口，不能同拍竞争
FU_Group = 1   CSR                 —— 非流水
FU_Group = 2   DIV                 —— 非流水
```

四组中**唯一需要分支预测字段**的一组（BRU 要拿 `pc` / `pred_*` 判是否 mispredict）。

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
- **issue** = `issue_valid` ∧ `FU_ready[FU_Group]` ∧ `!global_flush_late`
  - `issue_valid` = `isq_valid` ∧ `operand_ready`
    - `operand_ready` = `(rs1_ready ∨ fast_ready_rs1) ∧ (rs2_ready ∨ fast_ready_rs2)`
      —— **本组不用 `rs3`**，不参与取与
    - `fast_ready_rsX` = `!rsX_ready` ∧ OR over b∈{0..3} (`bypass_valid[b]` ∧ `rsX_wait_tag == bypass_tag[b]`)
      - `!rsX_ready` 不可省：ready 后 `wait_tag` 保持不变，且 tag 0 是合法 tag
        - **四条 bypass lane 全监听**——bypass 是全局广播，不按组收窄
    - `FU_ready[FU_Group]` 是**三位**电平输入，按组内索引取用
- **bypass_capture** = `isq_valid` ∧ `!global_flush_late` ∧ `!issue`
  ∧ (`fast_ready_rs1` ∨ `fast_ready_rs2`)
  - 同拍 issue 时不捕获，只向 FU 前递
- **flush** = `global_flush_late`
  - 优先级最高：flush 拍不 dispatch、不 issue、不 capture，`isq_valid ← 0`

**`FU_ready` 契约**（本组含两个非流水 FU，必须显式定义）：

```text
FU_ready[k] = FU k 本拍能接收一条新指令
非流水 FU（CSR / DIV）在执行中保持 FU_ready = 0；
在 P3 组内仲裁输掉、须 hold 住 completion request 时同样保持 0
```

- `FU_Group = 0` 是 **ALU0 / BRU / MRET 共用的一个** requester 接口——三者在 P3 侧
  共用 requester index 0，不是三个能同拍竞争的 requester，故 `FU_ready[0]` 也只有一位
- 组内 P3 仲裁的静态优先级为 `ALU0/BRU > CSR > DIV`，无 anti-starvation；
  该保证依赖按序退休

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

- 末两条对同一个 `rsX` 互斥；两个源可同拍并行
- 最后一条**绕过 entry 直接前递**，该值不落进本 entry
- `bypass_capture` 命中时只置 `rsX_ready`，`rsX_wait_tag` 不改——否则下一拍会拿新 tag 重新匹配
- `payload_in` 给的是完整 payload，本模块**只捕获 ⑤ 列出的字段**，其余丢弃

## ⑤ data structure（schema + 字段三角色）

- **state**：`isq_valid`
- **header**
  - `rs1_ready` / `rs2_ready`：`dispatch` 写初值；`bypass_capture` 命中对应源时置 1
    - `rs1_wait_tag` / `rs2_wait_tag`：`dispatch` 写入，`bypass_capture` 不改
    - `FU_Group`：`dispatch` 写入。取值 `{0,1,2}`，用于选组内 FU 并原样送给 FU 自译
- **payload**
  - `rs1_data` / `rs2_data`：`dispatch` 写初值，`bypass_capture` 命中时更新
    - `imm_valid + imm_data`：`dispatch` 写入（ALU 立即数型、CSR 的 `uimm` 型）
    - `pc + pred_taken + pred_target_pc`：`dispatch` 写入，BRU 判 mispredict 用
    - `self_tag`：`dispatch` 写入，本模块不查
    - **子码 / Full Decode 控制信号**：`dispatch` 写入，本模块不查。
      **位宽与编码待定**——取决于 FU 侧哪个值对应哪个操作。
      C 扩展的 `is_compressed`（BRU 算链接值要区分 `pc+2` / `pc+4`）也归在此处

**本组不存的字段**（`payload_in` 上有，本组丢弃）：

```text
rs3_ready / rs3_wait_tag / rs3_data   本组无三源指令
is_store / store_size                 访存字段，只有 LSU 用
```

## ⑥ 接口

**in-event** `→ ISQ_Group0`

- dispatch（Transaction，单向选通；ready = `isq_free_for_dispatch`，已被上游吸收；**1 写口**）
  - move；⑤ 列出的全部字段 —— 从 `payload_in` 捕获进 entry
    - 触发；`wr_en`(1) —— 本拍要不要捕获 `payload_in`

- bypass_capture（announce，**4 lane**）
  - move；`bypass_data[b]`(64，b∈{0..3}) —— 命中源的 `rsX_data` 写进 entry
    - broadcast；`bypass_valid[b]`(1，b∈{0..3})、`bypass_tag[b]`(4，b∈{0..3}) —— 与 `rsX_wait_tag` 比对，不留存

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，`isq_valid ← 0`，无载荷

- 组合读(in)
  - broadcast；`FU_ready[FU_Group]`(1，FU_Group∈{0,1,2}) —— 进 `issue` 判据，不留存

**out-event** `ISQ_Group0 →`

- issue；`rs1_data`(64)、`rs2_data`(64)、`FU_Group`(2)、`imm_valid`(1)、`imm_data`(64)、
  `pc`(64)、`pred_taken`(1)、`pred_target_pc`(64)、`self_tag`(4)、子码

`issue` 的判据（含 `FU_ready` 与 `!global_flush_late`）在 ③；
它送往库外的 FU，交付语义与 ready 归集成层登记。

**Static Info：**

- `isq_free_for_dispatch`(1) —— `isq_valid` 与本拍 `issue` 的投影，**含同拍 `issue`**（见 ③）
