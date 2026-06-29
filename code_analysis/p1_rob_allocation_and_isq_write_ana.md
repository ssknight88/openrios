# p1_rob_allocation_and_isq_write.sv 深度解析

这个模块是 P1 (分发阶段) 的**“组装车间”与“最终发车台”**。它将前面所有子模块（操作数解析、资源准入、死锁预防）产生的散装信息打包，正式写入 ROB 并塞进 ISQ，宣告指令脱离前端，进入乱序域。

---

## 1. 核心职责
1.  **组装 Payload**：把操作数的最终状态（Data 或 Wait Tag）和执行操作码拼装成结构体。
2.  **写 ROB**：将指令的元数据（是否是 Store、属于哪个槽位）通过 `rob_alloc_valid` 发送给 ROB 申请条目。
3.  **写 ISQ**：发出 `isq_wr_en`，把指令正式压入四个执行组中某个特定的 Issue Queue。
4.  **写 DST_REG (重命名)**：把指令要修改的目标寄存器（RD）在状态表里标成 Busy，并挂上刚刚申请到的 ROB Tag。

---

## 2. 核心组合逻辑流程

模块对 Slot 0 和 Slot 1 分别执行以下打包逻辑：

### 2.1 全局冲刷与阻塞判定 (Flush & Stall Gate)
*   **首要原则**：如果 P4 发来了 `global_flush_late`，当前周期的所有打包和写回动作**立刻取消**（`rob_alloc_valid = 0`，`isq_wr_en = 0`）。这是微架构避免将毒药数据送入后端的最后一道屏障。
*   **Stall 阻断**：如果 `p1_deadlock_prevention` 报告了 `stall`，或者 `p1_admission` 报告 `can_dispatch = 0`，则该 Slot 同样不执行任何操作。

### 2.2 打包 `isq_payload_t`
这是写入发射队列的关键数据包。模块会将散装的控制信号进行硬连接：
```systemverilog
isq_wr_payload[target_group].self_rob_tag = alloc_tag; // 在 ROB 里的身份证
isq_wr_payload[target_group].exe_subop    = isb.exe_subop;
isq_wr_payload[target_group].rd_idx       = isb.rd_idx;
// ... 以及立即数、寄存器类型的透传
```

PC 与预测上下文按目标组收敛：
```systemverilog
p.pc             = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pc : '0;
p.pred_taken     = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pred_taken : 1'b0;
p.pred_target_pc = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pred_target_pc : '0;
```
也就是说，真实 PC 只进入 Group 0 的 AUIPC/BRU 快路径；Group 1/2/3 的执行 payload 不再携带真实 PC。精确异常、trace 和 debug 所需 PC 由 ROB sidearray 按 tag 提供。

**操作数状态的最终确定**：
如果 `rs_ready` 为 1，说明在 P1 已经拿到了真实的硬数据，将其存入 `rs_data`，ISQ 之后不用再监听这个操作数。
如果 `rs_ready` 为 0，说明数据还在计算，将其存入 `rs_wait_tag`，ISQ 进去后就会盯着这根 Tag 的旁路广播。

### 2.3 目标分配 (Destination Allocation)
如果指令有效并且需要写寄存器（`use_rd == 1`），模块会产生 `dst_alloc_valid`。
这会通知对应的 `dst_reg` 模块：“请把 `rd_idx` 号寄存器标为 Busy，如果谁以后要读它，让他来找 `alloc_tag`！”

---

## 3. 架构意义
这个模块没有任何时序逻辑（DFF），它是一个纯粹的数据路由和格式化矩阵。
经过这个模块后，指令从“静态的汇编流”彻底变成了“动态的乱序数据流图节点”。只要 `isq_wr_en` 置为高，指令就在乱序引擎的汪洋大海中获得了自己的身份（ROB Tag）和驻留地（ISQ Entry）。
