# ISQ_Group1 · ALU1 + MUL 组 · 单 entry

组内两个 requester，`FU_Group` 是**组内 FU 索引**：

```text
FU_Group = 0   ALU1
FU_Group = 1   MUL
```

### ① per-entry state

`FREE / RESIDENT`

- 就是 `isq_valid` 一位：0 = FREE，1 = RESIDENT。只有一个 entry，无指针

### ② state transition & condition（event 名）

- FREE → RESIDENT：dispatch
- RESIDENT → RESIDENT：dispatch（同拍发射）
- RESIDENT → RESIDENT：bypass_capture
- RESIDENT → FREE：issue（本拍无 dispatch 时）
- RESIDENT → FREE：flush

### ③ condition 细化

- **dispatch** = `wr_en`
    - `payload_in` 在 `wr_en = 1` 时捕获
- **issue** = `issue_valid` ∧ `FU_ready[FU_Group]` ∧ `!global_flush_late`
    - `issue_valid` = `isq_valid` ∧ `operand_ready`
    - `operand_ready` = `(rs1_ready ∨ fast_ready_rs1) ∧ (rs2_ready ∨ fast_ready_rs2)`
      —— **本组不用 `rs3`**，不参与取与
    - `fast_ready_rsX` = `!rsX_ready` ∧ OR over b∈{0..3} (`bypass_valid[b]` ∧ `rsX_wait_tag == bypass_tag[b]`)
        - **四条 bypass lane 全监听**——bypass 是全局广播
    - `FU_ready[FU_Group]` 是按组内索引取用
- **bypass_capture** = `isq_valid` ∧ `!global_flush_late` ∧ `!issue`
  ∧ (`fast_ready_rs1` ∨ `fast_ready_rs2`)
    - 同拍 issue 时不捕获，只向 FU 前递
- **flush** = `global_flush_late`
    - 优先级最高：flush 拍不 dispatch、不 issue、不 capture，`isq_valid ← 0`

**`FU_ready` 契约**

```text
FU_ready[k] = FU k 本拍能接收一条新指令
ALU1 恒 ready
MUL 的 output hold 被占满时 FU_ready = 1 → 0；
    在 P3 组内仲裁输掉、须 hold 住 completion request 时同样拉低
```

- 组内 P3 仲裁的静态优先级为 `ALU1 > MUL`，无 anti-starvation；该保证依赖按序退休

**采样约定**：对外的空闲投影

```text
isq_free_for_dispatch = !isq_valid ∨ issue        // 含同拍 issue
```

### ④ data path

#### 1. `entry` 的捕获与发射

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

### ⑤ data structure（schema + 字段三角色）

- **state**：`isq_valid`
- **header**
    - `rs1_ready` / `rs2_ready`：`dispatch` 写初值；`bypass_capture` 命中对应源时置 1
    - `rs1_wait_tag` / `rs2_wait_tag`：`dispatch` 写入，`bypass_capture` 不改
    - `FU_Group`(2)：`dispatch` 写入。取值 `{0,1}`，用于选组内 FU 并原样送给 FU 自译
- **payload**
    - `rs1_data` / `rs2_data`：`dispatch` 写初值，`bypass_capture` 命中时更新
    - `imm_valid + imm_data`：`dispatch` 写入（ALU 立即数型）
    - `self_tag`：`dispatch` 写入，本模块不查
    - `exe_subop`(24)：`dispatch` 写入并原样发射；编码见集成层唯一 schema。

**本组不存的字段**（`payload_in` 上有，本组丢弃）：

```text
rs3_ready / rs3_wait_tag / rs3_data   本组无三源指令
pc / inst_bits / is_compressed / pred_taken / pred_target_pc
                                      指令身份与分支预测字段，只有 BRU 用
is_store / mem_funct3 / rd_is_fp      访存字段，只有 LSU 用
full_decode(17)                       Full Decode 控制字段，G1 无消费者
```

### ⑥ 接口

**in-event** `→ ISQ_Group1`

- dispatch（Transaction，单向选通；ready = `isq_free_for_dispatch`，已被上游吸收；**1 写口**）
    - move；⑤ 列出的全部字段 —— 从 `payload_in` 捕获进 entry
    - 触发；`wr_en`(1) —— 本拍要不要捕获 `payload_in`

- bypass_capture（announce，**4 lane**）
    - move；`bypass_data[b]`(64，b∈{0..3}) —— 命中源的 `rsX_data` 写进 entry
    - broadcast；`bypass_valid[b]`(1，b∈{0..3})、`bypass_tag[b]`(4，b∈{0..3}) —— 与 `rsX_wait_tag` 比对，不留存

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，`isq_valid ← 0`，无载荷

- 组合读(in)
    - broadcast；`FU_ready[FU_Group]`(1，FU_Group∈{0,1}) —— 进 `issue` 判据，不留存

**out-event** `ISQ_Group1 →`

- issue；`rs1_data`(64)、`rs2_data`(64)、`FU_Group`(2)、`imm_valid`(1)、`imm_data`(64)、
  `self_tag`(4)、`exe_subop`(24)

`issue` 的判据（含 `FU_ready` 与 `!global_flush_late`）在 ③；
它送往库外的 FU，交付语义与 ready 归集成层登记。

**Static Info**

- `isq_free_for_dispatch`(1) —— `isq_valid` 与本拍 `issue` 的投影，**含同拍 `issue`**（见 ③）
