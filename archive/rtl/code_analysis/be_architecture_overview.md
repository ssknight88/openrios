# Orca Backend (OR_BE) 核心代码模块解析

本文档旨在对 `be_code` 目录下的所有核心 SystemVerilog 文件进行详尽的功能拆解。为了方便查阅，模块按照其在超标量乱序（OoO）流水线中的逻辑位置进行分类。

---

## 1. 基础定义与顶层结构 (Foundations & Top-Level)

### `typedefs.sv`
*   **功能**：全局类型与参数定义包 (`orca_types`)。
*   **核心内容**：
    *   定义了架构的全局常量，如 `XLEN = 64` (数据位宽), `ROB_DEPTH = 16`, `TAG_W = 4` (ROB Tag位宽)。
    *   定义了所有跨流水线传递的核心结构体（Structs），包括前端喂给后端的 `isb_payload_t`，写回总线用的 `result_payload_t`，以及提交到架构状态的 `commit_payload_t`。

### `exe_subop_pkg.sv`
*   **功能**：执行单元子操作编码包。
*   **核心内容**：定义了各个执行组（Group）具体的 ALU 操作码（如 `ALU_ADD`, `ALU_XOR`）和 BRU 分支操作码（如 `BRU_BEQ`, `BRU_JAL`），并提供了一系列 `is_g0_alu0()` 等辅助判断函数，用于在分发（Dispatch）和发射（Issue）阶段进行路由选择。

### `backend_top.sv`
*   **功能**：后端物理顶层连线模块。
*   **核心内容**：
    *   实例化所有的 P1~P4 流水线控制子模块、各种执行单元（FU）、寄存器堆（ARF）、重命名表（DST_REG）、重排序缓存（ROB）和发射队列（ISQ）。
    *   维护了一个后端私有的 ISB（Instruction Stream Buffer）FIFO，用于缓存从前端送来的指令。
    *   **核心数据流中枢**：所有的模块间握手信号、旁路网络（Bypass Bus）广播都在这里进行物理连线。

---

## 2. P1 阶段：分发、重命名与分配 (Dispatch, Rename & Allocation)

P1 阶段负责将指令从按序的 ISB 中提取出来，进行资源分配，并送入乱序执行引擎。

### `p1_admission_and_backpressure.sv`
*   **功能**：准入控制与背压生成。
*   **核心机制**：
    *   检查流水线资源是否足够（如 ROB 是否有空位、目标 Group 的 ISQ 是否有空位）。
    *   根据目标资源的忙碌状态，决定当拍能够双发（Dispatch 2）、单发（Dispatch 1）还是全部阻塞（Stall）。

### `p1_source_resolution.sv`
*   **功能**：操作数源解析（寄存器重命名）。
*   **核心机制**：
    *   读取指令的源寄存器索引（`rs1`, `rs2`, `rs3`）。
    *   查表 `DST_REG`：如果目标寄存器处于 busy 状态，说明数据尚未计算出，将捕获对应的 ROB Tag；如果不 busy，则直接从 `ARF` 读取确定的物理数据。
    *   **同拍覆盖 (Same-cycle Overlay)**：处理极端的双发数据依赖。如果 Slot 1 的指令恰好依赖当拍 Slot 0 指令产生的结果，它会智能地短路提取 Slot 0 即将分配的 Tag。

### `p1_deadlock_prevention.sv`
*   **功能**：旁路死锁预防。
*   **核心机制**：
    *   监控指令的源操作数 Tag 是否在 ROB 中被标记为已完成（`done`），但尚未提交到 ARF，且**不在当拍的旁路网络（Bypass Bus）上**。
    *   如果出现这种情况，说明数据恰好处于“写回与提交之间的真空期”，此时如果强制发射会导致数据永远无法被 ISQ 捕获。模块会触发 `stall`，强制指令在 P1 等待，直到该数据安全提交入 ARF。

### `p1_rob_allocation_and_isq_write.sv`
*   **功能**：最终打包装载入库。
*   **核心机制**：
    *   将从 `p1_source_resolution` 获取的 Tag/Data 与指令的控制信号组合成完整的 `isq_payload_t`。
    *   发出分配信号，将条目登记到 ROB，并将 payload 压入目标执行组的 ISQ 中，正式进入乱序域。

---

## 3. P2 阶段：发射与操作数准备 (Issue & Operand Fetch)

### `isq.sv` (Issue Queue)
*   **功能**：发射队列（每个 Group 独立实例化）。
*   **核心机制**：
    *   持续监听 P3 广播的 Bypass 总线。
    *   当匹配到自己缺失的操作数 Tag 时，捕获数据并将该操作数标记为 `ready`。
    *   当所有的操作数都 `ready`，且对应的执行单元不忙（`!fu_busy`）时，拉高 `issue_en`，将指令弹出发射给执行单元。

### `p2_fu_input_mux.sv`
*   **功能**：操作数多路复用器。
*   **核心机制**：在发射的最后一刻，将指令需要的最终操作数进行统一规范化。如果数据是当拍刚刚通过 Bypass 送达的，它会直接从旁路截取数据送入 FU，实现了**零周期的数据背靠背前递**。

---

## 4. 执行单元 (Functional Units)

### `alu_simple.sv` (Unified ALU & BRU)
*   **功能**：联合算术与分支执行单元。
*   **核心机制**：
    *   **数学运算**：纯组合逻辑运算（单拍完成）。接收规范化后的 `rs1` 和 `rs2`，根据 `exe_subop` 执行加减、位运算、移位和比较，直接输出写回包 `wb_payload`。
    *   **分支解析**：计算所有的条件分支（BEQ/BNE 等）和无条件跳转（JAL/JALR）的目标地址。判断分支是否实际发生（`branch_taken`），如果预测失败则置起 `mispredict_flag` 并携带正确的 `target_pc` 给 ROB。

### `fake_lsu.sv` (高级黑盒模型)
*   **功能**：带有 STB（Store Buffer）的访存单元行为模型。
*   **核心机制**：
    *   **2 拍快速执行**：无论是 Load 还是 Store，在计算出地址后，固定经过 2 拍的响应流水线向 ROB 报告完成（返回 `result_valid` 和 `l1d_accepted`）。
    *   **5 拍异步落盘**：Store 指令在执行时只会存入内部的 STB。直到 P4 提交发出 Wakeup 后，STB 才会锁定 L1D 物理端口 5 个周期去真正写内存。期间会通过 `lsu_busy` 物理反压后续的 Load。
    *   **智能前递与别名阻塞**：年轻的 Load 如果算出的地址与 STB 中未提交的 Store 相同，它会直接命中 STB 提前拿到数据（Smart Forward Hit）；如果数据还没准备好，则会触发地址冲突（Alias Block）挂起。

---

## 5. P3 阶段：写回与仲裁 (Writeback & Arbitration)

### `p3_intra_group_arbiter.sv`
*   **功能**：组内写回仲裁。
*   **核心机制**：由于 Group 0（包含 ALU0, BRU, DIV 等）多个执行单元共享一条写回总线，该模块通过固定优先级（如 ALU0 > DIV > BRU）决定哪一个单元的计算结果可以在当拍登上全局写回网络，并对未抢到总线的单元施加反压。

---

## 6. 状态维护与 P4 提交 (State & Commit)

### `rob.sv` & `rob_sidearray.sv`
*   **功能**：重排序缓存与侧边数组。
*   **核心机制**：
    *   `rob` 负责追踪所有在飞指令的生命周期，按序分配，乱序标记完成（`done`），按序提交（Commit）。
    *   `rob_sidearray` 是 ROB 的扩展扩展扩展（分开存储以优化时序），专门用来记录那些不需要写寄存器、但对程序流有重大影响的元数据（如 BRU 算出的错误目标 PC、引发 Exception 的原因等）。

### `dst_reg.sv`
*   **功能**：物理寄存器重命名状态表。
*   **核心机制**：记录每个寄存器当前是否正在被计算（busy）以及是由哪个指令（Tag）负责计算。在 P4 Commit 时如果 Tag 匹配则解除 busy。

### `arf.sv`
*   **功能**：架构寄存器堆 (Architectural Register File)。
*   **核心机制**：代表处理器真实可见的机器状态。只有在指令绝对安全（通过 P4 提交验证）时，数据才会正式写入此文件。

### `p4_commit_control.sv`
*   **功能**：按序提交与冲刷控制。
*   **核心机制**：
    *   **终极守门员**：检查 ROB 头部的指令是否 `done` 且无异常（对于 Store，还必须确认 `l1d_accepted` 为高）。符合条件则发出 `commit_ack` 允许退休，并向 LSU 发送唤醒信号（如果是 Store）。
    *   **绝对冲刷 (Late Flush)**：一旦发现 ROB 头部存在分支预测失败或异常，立刻通过内部局部变量 `flush_selected_this_cycle` 强行阻断所有当拍的提交动作，并拉高 `global_flush_late` 信号。该信号将广播给全流水线，无情地抹除所有的投机状态和 STB 中的毒药数据，将处理器拉回安全状态。