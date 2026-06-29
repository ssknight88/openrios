# p1_admission_and_backpressure.sv 深度解析

这个模块是指令进入乱序引擎的**“签证官” (Admission Controller)**。它决定了当前时钟周期内，ISB 缓冲区的指令是否有资格进入后端的 ROB 和 ISQ。

---

## 1. 核心职责
防止因资源不足导致的流水线拥堵或溢出。如果后端核心结构（如 ROB）满了，或者某个特定的执行组队列（ISQ）满了，它必须产生背压（Backpressure），通知 ISB 停止下发指令。

## 2. 输入信号 (Inputs)
*   **指令需求**：`slot0_isb`, `slot1_isb` (当前排在 ISB 最前面的两条指令)。
*   **资源状态**：
    *   `rob_full`, `rob_empty`：ROB 是否已满。
    *   `isq_valid`：一个位掩码数组，指示 G0~G3 四个 ISQ 当前的每个条目是否被占用。

## 3. 核心机制：分配预判 (Allocation Dry-run)

模块不会盲目地只看当前状态，它会在一个组合逻辑块中**模拟分配动作**。

### 3.1 组别解码
首先解析 Slot 0 和 Slot 1 的指令分别需要去往哪个 Group (例如，一条是 ALU0，一条是 LSU)。
普通共享 ALU 指令可以根据 Group 0/Group 1 空闲情况分流；但 `AUIPC` 与 BRU 必须固定分配到 Group 0，因为它们在执行期需要真实 PC 或分支预测上下文。这样 Group 1 的 ALU1/MUL 路径不再需要 PC 数据布线。

### 3.2 Slot 0 判定
*   **条件**：ROB 没满，且 Slot 0 目标 Group 的 ISQ 是空闲的。
*   **结果**：如果满足，`slot0_can_dispatch = 1`。
*   **状态推进 (Dry-run)**：为了不影响 Slot 1，模块会在逻辑上假定 Slot 0 已经占据了那个 ISQ 的位置，生成一套 `gX_free_after_slot0` 信号。

### 3.3 Slot 1 判定
*   **条件**：Slot 0 必须成功发射（保证按序提取）。并且，ROB 还有**第二个空位**（不能刚剩一个就被 Slot 0 占了），且 Slot 1 目标 Group 的 ISQ 在 `gX_free_after_slot0` 状态下仍有空闲。
*   **结果**：如果满足，`slot1_can_dispatch = 1`。

## 4. 输出生成 (Outputs)
*   **`isb_dequeue_cnt`**: 告诉外层的 ISB FIFO 当拍可以弹出几条指令 (0, 1, 或 2)。
*   **`slot0/1_can_dispatch`**: 告诉后级的重命名和写入模块，哪些指令是真正获得“签证”的。

**微架构意义**：这是一种典型的“悲观/保守分配策略”，确保一旦指令跨过这条线进入 ISQ，它就必定有充足的物理追踪资源（ROB Entry），绝不会因为找不到床位而凭空消失。
