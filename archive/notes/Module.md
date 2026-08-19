# 模块索引（v2.1）

层级对照 `Module_modified.md`（submodule 分解，各条均可继续拆解）；正文描述按 v2 修正口径。
库内 20 份 + 库外契约宿主 2 份，全部在 `module_spec_v2/`。
另有五份共同宿主收无主内容：`module_spec_v2/集成层.md`（库内接线）、
`异常与trap语义.md`（cause 号段与 `ENABLE_*` 前置条件）、`FU契约.md`（后端对各 FU 的要求）、
`前端契约.md`（后端对 FE / decode 的要求）、`walkthrough.md`（裁定留痕）。
后两份写的是**契约不是微架构**——库外单元的内部设计仍不写，这一条范围划定没变。

## 1. IB

P0 前后端边界的有序指令缓冲（8 slot FIFO），持续输出最多两个队头指令并承受后端回压；enqueue 的可用空位**含本拍 dequeue**（上一拍满、本拍出队 2 条则本拍即可收 2 条，不吃气泡）、`accepted_slot` 回送是**唯一**的回压契约（剩余容量是内部量、**不导出给 FE**，FE 盲发即可），只有目标 ISQ 成功写入时才 dequeue，Late Flush 时指针复位。`is_serial` 覆盖四类：CSR 指令、MRET、FENCE/FENCE.I、22 条原子指令（LR/SC/AMO）；ECALL/EBREAK/WFI **不串行**，与 ILLEGAL 同形走 G0·SYS。

单列字段的归属：`is_compressed`（BRU）、`csr_addr`(12)（`imm` 被 uimm 占用）、`rm`（FPU）。**`aq`/`rl` 不携带**——原子指令一律按全 acquire+release 执行，是架构决策不是遗漏，见 `module_spec_v2/checked_file/ISQ_Group3微架构文档.md` ⑤。

## 2. INT_ARF

32×64 整数架构寄存器堆，**4 读 2 写**。只有提交能写，flush 不动；entry 0 恒 0，与 tag_mapping 硬连、写抑制构成三重防线。

## 3. FP_ARF

32×64 浮点架构寄存器堆，**3 读 1 写**（单写口 = 提交侧双 FP 缩 1 的反向依据）；flush 不动。

## 4. INT_tag_mapping

32 项整数 tag 状态追踪表，每项 {busy, latest_tag}——busy 即**映射有效位**（1 = 存在指向在飞 producer 的有效映射）。P1 分配（同拍 WAW 留 slot1）、提交拍 tag-qualified 解除映射、Global_Flush_Late 全部解绑（前提：flush 恒清全窗）；entry 0 硬连 {0,0}，x0 走普通解析路径无特例。

## 5. FP_tag_mapping

32 项浮点 tag 状态追踪表，同上但 1 写口 / 1 清除口（双 FP 阻塞的依据）；f0 是普通格。

## 6. scoreboard（组，四个子模块）

### 6.1 CompletionSCB — 裁决中枢

退休侧单一权威：per-tag 生命周期 + 按序退休判定链（原 commit_unit）+ 环指针与指令元数据（原 Buffer 控制侧）。

- **指针**：head/tail 5-bit 环指针 = tag 分配算术 + `occupancy` + 回滚边界（flush 拍先落当拍提交、再 tail←head）；导出 `Buffer_head`/`Buffer_tail`/`occupancy`/`can_alloc_1/2`/`buffer_empty`（拍初值）
- **per-tag**：valid 是 `[head, tail)` 解码投影、不单独存；逐格存 `exec_done` 与 store drain 两位（alloc 拍清零，flush 不清）；alloc 批 `rd_idx`/`rd_is_fp`/`rd_write_enable`/`is_store`；事件批 mispredict / exception / `is_mret` 及恢复载荷
- **判定链**：每拍对队头按序退休判定——exception 先于 store drain、外部中断压过 FENCE.I/mispredict/MRET、head1 永不越过 head0、双 FP 提交缩 1 只减条数不丢写；产出 commit lanes（valid/tag/`rd_*`）、`commit_count`、排空请求、flush 三元组（`recovery_kind` 为 3 bit、五种）
- **不可作废的 head0**：已 drain 的 store，或已 `exec_done` 的原子指令——它们已产生不可回滚的存储器副作用，中断不得作废（否则 handler 返回后重执行、内存改两次）。`!head1_valid` 时中断推迟一拍，架构合法
- **对外供给**：为 flush_model 提供按 `flush_tag` 索引的恢复读口（mispredict 目标 PC、exception 的 cause/tval）；为 P1 导出 valid/exec_done 两条向量（判唤醒窗口）；为 Buffer 供队头读地址；commit lanes 兼供 SerialInstructionTracker 自清与 system_instruction_handler 的 csr_stage 生效

`csr_clear` 与 `arch_csr_write` 两个跨模块事件都不存在了——前者由 SerialInstructionTracker 自清取代（6.3），后者随 csr_stage 迁入 6.4 降级为其内部逻辑。

### 6.2 Flush_Model — flush 翻译与广播

唯一生成 `global_flush_late`；把判定链交来的 flush 三元组翻译成前端重定向（MISPREDICT→SCB 表项 target_pc、MRET→`mepc`、FENCE_I→`PC_File[flush_tag].inst_pc + 4`、EXCEPTION/INTERRUPT→`trap_vector`）与特权态更新 `trap_state_write`（送 system_instruction_handler）。汇 SCB 恢复字段、PC_File、system_instruction_handler 三家读口；`flush_tag` 只是读地址，回滚边界由 `commit_count` 承担。

`recovery_kind` 为 3 bit 五种；MISPREDICT 与 FENCE_I 不更新特权态。另唯一产生 `frontend_icache_invalidate = (recovery_kind == FENCE_I)` 送 FE——重定向的性质归本模块解释，FE 只按线动作。FENCE.I 的 `+4` 是常量：RVC 里没有 `C.FENCE.I`，因此不需要任何 per-tag 的指令长度。

### 6.3 SerialInstructionTracker — 串行化 tracker

全机唯一串行化互斥器 {`serial_inflight_valid`, `serial_inflight_tag`}。accept 拍按 `is_serial` 置位、挡死后续派发保证独占；解除是 **tag 比对自清**——commit lane 上自己的 tag 命中即 clear，不需要任何门控（v1 的 `csr_clear` 及"口径逐位相等否则停摆"契约整类消灭）——或 flush（承担一切不提交路径）。对指令种类不知情。

### 6.4 system_instruction_handler — 系统指令退休效应宿主

架构 CSR / 特权态 + csr_stage 的合体（原 csr_file + 原 SCB 的 csr_stage）。裁决在 6.1，生效在这里：

- **架构组**（flush 不动）：`mstatus`（含 `FS`/`SD`）/`mepc`/`mcause`/`mtval`/`mtvec`/`mscratch`/`mie`/`mip` + `current_priv`（非 CSR、恒 M，U 态待补）；**FP 组** `fflags`/`frm`/`fcsr`（提交拍按位或累加、FS 置脏）；最小合规组 `mhartid` 等硬连读 0、`mcycle`/`minstret` 真计数器
- **`misa` 不是常量**，由静态配置 `ENABLE_A`/`ENABLE_C`/`ENABLE_FD` 打包（全启用 `64'h8000_0000_0000_112D` = RV64IMAFDC；仅 IMFD 为 `…1128`）。同一组参数还驱动 decode/FE/LSU/FPU，必须同源；某扩展的库外契约未闭合时对应位必须为 0。`mepc` 的可写位随 `ENABLE_C` 变：IALIGN=16 时只有 `[0]` 恒 0
- **csr_stage**（唯一投机寄存器，flush 作废）：lane 0 写回拍 capture 写意图，提交拍 commit lane tag 比对命中即落笔——`arch_csr_write` 降级为模块内一行
- **写路径全在架构边界**：apply（提交拍）、`trap_entry`、`mret_update`（flush_model 驱动）；`mip` 外部位顶层电平直驱
- **读口按消费者分侧**：执行侧（csr_fu 读旧值 + `current_priv`）、退休侧（`interrupt_pending`）、flush 侧（`mepc`/`interrupt_cause`/`trap_vector`）
- **新增两个组合读口**：`fs_enabled`(= `mstatus.FS != Off`) 供 dispatch 判 `fp_illegal`、供 csr_fu 判 fcsr 三地址；`frm` 改供 dispatch 算 `effective_rm`，**不再直供 FPU**
- **系统指令待补挂点**：U 态、SFENCE.VMA（需 MMU）。ECALL/EBREAK/WFI/FENCE/FENCE.I 五条与 FS==Off / rm 保留值检查**都已不在此列**——前五条见各自宿主，后者改由派遣侧判、G2 永不发异常

## 7. PC_File

16 项、按 tag 索引的 PC-only 存储，仅保存 `inst_pc`；P1 是唯一写入方，flush 不清除物理内容。3 个组合读口：`flush_model` 按 `flush_tag` 读作 trap epc；另两口按 SCB 的 `head0_tag`/`head1_tag` 读出 `trace_pc[k]`，供提交点对拍。

## 8. dependency_check

纯组合，三项职责。1) 公共上下文：从 `Buffer_tail`（SCB 导出）导出两 slot 的 `self_tag`；生成 `rd_write_enable`（只抑制整数 x0，不抑制 f0）；导出 present / serial / fp 标志供准入。2) 同拍 RAW 检查：slot1 的每个源与 slot0 的目的寄存器对比，命中则改等 slot0 的 tag。3) 源解析：每源六选一（overlay / none / ARF / commit / bypass / wait）产出 ready、wait_tag 与数据选择码；另给出 missed_wakeup——producer 已执行完但错过唤醒窗口时把该 slot 挡在派发外。按选择码取数装配 `rsX_data` 的逻辑归集成层。

## 9. dispatch_logic

纯组合，accept 的唯一产生点，**选组逻辑已并入**（即参照里的 isq_group_select 小节）。先选组：整数 ALU 在 G0/G1 动态二选一（slot0 已占 G0 时 slot1 的 ALU 让位到 G1，但 AUIPC 那档固定 G0），其余类别固定映射——本次补全新增 ATOMIC→G3、FENCE→G3、SYS→G0 三类；相同组时保留 slot0；产出 `select_payload` 选择码供 p1_ISQ_input_mux。扩展的启用门控**不在本模块**，在 decode：`ENABLE_A`/`ENABLE_C` 为 0 时对应子码一律置 `illegal = 1` 走 ILLEGAL 完成路径（若改用 `subop_supported_now = 0`，该 slot 会永远停在队头——是挂死不是陷入）。再准入：slot0 要同时满足 SCB 有格、目标 ISQ 空闲、没有串行指令在飞（`serial_inflight_valid`）、自己若是串行则要求窗口空、没有 missed_wakeup、非 flush 拍；slot1 在此之上追加：够两格、自己的目标 ISQ 也空、与 slot0 组不同、不与 slot0 同为 FP、本拍没有串行指令。结构上 `accept[1] ⇒ accept[0]`。准入定了之后纯译码出三组使能：IB 出队、各 ISQ 写使能、SerialInstructionTracker 的 `serial_set`。`slot_ISQGroup` / `groups_distinct` / `slot0_fire_candidate` 均为内部中间量，无环纪律转为模块内不变量。

### 9.1 继续拆解

**FP_read_address_mux**——两 slot 共 6 个候选 FP 源地址收缩到 3 个 FP 读口，选通只用 `is_fp_instruction[0]`（用 accept 会成组合环），输出同时驱动 FP_ARF 与 FP_tag_mapping 读地址。**p1_ISQ_input_mux ×4**——per group 把两 slot 的完整 `ISQ_Payload` 按 `select_payload` 二选一送进对应 ISQ，不加工不裁剪。

## 10. ISQ（Group0–3，各一份文档）

每组单 entry 发射队列。Issue 需要：操作数齐、对应 FU 本拍能收、非 flush 拍。操作数齐两条路：已经 ready，或四条 bypass lane 当拍 tag 命中（fast_ready）——命中未发射则 capture 落 entry 置 ready（`wait_tag` 不改），命中且同拍发射则直接前递不落 entry。`isq_free_for_dispatch` 含同拍 issue。组间差异：G0 = ALU0/BRU/MRET + CSR + DIV + SYS（ECALL/EBREAK/WFI），唯一存分支预测字段（`csr_addr` 走 `full_decode[11:0]`，**不进子码段**）；G1 = ALU1 + MUL，**一条异常也产生不了**——这是"可能陷入的指令不得分流到 G1"这条约束的来源；G2 = FPU，唯一用 rs3、不存立即数；G3 = LSU + ATOMIC + FENCE，唯一存 `is_store`/`mem_funct3`。G3 三类**共用同一份 schema、无专用字段**，由 `exe_subop` 区分；`is_store` 专指走 drain 子流程的普通缓冲 store，原子指令会写内存但 `is_store = 0`。

**继续拆解：FU_input_mux ×9（按 rs 实例化：G0/G1/G3 各 2、G2 3）**——issue 侧每源二选一（entry 存的 `rsX_data` vs 当拍 `bypass_data`），输出接 FU 的一个操作数口。

## 11. Buffer

16 格 × 64 位、按 tag 索引的结果数据 RAM，纯数据平面。四条完成 lane 写 `result_data`（按 `tag_out` 寻址）；两个队头读口（地址 `head0/1_tag` 由 SCB 给出）持续输出 `commit_data`，点对点接 INT/FP ARF 写数据口与 Commit CDB。无指针、无状态——alloc、commit、flush 都不进本模块。

## 库外（集成层登记）

- **前端**：fetch / decode / 分支预测——`IB_Payload` 生产者，redirect 与 `predictor_update` 消费者。完整义务见 `前端契约.md`
- **FU**（规格目标 **RV64IMAFDC**，`misa` 由 `ENABLE_*` 打包、库外契约闭合后才置位；`FS==Off` 与 `rm` 保留值的检查已移到派遣侧、G2 永不发异常）：ALU0/BRU（含 MRET 透传、ILLEGAL 兜底、`FETCH_FAULT`（取指故障，cause 1、tval 取 pc）、SYS 的 ECALL/EBREAK/WFI，另欠 FE 一条 `predictor_update`——**只做 resolve 侧、不做 commit 侧**）、csr_fu（读 system_instruction_handler 旧值、算结果与写意图、不落笔；写使能必须与 payload 的 `csr_write_intent` 相与）、DIV、ALU1、MUL、FPU、LSU + store buffer。**各 FU 的完整契约见 `FU契约.md`**，其中 §5.5 是 `g3_lsu_iface` 的完整双向边集
  - **LSU 因 A 扩展新增的义务**：LR/SC/AMO 的原子事务（`exec_done` 严格等于不可回滚点已完成，**不走 store drain**）、reservation 的维护（**纯 LSU 内部事务**，后端不送任何相关信号；flush 时清未被 SC 消费的 reservation）、`FENCE`/`FENCE.I` 的屏障、报 cause 4/6。原子指令 `is_serial = 1`，发射时窗口已空 ⇒ **不需要为它们做 store-buffer forwarding**
- **FU_group_arbiter**：G0（ALU0/BRU > CSR > DIV）、G1（ALU1 > MUL）组内静态优先级仲裁，G2/G3 直连 lane 2/3；loser 冻结 FU 本地 hold 下拍重试。**不入库**；`completion_common` / `csr_sideband` 两层 schema 的权威定义在 `module_spec_v2/p3_arbiter_G0/G1` 两份契约宿主文档；FU flush 契约与完成请求寄存一拍契约归 **FU 微架构文档**（待建）。
  四条 completion lane 的公共层 `completion_common` 都驱动 `Result_valid`、`tag_out`、`result_data`、`exception_flag`、
  `exception_cause`、`exception_tval`、`mispredict_flag`、`mispredict_target_pc`、`is_mret`、`fpu_fflags`：G1 的事件字段恒为 0；
  **G2 的 exception / mispredict / is_mret 恒为 0，但驱动 `fpu_fflags`**（IEEE 标志、非事件字段、只 G2 非零）；
  G3 的 `mispredict_flag` / `is_mret` / `fpu_fflags` 恒为 0，且 LSU 必须在同步访存异常时驱动
  `exception_flag/cause/tval`；G0 可驱动全部事件字段、`fpu_fflags` 恒 0。lane 0 另带 `csr_sideband`（CSR 写意图）。G2/G3 直连时由 FPU/LSU 直接遵守此 schema。
- **P1 的 `rs_data` 装配**：按选择码从 ARF / Commit CDB / bypass 取数
- **顶层外部中断电平**：直驱 `mip`
