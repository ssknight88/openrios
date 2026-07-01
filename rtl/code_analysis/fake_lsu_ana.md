# fake_lsu.sv 实现分析

`fake_lsu.sv` 是 testbench 侧的 LSU/L1D 行为模型，不是生产级 Cache/TLB/LSQ。它的目的，是给 backend 提供足够真实的协议压力：Load 写回、Store Buffer、Store-to-Load forwarding、Store drain latency、flush discard，以及后续 load/store exception 测试入口。

## 接口角色

- `req_pending/req_valid/req_payload`: backend Group 3 LSU 请求入口。
- `req_payload` 不携带指令 PC；LSU 地址只由 `base_addr + imm_data` 计算。异常返回 tag/cause，faulting PC 由 ROB sidearray 在 P4 通过 tag 恢复。
- `lsu_busy`: 只表示当前请求不能被 LSU 接收。现在 Store drain 进行中不会天然阻塞 Load；Store 只有在 STB 满时被反压。
- `lsu_wb`: Load 返回数据或异常；Store 返回“已经进入 STB”的执行完成信号。
- `lsu_store_buffered`: Store 进入 STB 后同拍随 `lsu_wb` 返回给 ROB。它不是 commit 许可。
- `store_drain_req_valid/tag`: P4 在 Store 成为 ROB head 后请求 fake LSU 开始 drain。
- `store_done_valid/tag/exception/cause`: drain 结束后返回给 ROB/P4。Store 只有收到 `Store_Done` 后才能 commit。

## Store 生命周期

1. Store 在 P2 issue 到 fake LSU。
2. fake LSU 计算地址并把 `{tag, addr, data}` 放入 STB。
3. P3 通过 `lsu_wb.result_valid` 标记 ROB entry `done=1`，并通过 `lsu_store_buffered=1` 标记已进入 STB。
4. P4 看到该 Store 位于 ROB head 且已 buffered 后，发出 `Store_Drain_Req`，但不提交 Store。
5. fake LSU 保持 STB entry 有效并设置 `draining/drain_cnt`。
6. drain 计数结束后，如果没有 Store exception，则写入 `mem` 并返回 `Store_Done`；如果有 exception，则不写 `mem`，返回 `Store_Done_Exception`。
7. ROB 记录 `store_done` 或 exception，P4 下一次观察到后执行 commit 或 precise flush。

## Load 行为

Load 在这个模型里是一个**固定两拍执行路径**：

- 第 1 拍：Issue 进入 LSU，进入内部 Stage1，也就是 AGU 地址计算阶段。
- 第 2 拍：进入 Stage2，输出 `lsu_wb.result_valid/result_data`，随后走普通 P3 bypass 回写路径。

所以对当前模型来说，L1D hit 的 Load 可以理解为：`Issue -> AGU -> WB`，总共 2 个 execution cycle。这里的 2 拍是当前 mock 的确定性 fast path，不是变量延迟内存模型。

Load 进入 fake LSU 后，如果地址合法：

- 优先查 STB，同地址命中时执行 Store-to-Load forwarding。
- STB 未命中时读取 `mem[mem_idx(addr)]`。
- Load 数据通过 `lsu_wb` 回写 ROB，并进入普通 P3 bypass 路径。

Load 地址异常时：

- 不发 `agu_early_tag`。
- 不读取 `mem`，也不做 STB forwarding。
- 通过 `lsu_wb.exception_flag=1`、`exception_cause=5` 写入 ROB/sidearray，由 P4 精确触发 flush。

## agu_early_tag

`agu_early_tag` 不是数据，只是一个给 P1 用的预测性 tag 控制信号。它在 Load 的 Issue / AGU 入口拍被拉高，作为单拍脉冲使用；下一拍会自动清掉。它的作用是让 P1 能提前放行依赖这个 Load 的指令进入 ISQ，从而避免“bypass 已过、commit 未到”之间的死锁窗口。

## Store Exception

当前 mock 把 Store 地址异常延迟到 drain 完成时报告：

- Store 仍可进入 STB，并在 ROB 中表现为 buffered/done。
- P4 请求 drain 后，fake LSU 经过 drain latency 返回 `Store_Done_Exception=1`、`cause=7`。
- ROB 将该 Store 标记为 exception；P4 在它位于 ROB head 时触发 precise exception flush。

## Flush

`flush_late` 清空 fake LSU 的执行流水级，并根据 `flush_discard_mask` 清掉 STB 中被指定的投机 Store。正在 drain 的已请求 Store 不会因为普通流水线清空而产生新的投机写入；Store exception 路径会在返回 `Store_Done_Exception` 时避免写入 `mem`。
