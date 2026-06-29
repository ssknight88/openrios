# alu_simple.sv 深度解析 (联合算术与分支执行单元)

在当前的架构迭代中，`alu_simple.sv` 已经不再是一个纯粹的数学计算器，而是演变成了一个**联合算术与分支执行单元 (Unified ALU & BRU)**。

在 `backend_top.sv` 的 Group 0 实例化中，普通算术指令 (`en_alu0`) 和分支指令 (`en_bru`) 都会路由给同一个 `alu_simple` 实例。这种设计可以复用底层硬件（如加法器）并简化 P3 阶段的写回仲裁。

---

## 1. 扩展后的接口设计

为了同时支持数学计算、`AUIPC` 和分支解析，它的接口包含了两类信息的融合：
*   **基础操作数**: `rs1`, `rs2`。
*   **PC 相关执行上下文**: `pc`, `imm_data`, `imm_valid`。其中 `AUIPC` 使用 `pc + imm_data`，BRU/JAL 使用 `pc + imm_data` 或 `pc + 4`。
*   **预测上下文**: `pred_taken`, `pred_target_pc` (仅 BRU 用于和实际计算结果进行对比)。
*   **输出信号**: 除了常规的 `wb_payload`，还暴露了 `wb_is_bru` (指示当前写回的结果是否来自于分支指令，用于 P3 写回多路复用)。

---

## 2. 并行双轨计算逻辑 (Dual-Track Computation)

在一个组合逻辑时钟周期内，模块会“背靠背”同时跑两条轨道，最后根据 `exe_subop` 的真实身份进行选择输出。

### 轨道 A：数学运算 (ALU Track)
执行一个庞大的 `case (exe_subop)` 树：
*   处理 `ADD`, `SUB`, `AND`, `OR`, `SLL` 等所有的基础和立即数算术操作。
*   `ALU_AUIPC` 是特殊 ALU 操作，结果为 `pc + imm_data`，因此只允许走 Group 0 的真实 PC 执行路径。
*   所有的结果暂存在局部变量 `alu_result` 中。

### 轨道 B：分支解析 (BRU Track)
无论当前是什么指令，这条轨道也会同时进行条件判断和地址计算：
*   计算**顺序执行地址**: `fallthrough_pc = pc + 64'd4`。
*   使用 `unique case` 对比 `rs1` 和 `rs2`，计算 `branch_taken` (是否跳转)。
*   计算**跳转目标地址**: `branch_target` (如 `pc + imm_data` 或 `(rs1 + imm_data) & ~1`)。
*   **关键的预测比对**:
    ```systemverilog
    assign mispredict_flag = is_bru_op &&
                             ((branch_taken != pred_taken) ||
                              (branch_taken && (pred_target_pc != branch_target)));
    ```
    只有当指令真的是分支 (`is_bru_op`)，并且它的实际行为与前端的预测行为（是否跳转、跳去哪里）不一致时，才会触发误预测标志。

---

## 3. 时序锁存与输出封装

在时钟的上升沿，模块决定究竟把哪条轨道的结果打包成 `result_payload_t` 发给 ROB：

```systemverilog
// 锁定异常标记和纠正地址
wb_payload.mispredict_flag <= mispredict_flag;
wb_payload.correct_pc      <= correct_pc; // 正确的下一条指令地址

if (is_bru_op) begin
    wb_is_bru <= 1'b1;
    // 如果是 JAL/JALR，需要向 RD 寄存器写回返回地址 (PC+4)
    wb_payload.result_data <= ((exe_subop == BRU_JAL) || (exe_subop == BRU_JALR)) ? fallthrough_pc : '0;
end else begin
    wb_payload.result_data <= alu_result; // 输出算术轨道的结果
end
```

## 4. 架构意义
将 BRU 合并进 ALU 是一种非常经典的微架构优化：
1. **减少执行端口碎片化**：不需要为了一个简单的比较指令单独开辟一个隔离的执行单元和 P3 写回端口。
2. **复用比较逻辑**：分支的 `rs1 == rs2` 与 ALU 的 `SUB` 操作底层极度相似。虽然在目前的行为级模型中我们写了单独的 `if` 和 `-`，但在综合成门级网表时，EDA 工具会自动将它们映射到同一个硬件加法器/比较器树上，极大节省面积。
