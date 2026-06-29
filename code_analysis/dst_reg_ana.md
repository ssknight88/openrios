# dst_reg.sv 深度解析 (目标寄存器状态表)

`dst_reg.sv` 是实现**寄存器重命名 (Register Renaming)** 与乱序引擎**数据依赖构建 (Dependency Tracking)** 的心脏部位。通常在文献中，这个结构被称为 **Register Alias Table (RAT)** 或 **Busy Board**。

在我们架构中，它被实例化为两份：一份负责追踪 32 个整数寄存器 (`u_dst_int`)，一份负责追踪浮点寄存器 (`u_dst_fp`)。

---

## 1. 数据结构 (State Tracking Table)
它本质上是一个深度为 32 的表格，每一行对应一个架构寄存器（如 `x1` 到 `x31`）。
```systemverilog
typedef struct packed {
    logic             busy; // 1=期货，0=现货
    logic [TAG_W-1:0] tag;  // 谁在算这个期货的单号
} dst_entry_t;
dst_entry_t [31:0] dst_table;
```

---

## 2. 三大核心交互场景

### 2.1 给 P1 提供查询 (Read Ports)
当 P1 阶段要解析指令的源操作数时，它会拿着索引（如 `rs1=x5`）来查这个表。
*   **组合逻辑透出**：`dst_reg` 直接甩出 `rs_busy` 和 `rs_tag` 两个位向量。
*   如果 `x5` 对应的 `busy == 0`，说明数据已经在真实的 ARF（架构寄存器堆）里了，P1 直接去读现货。
*   如果 `busy == 1`，说明有一条老指令正在满头大汗地算 `x5`，此时 P1 只能拿着表里的 `tag`（比如 Tag 12）当作“取件码”，去 ISQ 里排队等候。

### 2.2 给 P1 登记分配 (Allocation Ports - 设为 Busy)
当 P1 阶段判定某条新指令可以进入乱序执行，且这条指令需要**修改寄存器**（`use_rd=1`）时，它会向 `dst_reg` 发出分配请求。
*   比如：指令 `ADD x6, x1, x2` 拿到身份 `Tag 15`。
*   在时钟边沿，`dst_reg` 会找到 `x6` 这一行，**残酷地覆盖它**：将 `busy` 设为 `1`，`tag` 更新为 `15`。
*   **逻辑美学**：从此以后，任何比它年轻的、想要读 `x6` 的指令，查表拿到的都将是最新的 `Tag 15`。这是解决 Write-After-Write (WAW) 和 Read-After-Write (RAW) 假相关障碍的终极魔法。

### 2.3 给 P4 提供清算 (Commit Ports - 解除 Busy)
如果在前面第 2 步中，指令 `Tag 15` 执行完了，成了老资格，在 P4 阶段功成身退 (Commit)。
*   P4 会把 `Tag 15` 和目标寄存器 `x6` 传过来。
*   `dst_reg` 找到 `x6` 这一行，但它**非常警惕**地做了一层检查：
    ```systemverilog
    if (dst_table[rd_idx].tag == commit_tag) begin
        dst_table[rd_idx].busy <= 1'b0;
    end
    ```
    它必须确认现在占着 `x6` 的到底还是不是 `Tag 15`！如果不是（说明在它后面，又有一个更年轻的指令宣称要改写 `x6`，且拿到了更年轻的 Tag），那么 `dst_reg` **绝对不会**解除 busy 状态。
*   如果匹配，解除 busy 状态，宣告 `x6` 彻底从“期货市场”回归到安稳的“现货市场 (ARF)”。