# Submodule Description （各submodule均可继续拆解）

## IB

P0 前后端边界的有序指令缓冲，深度为8

## INT_ARF

32项64位整数架构寄存器文件，支持 4 读 2 写

## FP_ARF

32项64位浮点架构寄存器文件，支持 3 读 1 写

## INT_tag_mapping

整数指令tag状态追踪表

## FP_tag_mapping

浮点指令tag状态追踪表

## scoreboard

### CompletionSCB — 裁决中枢

职责：跟踪每个 tag 的生命周期（在飞、执行完、store 排空）；保存裁决所需的全部事件字段（mispredict、exception、is_store、is_serial，以及 CSR 写回内容）；每拍对队头做按序退休判定，决定提交几条、要不要 flush、store 何时排空；产出退休侧全部控制信号——commit valid/tag/条数、csr_clear（送 tracker）、排空请求、flush 三元组。

另有两条对外供给：为 Flush_Model 提供按 flush_tag 索引的恢复上下文读口（mispredict 目标 PC、exception 的 cause/tval）；为 P1 导出 valid/exec_done 两条向量，供派发前判断唤醒窗口是否已错过。

### Flush_Model — flush 翻译与广播

职责：唯一生成全局 flush 信号；把判定链交来的 flush 事件翻译成前端重定向（按 kind 选恢复 PC）与特权态更新（送外围 CSR 寄存器堆）。

### Serial_Control_Tracker — 串行化 tracker

职责：记录当前是否有一条串行指令在飞（全机唯一的一份 valid+tag），以此挡死后续派发、保证串行指令独占后端；提交或 flush 时解除。

### System_Instruction_Handler

职责：专门处理 ecall、csrrw/csrrs、MRET、SRET、DRET 等系统指令

## PC_File

16 项、按 Buffer tag 索引的 PC-only 存储结构，仅保存 inst_pc

## Dependency_Check

1. 解析 Inst：从 Buffer_tail 导出两个 slot 的 self_tag；生成 used_rd（只抑制整数 x0，不抑制 f0）；导出三类标志供 p1_dsp 准入——present（IB 有没有指令）、serial（串行指令只许在 Buffer 排空时从 slot0 单独发出，serial0 同时置位 CSR tracker，serial_inst 禁止串行指令参与双发）、fp0/fp1（FP 源读口只有一条指令的宽度，同拍两 slot 不得同为 FP，即双 FP 阻塞）。
2. 同拍 RAW 检查：slot1 的每个源与 slot0 的目的寄存器对比，命中则 slot1 该源改为 slot0 的 tag。
3. 源解析：对每个源按优先级判定它的来源，产出 ready、wait_tag 和数据选择码；另给出 missed_wakeup：producer 已执行完但错过了唤醒窗口时把该 slot 挡在派发外，等它提交后再走提交 lane。

## dispatch logic

accept 的唯一产生点。slot0 要同时满足：Buffer 有格、目标 ISQ 空闲、没有串行指令在飞、自己若是串行则要求 Buffer 为空、没有 missed_wakeup、非 flush 拍。slot1 在此之上追加：Buffer 够两格、自己的目标 ISQ 也空、与 slot0 组不同、不与 slot0 同为 FP、本拍没有串行指令。结构上 slot1 被接受必然 slot0 也被接受。准入定了之后纯译码出三组使能：给 IB 的出队、给各 ISQ 的写使能、给 CSR tracker 的置位。

### isq_group_select

整数 ALU 在 G0/G1 动态二选一，其余类别固定映射。冲突判定：给出两 slot 的组号是否互异；相同组时保留 slot0，slot1 由准入端拦下。

## ISQ

One Entry，valid(1 bit)。Issue 需要满足：操作数齐、对应 FU 本拍能收、非 flush 拍。操作数齐有两条路：已经 ready，或者四条 bypass lane 里当拍 tag 命中（fast_ready）——命中但没能同拍发射时，把 bypass 数据落进 entry 并置 ready，wait_tag 保持不改；命中且同拍发射时数据直接前递给 FU、不落 entry。

组间差异：G0: ALU0/BRU/CSR/DIV；G1: ALU1/MUL；G2: FPU，唯一用 rs3 的组，不存立即数；G3: LSU

## Buffer — 16 entries

16 项、按 Buffer tag 索引的 result-only 存储结构。分配时两写口仅占用 entry，tag 就是 buffer entry 地址，与 PC File、SCB 共用同一套地址算术，分配位置一致；entry 内唯一 payload 是 result_data；它只在执行完成后由四条完成 lane 按 `tag_out` 寻址写入 `entry[tag_out].result_data`。提交与回滚时，commit 只按 SCB 给出的提交条数推进 head，flush 拍先落下当拍提交（head 先按提交条数前移）、tail 回滚到 head 位置；两个队头读口按 `head0_tag` / `head1_tag` 读出对应 entry 的 `result_data`，对外命名为 `commit_data[k]`，并接 INT/FP ARF 写数据口与 Commit CDB 的 `data`。

## FU

支持：RV64 I、M、A、F、D、C 指令

### ALU

ALU 支持整数算术、逻辑、移位与比较

### MUL/DIV

支持整数乘除及余数运算

### FPU

支持浮点算术（包括 D 扩展）与 FMA

### CSR

支持 CSR 操作

### LSU

负责 Load/Store 的地址计算和访存处理

### BRU

BRU 与 ALU0 合并为单周期执行单元，负责分支条件判定和实际跳转目标计算，并通过比较预测方向与目标形成误预测及正确恢复地址；误预测采用 Late Flush，在精确提交阶段统一处理。

### FU_group_arbiter

四个执行组分别为 G0（ALU0/BRU、DIV、CSR）、G1（ALU1、MUL）、G2（FPU）和 G3（LSU）。G0、G1 在组内对多个 FU 的完成结果进行仲裁，G2、G3 各自只有一个 FU，无需组内仲裁。

仲裁采用固定静态优先级：G0 为 ALU0/BRU > CSR > DIV；
G1 为 ALU1 > MUL；
同一组有多个 FU 同拍完成时，仅最高优先级结果获得本拍写回机会，未获选结果保持不变并在下一拍重新请求。
