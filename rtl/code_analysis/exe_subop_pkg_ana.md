# exe_subop_pkg.sv 深度解析 (操作码路由表)

`exe_subop_pkg.sv` 充当了后端执行引擎的**“操作码字典”**和**“路由判决器”**。

---

## 1. 核心枚举定义 (Enums)

### 1.1 `backend_exe_group_e`
定义了后端的四个物理执行集群（Issue Groups）：
*   `GROUP_ALU0_BRU_DIV_CSR`: Group 0，最庞大、功能最杂的标量/分支/控制单元。
*   `GROUP_ALU1_MUL`: Group 1，纯数学标量单元（双发 ALU，乘法器）。
*   `GROUP_FPU`: Group 2，浮点组。
*   `GROUP_LSU`: Group 3，访存组。

### 1.2 `backend_exe_subop_t`
定义了所有功能单元底层的具体操作码。例如：
*   **ALU**: `ALU_ADD`, `ALU_SUB`, `ALU_XOR`, `ALU_ADDI` 等。
*   **BRU (分支)**: `BRU_BEQ`, `BRU_JAL`, `BRU_BLT` 等。
*   **LSU (访存)**: `LSU_LOAD`, `LSU_STORE`。
*   **CSR**: 各种读写和清理操作。

---

## 2. 路由判决函数 (Routing Functions)

为了让 P2 (Issue) 阶段和 P3 (Writeback) 阶段的控制逻辑保持简洁，这个包提供了一系列 `is_gX_XXX` 风格的自动判断函数。

**示例与作用**：
*   `is_g0_alu0(subop)`: 返回该操作是否是 Group 0 的 ALU 指令。
*   `is_shared_alu(subop)`: 返回是否允许在 Group 0/Group 1 之间共享路由；`ALU_AUIPC` 被排除，因为它需要真实 PC。
*   `is_g1_alu1(subop)`: 返回该操作是否可由 Group 1 ALU1 执行；同样排除 `ALU_AUIPC`，保证 Group 1 不消费 PC。
*   `is_g0_bru(subop)`: 返回该操作是否是分支解析指令。
*   `is_lsu_store(subop)`: 专门用于判断访存组内是否是写内存操作。

## 3. 在架构中的应用
*   **P1 阶段**用它来决定一条指令应该压入 `isq[0]` 还是 `isq[1]`；其中 AUIPC/BRU 固定走 Group 0。
*   **P2 阶段**用它作为 MUX 的选择信号，把 `issue_en` 准确地路由给特定的执行黑盒（如 `alu_simple` 还是 `bru`）。
*   **Testbench** 用它来进行逆向解码，生成类似 `ADD` 或 `STORE` 的易读调试日志。
