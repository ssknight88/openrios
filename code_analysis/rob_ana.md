# rob.sv 实现分析

`rob.sv` 是 16-entry 环形 Reorder Buffer，负责保存乱序执行结果，并在 P4 按程序顺序释放架构状态。

## Entry 状态

每个 ROB entry 保存：

- `valid`: entry 是否被占用。
- `done`: 执行结果是否已返回。
- `is_store`: 是否为 Store。
- `store_buffered`: Store 是否已经进入 LSU/STB。
- `store_drain_requested`: P4 是否已经为该 Store 发起 drain request。
- `store_done`: LSU 是否已经返回 Store_Done。
- `rd_idx/rd_is_fp/result_data`: 普通寄存器提交信息。
- `mispredict_flag/exception_flag`: P4 precise flush 判断信息。
- `is_csr/csr_write_enable`: CSR retire 控制信息。

## P3 Writeback

普通 FU 和 Load 通过 `wb_payload` 写回：

- 设置 `done=1`。
- 捕获 destination/result/exception/mispredict/CSR metadata。

Store 进入 STB 后也会走 `wb_payload.result_valid`，同时通过 `wb_store_buffered` 标记 `store_buffered=1`。这不是 commit，只表示 Store 已经进入 LSU 侧 buffer。

## Store drain 更新

P4 输出 `Store_Drain_Req_Valid/Tag` 后，ROB 设置对应 entry 的 `store_drain_requested=1`。

fake LSU 返回 `Store_Done_Valid/Tag` 后，ROB 设置：

- `store_done=1`
- 如果 `store_done_exception=1`，同时设置 `exception_flag=1`

异常 cause 不存放在 ROB 主体，而由 `rob_sidearray` 保存。

## Commit

P4 根据 head/head+1 的组合读口决定 `commit_ack`。ROB 在时钟边沿按 `commit_ack` 清除对应 entry 并推进 `head`。

Flush 时，ROB 根据 `flush_head_adv` 计算新 head，并将 head/tail 收敛到同一点，丢弃所有年轻投机 entry。
## Flush priority over P3 writeback

If `reset_rob_pointers` is asserted in the same cycle as any P3 `wb_payload[*].result_valid`, ROB recovery wins. The `reset_rob_pointers` branch executes before the normal writeback branch, so same-cycle killed P3 results do not set `valid`, `done`, or retire metadata in ROB.

## Allocation capacity sideband

ROB now exports two capacity signals to P1 admission:

- `rob_can_alloc_1`: current ROB state has at least one free entry.
- `rob_can_alloc_2`: current ROB state has at least two free entries.

These signals are stricter than `rob_full == 0` for a 2-wide dispatch machine. Near full, one free entry permits `slot0` allocation only; accepting `slot1` in the same cycle would overwrite a live ROB entry. The capacity calculation uses `head`, `tail`, and `full_flag` to derive occupancy/free slots.

Simulation-only guards in `rob.sv` stop immediately if either allocated tag already points to a valid entry. They are intended to catch future admission/flush bugs before they become silent tag reuse or commit deadlock.
