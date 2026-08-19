# ISQ_Group3 · LSU 组 · 单 entry

组内只有 LSU 一个 FU，`FU_Group` 恒为 0。
**唯一带访存字段**的一组（`is_store` / `mem_funct3`），
也是唯一需要 `rd_is_fp` 的一组——FP load 与整数 load 的尺寸相同、只差结果整形。

本组承接三类指令，**schema 完全相同、无任何专用字段**，由 `exe_subop` 唯一区分：

```text
LSU      普通 load / store
ATOMIC   LR / SC / 9 种 AMO，各 .W/.D，共 22 条
FENCE    FENCE / FENCE.I
```

后两类到达本模块时 `is_serial = 1`（在 dispatch 侧生效，本模块不查），
所以它们进入本组时**退休窗口是空的**——本组同时至多一条在飞的事实不变。

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

> `g3_lsu_iface` 的完整双向边集见 `../../FU契约.md` §5.5。上面这条是按
> "反压全折进 `FU_ready`"写的；若 LSU 另有独立的 issue 侧约束（如 store buffer 满
> 须单独挡 store），本节 `issue` 的判据要相应增项。

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
- **payload**
    - `rs1_data` / `rs2_data`：`dispatch` 写初值，`bypass_capture` 命中时更新
    - `imm_valid + imm_data`：`dispatch` 写入（访存偏移）
    - `is_store`：`dispatch` 写入，本模块不查。**它专指"走 SCB drain 子流程的普通缓冲
      store"**，不是"这条指令会不会写内存"。原子指令会写内存但 `is_store = 0`——
      它们不走 `store_drain_req` / `store_done`，`exec_done` 直接意味着不可回滚的
      原子事务已完成，按普通完成项按序提交。`FENCE` / `FENCE.I` 同样 `is_store = 0`
    - `mem_funct3`(3)：`dispatch` 写入，本模块不查。**访存类型**——
      同时承载宽度、符号扩展与 FP 三件事，load 与 store 共用一个字段。
      load 侧有七种取值（字节 / 半字 / 字 / 双字，前三种再分有无符号扩展），
      **2 bit 装不下**，故为 3 bit；store 侧只用其中的宽度部分。
      结果的符号扩展与 NaN-boxing 由 LSU 在驱动 `result_data` 之前完成，
      后端不再需要额外的扩展字段
    - `rd_is_fp`：`dispatch` 写入，本模块不查。供 LSU 区分同宽度的整数与 FP load
      （字宽的 `LW` 与 FP load 取值相同、双字同理），二者只差结果整形
    - `self_tag`：`dispatch` 写入，本模块不查
    - `exe_subop`(24)：`dispatch` 写入并原样发射；编码见集成层唯一 schema。
    - `full_decode`(17)：`{csr_write_intent, illegal, rm[2:0], csr_addr[11:0]}`；
      本组一位也不消费，对非适用字段置零并忽略。

**本组不存的字段**（`payload_in` 上有，本组丢弃）：

```text
rs3_ready / rs3_wait_tag / rs3_data   本组无三源指令
FU_Group                              组内单成员，恒 0，无须存
pc / inst_bits / is_compressed / pred_taken / pred_target_pc
                                      指令身份与分支预测字段，只有 BRU 用
```

**三类指令对同一组字段的用法**

```text
LSU      rs1 = 基址   rs2 = store 数据   imm = 偏移      mem_funct3 = 宽度+符号+FP
ATOMIC   rs1 = 地址   rs2 = 操作数/写数据  imm 恒 0        mem_funct3 只用宽度(.W/.D)
                      LR 不用 rs2（use_rs2 = 0 ⇒ rs2_ready 由上游给 1）
FENCE    rs1/rs2 均不用；imm、mem_funct3 均无意义，置零忽略
```

**`aq` / `rl` 的架构决策**：本实现**一律按 `aq = rl = 1` 执行**（全 acquire + release），
编码里的这两位**不译码、不进 payload**。这是比 ISA 要求更强的内存序，合法；
代价是放弃了 relaxed 原子的性能。之所以能这样，是因为原子指令已 `is_serial = 1`、
在退休点串行化，天然全序，逐指令放松也拿不到好处。
`full_decode` 因此不为 aq/rl 加位。**这是决策不是遗漏**——不得在别处描述成"已消费 aq/rl"。

**地址对齐**：LR / SC / AMO 的地址**必须自然对齐**（`.W` 4 字节、`.D` 8 字节），
否则报异常且**不得产生任何访存副作用**。cause 分两种：
`LR` 是读操作报 **4**（load address misaligned），`SC` / `AMO` 报 **6**（store/AMO
address misaligned），`tval` = 出错地址。号段全表见 `../../异常与trap语义.md`。

**`rd = x0`**：只抑制 ARF 写口（由 `rd_write_enable` 承担），**不抑制访存副作用**。
`amoadd.d x0, x3, (a0)` 仍要改内存。本组不参与这件事，记在此处只为防止误读。

> LSU 侧的行为契约——`exec_done` 的严格时点、reservation 的建立与作废、
> FENCE 的排空范围、以及 `g3_lsu_iface` 的完整双向边集——**不在本模块**，
> 见 `../../FU契约.md` §5。

### ⑥ 接口

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
  `is_store`(1)、`mem_funct3`(3)、`rd_is_fp`(1)、`self_tag`(4)、
  `exe_subop`(24)、`full_decode`(17)

`issue` 的判据（含 `FU_ready` 与 `!global_flush_late`）在 ③；
它送往库外的 LSU，交付语义与 ready 归集成层登记。

**Static Info**

- `isq_free_for_dispatch`(1) —— `isq_valid` 与本拍 `issue` 的投影，**含同拍 `issue`**（见 ③）
