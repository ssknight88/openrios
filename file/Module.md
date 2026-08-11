## 1. IB

P0 前后端边界的有序指令缓冲，向 DSP 提供最多两个队头指令并承受后端回压；只有目标 ISQ 成功写入时才 dequeue，Late Flush 时清除可见投机内容。

## 2. INT_DST_REG

32 项整数逻辑寄存器重命名表，每项保存 {busy, latest_tag}；执行 P1 分配、P4 已完成 tag-qualified 的 clear 和 Global_Flush_Late 清除，x0 永远保持架构零语义。

## 3. FP_DST_REG

32 项浮点逻辑寄存器重命名表，每项保存 {busy, latest_tag}；执行 P1 分配、P4 已完成 tag-qualified 的 clear 和 Global_Flush_Late 清除，模块自身不检查 P3/P4 完成信息。

## 4. PC File

16 项、按 Buffer tag 索引的 PC-only 存储结构，仅保存 inst_pc；P1 是唯一写入方，P4 用于精确提交/恢复读取，flush 不清除其物理内容

## 5. p1_check_resolve

1. 解析 Inst：从 Buffer_tail 导出两个 slot 的 self_tag；生成 used_rd（只抑制整数 x0，不抑制 f0）；导出三类标志供 p1_dsp 准入——present（IB 有没有指令）、serial（串行指令只许在 Buffer 排空时从 slot0 单独发出，serial0 同时置位 CSR tracker，serial_inst 禁止串行指令参与双发）、fp0/fp1（FP 源读口只有一条指令的宽度，同拍两 slot 不得同为 FP，即双 FP 阻塞）。
2. 同拍 RAW 检查：slot1 的每个源与 slot0 的目的寄存器对比，命中则 slot1 该源改等 slot0 的 tag。
3. 源解析：对每个源按优先级判定它的来源，产出 ready、wait_tag 和数据选择码；另给出 missed_wakeup：producer 已执行完但错过了唤醒窗口时把该 slot 挡在派发外，等它提交后再走提交 lane。

## 6. p1_DSP

accept 的唯一产生点。slot0 要同时满足：Buffer 有格、目标 ISQ 空闲、没有串行指令在飞、自己若是串行则要求 Buffer 为空、没有 missed_wakeup、非 flush 拍。slot1 在此之上追加：Buffer 够两格、自己的目标 ISQ 也空、与 slot0 组不同、不与 slot0 同为 FP、本拍没有串行指令。结构上 slot1 被接受必然 slot0 也被接受。准入定了之后纯译码出三组使能：给 IB 的出队、给各 ISQ 的写使能、给 CSR tracker 的置位。

## 7. p1_isq_group_select

整数 ALU 在 G0/G1 动态二选一，其余类别固定映射。冲突判定：给出两 slot 的组号是否互异；相同组时保留 slot0，slot1 由准入端拦下。

## 8. ISQ

One Entry，valid(1 bit)。Issue 需要满足：操作数齐、对应 FU 本拍能收、非 flush 拍。操作数齐有两条路：已经 ready，或者四条 bypass lane 里当拍 tag 命中（fast_ready）——命中但没能同拍发射时，把 bypass 数据落进 entry 并置 ready，wait_tag 保持不改；命中且同拍发射时数据直接前递给 FU、不落 entry。

组间差异：G0: ALU0/BRU/CSR/DIV；G1: ALU1/MUL；G2: FPU，唯一用 rs3 的组，不存立即数；G3: LSU

## 9. Buffer — 16 entry

1. 分配：两写口，写入 rd_idx、rd_is_fp、use_rd；tag 就是 entry 地址，与 PC File、SCB 共用同一套地址算术，分配位置天然一致。不清零任何字段——result_data 只在执行完成后才会被读。
2. 写回：四条完成 lane 随机寻址，只写 result_data。
3. 提交与回滚：commit 只按 SCB 给的提交条数推 head；flush 拍先落下当拍提交（head 先按提交条数前移）、tail 回滚到 head 位置
4. 读口与投影：两个队头读口持续组合输出整条 entry，数据平面从这里点对点直连消费端——result_data 接 ARF 写数据口与 Commit CDB 的 data，rd_idx 接 ARF 写地址与重命名表清除口，use_rd/rd_is_fp 作为消费端本地合成 write enable 的 qualifier

## 10. CompletionSCB — 裁决中枢

职责：跟踪每个 tag 的生命周期（在飞、执行完、store 排空）；保存裁决所需的全部事件字段（mispredict、exception、is_store、is_serial，以及 CSR 写回内容）；每拍对队头做按序退休判定，决定提交几条、要不要 flush、store 何时排空；产出退休侧全部控制信号——commit valid/tag/条数、csr_clear（送 tracker）、排空请求、flush 三元组。

CSR 写通路：CSR 指令执行时算出的"写哪个、写什么"（csr_addr、csr_wdata）不许当场落笔——架构状态只在提交拍更新——先随写回存进这条指令自己的表项里候着；等它排到队头、判定链放行提交的那一拍，SCB 从表项读出这批内容，以 arch_csr_write 事件送外围 CSR 寄存器堆，此时才真正写入；若它在提交前被 flush，表项作废，这笔写随之蒸发。

另有两条对外供给：为 Flush_Model 提供按 flush_tag 索引的恢复上下文读口（mispredict 目标 PC、exception 的 cause/tval）；为 P1 导出 valid/exec_done 两条向量，供派发前判断唤醒窗口是否已错过。

## 11. Flush_Model — flush 翻译与广播

职责：唯一生成全局 flush 信号；把判定链交来的 flush 事件翻译成前端重定向（按 kind 选恢复 PC）与特权态更新（送外围 CSR 寄存器堆）。

## 12. CSR_Control — 串行化 tracker

职责：记录当前是否有一条串行指令在飞（全机唯一的一份 valid+tag），以此挡死后续派发、保证串行指令独占后端；提交或 flush 时解除。
