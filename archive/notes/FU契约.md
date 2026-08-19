# FU 契约

**本文档只回答一件事：后端要求每个 FU 做到什么。**

FU 内部怎么算、几级流水、用什么算法——**一律不在这里**。各 FU 是**库外**单元，
按既定范围划定不写微架构文档；本文档写的是**契约**，即后端已经据以设计、
FU 不满足就会出错的那些约定。

**为什么需要这份文档**：这些契约原先散在 `p3_arbiter_G0/G1` ④ 与四份 ISQ 的 ③ 里，
后按"仲裁器只做仲裁、不规定 FU 内部时序"的裁定移出（见 `walkthrough.md` §1.4），
一度只暂存于 `walkthrough.md` §2.1。本文档是它们的正式宿主。

**边界**：谁给 FU 送什么、FU 送出去的东西谁收——那是 `module_spec_v2/集成层.md` 的事。
异常号段与 `tval` 口径——那是 `异常与trap语义.md` 的事。本文档只写 FU 自身的义务。

---

## 1. 通用契约（四条 lane 全适用）

三条都是**后端已经据以设计**的前提，不是建议。

### 1.1 flush 契约

```text
global_flush_late 拍：作废全部在飞指令，以及被 P3 仲裁 hold 住的 completion request
此后：不得对旧 tag 再发 Result_valid
```

**为什么是硬约束**：`Buffer` 是全库唯一有意不挂 flush 门的模块，它的安全性**整个建立在这条上**
（理由链见 `walkthrough.md` §1.9）。直连 lane 2/3 的 FPU 与 LSU **同样受此约束**——
它们不经过仲裁器，没有第三方能代为拦截。

### 1.2 完成请求寄存一拍契约

```text
completion request 相对 issue 至少寄存一拍
```

即使是零延迟的 ALU 也不得在 issue 当拍就把 completion 打到仲裁器上。

### 1.3 恒零字段谁来驱动

`completion_common` 是**后端内部**的四 lane 共用 schema。谁补齐它取决于该 FU 在不在库内：

```text
库内 FU        送出完整的 completion_common，自己产生不了的字段自己置 0，仲裁器不代为补造
库外 FU        只交它自己能产生的字段；schema 由后端侧的适配器补齐
```

**为什么分两档**：G2/G3 直连 lane 2/3，没有仲裁器可以代置 0——所以补零这件事必须有人做。
但把它派给**库外**单元就等于要求对方背我们的内部数据结构:LSU 产生不了误预测、`mret`、
`fflags`，让它给这三样填零是把后端的 schema 塞进接口。这三样在 `g3_lsu_iface` 里接地。

**因此 `BE_LSU接口规范.md` 里不出现 `completion_common`**，只列 LSU 实际驱动的
`tag` / `data` / `excp` / `cause` / `tval` 五个字段。将来写 FPU 接口文档时照此办理。

schema 的权威定义在 `module_spec_v2/p3_arbiter_G0微架构文档.md` /
`module_spec_v2/p3_arbiter_G1微架构文档.md`。

---

## 2. `FU_ready` 语义

```text
FU_ready[k] = FU k 本拍能接收一条新指令

G0   ALU0/BRU 恒 ready；csr_fu、DIV 执行中或 P3 仲裁 hold 时为 0
G1   ALU1 恒 ready；MUL 的 output hold 被占满、或 P3 仲裁输掉须 hold 时为 0
G2   FPU 多周期运算期间、或须 hold completion 时为 0
G3   LSU 的一切内部反压（地址队列 / store buffer 余量 / 执行段占用）
     都折进这一位，不另设第二条反压通路
```

**这一位是唯一的反压通路。** 对端 ISQ 的 `issue` 判据只看它；FU 若另有独立的 issue 侧约束
（例如 store buffer 满时须单独挡 store），**那不是 FU 自己消化就是要改 ISQ 的 ③**，
不能两边都不管。

> G3 那条是按"反压全折进 `FU_ready`"写的模板；若 LSU 另有独立的 issue 侧约束
> （如 store buffer 满须单独挡 store），`ISQ_Group3` 的 `issue` 判据要相应增项。
> `g3_lsu_iface` 的完整双向边集见 §5.5。

---

## 3. 各 FU 的异常义务

号段与 `tval` 口径见 `异常与trap语义.md`，本节只写"谁负责报"。

```text
G0 · ALU0/BRU    cause 0   跳转/分支目标地址不对齐
                           判据随 ENABLE_C 变：C 未启用时 target[1:0] != 0，
                           启用后只查 target[0] != 0
G0 · ALU0/BRU    cause 1   FETCH_FAULT 子码   tval = pc（不是 inst_bits）
G0 · ALU0/BRU    cause 2   ILLEGAL 子码       tval = inst_bits
                           两者 cause 均由子码硬编码、不进 payload；除 cause 与 tval
                           来源外完全同形（无源操作数、不写 rd、不串行、requester 0）
G0 · SYS         cause 3   EBREAK        tval = 0
G0 · SYS         cause 11  ECALL         tval = 0（M-only；U 态落地后要分 8 / 11）
G0 · csr_fu      cause 2   未实现地址、写只读地址、特权不足
G1 · ALU1/MUL    无        **一条也产生不了**——完成事件字段恒 0
G2 · FPU         无        事件字段恒 0，见 §6
G3 · LSU         cause 4   load / LR 地址不对齐
G3 · LSU         cause 5   load / LR access fault
G3 · LSU         cause 6   store / SC / AMO 地址不对齐
G3 · LSU         cause 7   store / SC / AMO access fault
                           —— 唯一有两个上报时机的 cause，见下
```

**`exception_flag = 1` 时必须同拍给出有效的 `tag_out` / `exception_cause` / `exception_tval`**。

**cause 7 的两个上报时机**——store 的写分执行拍（进 store buffer）与退休拍（drain 落内存）
两段，访问权限故障两段都可能检出：

```text
执行拍检出    走 lane 3 的 exception_flag/cause/tval，与 cause 6 同形
             ⇒ 该 store 永远不会 drain
drain 拍检出  走 store_done_exception / _cause / _tval
             ⇒ 后端写进事件批，下一拍由同一个 exception 分支处置
```

**`store_done_exception = 1` 时内存不得被修改**——这是 LSU 的硬性义务，
后端「已 drain 的 store 不可被中断作废」那条保护正是靠它才成立。
load 没有 drain 阶段，**cause 5 只有执行拍一个时机**。
异常在**退休拍按序发生**，不在执行拍发生——FU 只负责如实上报，不产生任何架构效应。

**G1 产生不了异常，是"可能陷入的指令不得分流到 G1"这条约束的来源。** 现有两条据此成立：
`AUIPC` 固定 G0（它另有 PC 依赖）、`SYS` 类固定 G0。将来给 G1 加指令时必须重核。

---

## 4. csr_fu（G0，`FU_Group = 1`）

- **收 issue**：`rs1_data`、uimm（走 `imm` 通道）、`csr_addr`（在 `full_decode` 里）、子码、`self_tag`
- **执行拍组合读旧值**：经 `system_instruction_handler` 的软件读口。
  串行化保证执行时全机只有它一条在飞 ⇒ 旧值必为架构当前值，**读无竞争**
- **算两样**：
  ```text
  result_data       = 旧值（回 rd，上 completion lane 0）
  csr_wdata         CSRRW = rs1_data；CSRRS = old | rs1_data；CSRRC = old & ~rs1_data
  csr_write_enable  = 子码是写型 ∧ full_decode.csr_write_intent ∧ 地址合法
  ```

  **`csr_write_intent` 必须用 payload 里那一位，不能自己从 `rs1_data == 0` 推。**
  `CSRRS` / `CSRRC` 是否写取决于 **`rs1_idx == x0` 这个寄存器号**，不是值；
  而 `rs1_idx` 不在 payload 里。`csrrs t0, mstatus, t1` 在 `t1` 恰好为 0 时**仍是一次写**，
  `csrrs t0, mstatus, x0` 则**不是**——两者的 `rs1_data` 完全相同
- **非法判据**（三条，命中任一即 `exception_flag`、`cause = 2`、`tval = inst_bits`，**且 `we = 0`**）：
  ```text
  ① 未实现地址
  ② 只读 CSR（csr_addr[11:10] == 11）且 csr_write_intent = 1
     —— 只读 CSR 的**读是合法的**，只有写非法；这一条同样离不开 csr_write_intent
  ③ !fs_enabled 且地址是 fcsr / fflags / frm 三者之一（读写皆非法）
  ```
  **三条都必须真发异常，不能只清 `we`。** 只清写使能会让这条非法 CSR 指令被当成
  一次普通完成、正常退休——软件看不到任何错误，而它本该陷入。
  `fs_enabled` 由 `system_instruction_handler` 组合供给
- **非流水**：执行中或 P3 仲裁 hold 时 `FU_ready[1] = 0`
- **绝不当场写任何 CSR**——写意图上 lane 0，由 `system_instruction_handler` 的 `csr_stage`
  捕获、提交拍 `apply` 才落笔；被 flush 则蒸发

---

## 5. LSU（G3）

G3 承接三类指令，由 `exe_subop` 唯一区分：普通 load/store、22 条原子指令、`FENCE`/`FENCE.I`。
后两类到达时 `is_serial = 1`，即**发射时退休窗口是空的**。

### 5.1 普通 load / store

- store 走 SCB 的 drain 子流程：`store_drain_req` 到达才写内存，`store_done` 回送
- 不对齐**报异常，不做硬件拆分**（cause 4 / 6，`tval` = 出错地址）
- 结果的符号扩展与 NaN-boxing 由 LSU 在驱动 `result_data` 之前完成，后端不再整形

### 5.2 原子指令（LR / SC / 9 种 AMO，各 `.W`/`.D`）

**`is_store = 0`——它们不走 drain 通路。** `exec_done` 直接意味着不可回滚的原子事务已完成：

```text
LR         exec_done = 已取到 load 值
                       result_data = load 值；.W 在 RV64 必须符号扩展
SC 成功    exec_done = 条件写已完成，且不可回滚
                       result_data = 0
SC 失败    exec_done = 判定完成，未发生任何写入
                       result_data = 1
AMO        exec_done = 旧值读取、运算、写回三件事在同一 LSU 原子事务内完成
                       result_data = 更新前的旧值；.W 必须符号扩展
```

`Result_valid[3]` 此时才写 `Buffer`。**AMO 与成功的 SC 之后不存在第二次 `store_done`。**

**串行化给 LSU 省掉的东西**（理由链见 `walkthrough.md` §1.19）：
发射时窗口空 ⇒ 更早的 store 全部已 `store_done`、已落内存 ⇒
**LSU 不需要为原子指令做 store-buffer forwarding**。

### 5.3 reservation —— LSU 内部事务

reservation 怎么存、粒度多大、被谁作废，**全在 LSU 内部**。后端不持有 reservation 状态，
也**不向 LSU 提供任何与之相关的信号**（早期方案曾让后端把 `commit_valid`/`commit_tag`
送给 LSU 做"按 tag 提升"，已撤销——那是替 LSU 设计内部机制，越界了）。

接口上只有一条：**`global_flush_late` 之后，被作废的 LR 不得使后续 SC 成功。**
怎么做到（清 reservation 还是别的）是 LSU 的事。

这是保守做法，会造成偶发的 SC 失败（软件重试一轮），**RISC-V 明确允许**。
换来的是接口少一条边、LSU 少一套 pending/提升机制。理由链见 `walkthrough.md` §1.31。

### 5.4 对齐与副作用

LR / SC / AMO 的地址**必须自然对齐**（`.W` 4 字节、`.D` 8 字节），
不对齐一律陷入且**不得产生任何访存副作用**。`LR` 报 cause 4，`SC` / `AMO` 报 6。

`rd = x0` 只抑制 ARF 写口（由 `rd_write_enable` 承担），**不抑制访存副作用**——
`amoadd.d x0, x3, (a0)` 仍要改内存。

### 5.5 `g3_lsu_iface` —— 后端与 LSU 之间的完整边集

**这是全库唯一一处后端与库外单元的双向协议**，逐条列全：

```text
后端 → LSU
  issue（ISQ_Group3 的 out-event，见该文档 ⑥）
      rs1_data / rs2_data / imm_valid / imm_data / is_store / mem_funct3 /
      rd_is_fp / self_tag / exe_subop(24) / full_decode(17)
  store_drain_req_valid / store_drain_tag   触发 + 地址，1 拍脉冲，无 ready 回送
  global_flush_late                         单线脉冲，直达，不经仲裁器

LSU → 后端
  FU_ready                                  唯一反压通路
  wb_valid / wb_pld                         tag / data / excp / cause / tval —— **仅此五项**
                                            g3_lsu_iface 展开成 completion_common，
                                            并把 mispredict_flag / is_mret / fpu_fflags 接地
  store_done_valid / store_done_tag         触发 + 地址，1 拍脉冲
  store_done_exception / _cause / _tval     drain 拍检出的 access fault（cause 7）
```

**`mem_class` 必须由 `exe_subop` 分类，不能用 `!is_store` 推 load**：

```text
mem_class = decode(exe_subop) ∈ { LOAD, STORE, LR, SC, AMO, FENCE, FENCE_I }
```

`is_store` 只区分"走不走 drain 子流程"，**不是**"是不是访存写"。
AMO / SC / FENCE 三类都 `is_store = 0` 但都不是 load，靠 `!is_store` 推会全推错。

**`store_mask` 不进接口**：LSU 按 `(有效地址, mem_funct3)` 自己算
`mask = size_mask(mem_funct3) << effective_addr[2:0]`。前提是不对齐先报异常、
不做跨 beat 写——本实现正是如此（见 `异常与trap语义.md` §5）。

**`rd_idx` 不进接口**：回写按 `tag_out` 寻址，目的寄存器信息在 alloc 拍已进 SCB。
（v1 RTL 的 `lsu_req_t` 带了 `rd_idx`，v2 有意去掉。）

**flush 时 LSU 该丢什么——不需要后端送 discard mask**：

```text
已收到 store_drain_req 的条目   ⇒ 它已经提交，保留，继续 drain
未收到 drain_req 的条目          ⇒ 一定还是投机的，全丢
flush 同拍                       ⇒ 不得新接受 store_drain_req
```

**这条推论的依据是 v2 收窄了 drain 的时机**：drain 只在 head0 发起、按序、一次一条，
而判定链第 3 步（store drain）排在第 4 步（外部中断）**之前**——head0 卡在 drain 子流程时
`commit_count = 0`、不产生任何 flush 输出。所以**drain 窗口内不可能发生 flush**，
"未收到 drain_req ⇒ 必投机"是充分判据，LSU 每条 STB 条目一位 `draining` 就够，
后端不必送 16 位掩码。理由链见 `walkthrough.md` §1.25。

### 5.6 `FENCE` / `FENCE.I`

串行化保证更早的访存全部已退休，所以 LSU 侧的屏障**退化成"排空自己的 store buffer"**。
`FENCE.I` 另须确认前序**代码 store** 已对取指可见，再放它完成；
重取由退休侧的 `FENCE_I` 恢复事件承担，不归 LSU。

---

## 6. FPU（G2，直连 lane 2）

- **事件字段恒 0**：`exception_flag` / `mispredict_flag` / `is_mret` 一律置 0。
  **G2 不产生任何异常**——FP 指令的合法性检查全部在派遣侧完成，见 §7
- **唯一非零的非结果字段是 `fpu_fflags`(5)**：IEEE 标志，**不属于"事件字段"**，
  由 SCB 逐格存、随 commit 送 `commit_fflags[k]` 给 `system_instruction_handler` 累加
- **舍入模式直接用 payload 里的三位，不读实时 `frm`**：那三位已被装配侧覆写成
  派遣拍定格的 `effective_rm = (rm == DYN) ? frm : rm`，取值恒在 `000..100`。
  `DYN` 与保留值都不会到达本组——前者已解析、后者已在派遣侧判非法改道 G0。
  **`system_instruction_handler → FPU  frm` 这条边不存在**，接线时不要连
- **不用管 `FS`**：`mstatus.FS == Off` 时 FP 指令根本不会被派遣到 G2

---

## 7. FP 合法性检查在派遣侧，不在 FPU

**这是一条设计决定，不是遗漏。** `mstatus.FS == Off` 与 `rm` 取保留值都会让 FP 指令非法，
但检查**不在 FPU 做**，而在派遣侧合成 `illegal`、送 G0 的 ILLEGAL 完成路径。

```text
frm_illegal = (frm > 3'b100)          // frm 只允许 000..100

rm_illegal  = uses_rm(exe_subop)
              ∧ ( rm == 3'b101 ∨ rm == 3'b110 ∨ (rm == 3'b111 ∧ frm_illegal) )

fp_illegal  = is_fp_instruction ∧ ( !fs_enabled ∨ rm_illegal )
```

**`uses_rm` 必须由 `exe_subop` 静态分类**：算术类（FADD/FSUB/FMUL/FDIV/FSQRT、
四条 FMADD 族）与转换类（FCVT.*）用舍入模式；**FSGNJ*、FMIN/FMAX、FEQ/FLT/FLE、
FCLASS、FMV.* 都不用**——它们编码里那三位是别的意思，盲查会把合法指令误判成非法。

**为什么这么切**：
- G2 的事件字段可以继续恒 0，lane 2 的完成契约一字不改
- `ISQ_Group2` 不必增存 `inst_bits`——而 `tval` 要写指令编码，G0 本来就有
- 复用一条已经存在、已经核过的异常路径，不新增异常源

判据的宿主在 `module_spec_v2/checked_file/dispatch_logic微架构文档.md` ④，
它读 `system_instruction_handler` 的 `FS` 与 `frm` 两个组合读口。

> **另有一条不归派遣侧**：`FS == Off` 时访问 `fcsr` / `fflags` / `frm` 三个 CSR
> 同样应报非法指令——它们是 FP 状态。CSR 指令走 G0 的 csr_fu，由它在执行侧判，见 §4。
> **那一条必须真发 `exception_flag`**，只清 `csr_write_enable` 会让非法 CSR 指令
> 被当成一次普通完成、正常退休，软件看不到任何错误。

---

## 8. ALU0 / BRU / DIV / ALU1 / MUL

- **ALU0 / ALU1**：恒 ready，无异常。两者的可执行子码集合由
  `module_spec_v2/subop/exe_subop_pkg.sv` 的 `is_g0_alu0_subop` / `is_g1_alu1_subop` 界定；
  两集合不等——`AUIPC` 只在前者里（它要算 `pc + imm`，而 G1 不存 `pc`）
- **BRU**：算链接地址与分支 fall-through 目标时**按 `is_compressed` 取 `pc + 2` 或 `pc + 4`**；
  报 cause 0；`mispredict_flag` / `mispredict_target_pc` 的唯一产生方；
  `MRET` 透传（`is_mret`）与 `ILLEGAL` 兜底也在它这条 requester 上。
  mispredict 判据：
  ```text
  mispredict_flag = (actual_taken != pred_taken)
                  ∨ (actual_taken ∧ actual_target != pred_target_pc)
  ```
- **BRU 另欠 FE 一条预测器训练通路**（`predictor_update`）——这条**与恢复通路分开**：
  ```text
  BRU → SCB completion   mispredict_flag / mispredict_target_pc
                         只用于按序恢复，走退休侧
  BRU → FE               predictor_update{valid, branch_pc(64), actual_taken,
                                          actual_target(64), cf_class(2)}
                         用于方向 / 目标预测训练，**执行拍直发，不等提交**
  ```
  ```text
  cf_class = 00 COND_BRANCH / 01 DIRECT_JUMP / 10 INDIRECT_JUMP / 11 保留
             由 BRU 从 exe_subop 直接产生
  ```
  **`cf_class` 省不掉**：`actual_taken` 对无条件跳转恒为 1，喂进方向预测器是污染；
  而 FE 光靠 `branch_pc` 分不出类别，除非回去重新取指译码。
  **它明确不含 call/return**——那要看 `rd`/`rs1` 是不是 `x1`/`x5`，
  而 ISQ payload 没有 `rd_idx`/`rs1_idx`，BRU 算不出来。**因此本后端不支持 RAS**；
  将来要做，得在派遣侧预算 `ras_action` 或把两个寄存器号补进 payload。
  **`actual_target` ≠ `mispredict_target_pc`**：前者是 taken 时的控制流目标（训练用），
  后者是 `actual_taken ? actual_target : pc + 指令长度`（重定向用）。
  一条"预测 taken、实际 not-taken"的分支，两者取值不同
  **为什么必须单列**：`redirect_pc` 只在预测错时才有，而且它是**目标 PC 不是分支 PC**——
  预测器据此既学不到"哪条分支"，也收不到预测对时的确认。没有这条边，
  payload 里的 `pred_taken` / `pred_target_pc` 就是只读不写的死字段，预测器永远学不会。
  **训练允许投机**：被 flush 掉的分支训练进去只是污染准确率，不影响正确性；
  等提交反而会让训练严重滞后。v1 RTL 同样缺这条边，属两版共同的缺口
- **DIV**：非流水，执行中 `FU_ready[2] = 0`。**除零与溢出不是异常**——
  RISC-V 规定它们返回规定值，不陷入
- **MUL**：`FU_Group = 1`，output hold 被占满时不 ready
