# p4_commit_control.sv 实现分析

`p4_commit_control.sv` 是 ROB head 的精确提交仲裁器。它按 `head0 -> head1` 顺序决定普通 commit、precise flush、CSR retire，以及 Store drain request。

## 普通提交

非 Store 指令满足以下条件后可以 commit：

- ROB entry valid。
- ROB entry done。
- 没有 mispredict/exception。
- CSR 指令还必须满足 CSR inflight/pending 前置条件。

`commit_valid` 只表示架构提交，会驱动 ARF 写回、DST_REG 清理、CSR retire，以及 ROB head 前移。

## Store drain 协议

Store 的 `done` 只表示 AGU 完成并已进入 LSU/STB；它不能直接 commit。

P4 对 Store 的处理分三类：

- `buffered && !store_drain_requested && !store_done`: 发出 `Store_Drain_Req_Valid/Tag`，不提交、不前移 ROB。
- `store_drain_requested && !store_done`: 阻塞 ROB head，等待 LSU 返回 `Store_Done`。
- `store_done && !exception`: Store 可以像普通指令一样 commit。

如果 Store drain 返回 exception，ROB 会把该 Store 标记为 exception，P4 随后按普通 precise exception 路径触发 `global_flush_late`。

## 双发约束

- `head1` 永远不能越过 blocked `head0`。
- 如果 `head0` 是非 Store 并正常 commit，`head1` Store 可以在同一拍被请求 drain，但不能在同一动作中 commit。
- 如果 `head0/head1` 都是 Store，同一拍只考虑更老的 `head0`，避免同时处理两个 Store-side effects。
- 两个 FP 写回仍受单 FP ARF 写端口限制。

## Flush 优先级

任何被选中的 internal flush 或 external interrupt 都会压制 Store drain request（将其强行清零）。
而对于提交（commit_ack）的压制规则如下：
* **异常 (Exception) 或 中断 (Interrupt) 引起的 Flush**：当拍不会有任何指令提交，`commit_ack` 被压制为 `0`。
* **分支预测错误 (Misprediction) 引起的 Flush**：在发出 `global_flush_late` 的当拍，该分支指令本身仍然会正常提交（`commit_ack` 为 `1` 或 `2`），以确保分支指令完成其寄存器写回（例如 JAL/JALR 写入返回地址），随后从下一拍开始清空后续的投机指令并跳转。
