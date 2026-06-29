# arf.sv 深度解析 (架构寄存器堆)

`arf.sv` (Architectural Register File) 是处理器中最保守、最真实、也最“迟钝”的存储阵列。在狂风骤雨的乱序引擎深处，它犹如一块坚如磐石的定海神针，代表着程序执行的**不可逆真实状态 (Committed Architectural State)**。

---

## 1. 结构与定义
它在内部维护了一个极其简单的一维数组：
```systemverilog
logic [XLEN-1:0] regs [31:0];
```
包含 32 个 64 位宽的物理寄存器槽位。这正是 RISC-V 规范中程序员肉眼可见的那 32 个通用寄存器（`x0` ~ `x31`）。

与复杂的 `DST_REG` 和 `ROB` 相比，它没有任何关于 Tag、Busy 位或 Exception 状态的概念。它只存放纯净的硬核数字。

---

## 2. 行为准则：严格后置写入 (Commit-Write Only)

在我们的超标量架构中，所有在 P3 阶段由功能单元（ALU, LSU）算出来的结果，都只能停留在 Bypass 总线上或被暂扣在 ROB 中，**绝对不允许**直接接触 ARF。

只有在 **P4 阶段 (Commit 级)** 发生时，即当 ROB 头部的指令被最终审查（无异常、无预测失败），且 P4 控制器下达不可撤回的退休命令 (`commit_payload[k].commit_valid = 1`) 后，ARF 才会在接下来的时钟上升沿接收这笔数据。

```systemverilog
if (commit_payload[k].commit_valid) begin
    if (commit_payload[k].rd_idx != '0 || IS_FP) begin
        regs[commit_payload[k].rd_idx] <= commit_payload[k].result_data;
    end
end
```
*(注意那根硬连线逻辑：如果是整数寄存器堆，对 `x0` 的写入被直接抛弃，硬件上保证 `x0` 永远为零的 RISC-V 原则)*。

## 3. 多端口读出 (Multi-ported Read)

由于我们的 P1 阶段在一个时钟周期内最多可以分发两条指令，每条指令最多需要 2~3 个操作数，因此 ARF 必须暴露巨大的读带宽。
*   对于整数，它暴露了 4 个读端口（`NUM_READ_PORTS=4`）。
*   读取动作是**全组合逻辑**的：
    ```systemverilog
    for (genvar i = 0; i < NUM_READ_PORTS; i++) begin
        assign rs_data[i] = regs[rs_idx[i]];
    end
    ```
当 P1 查询 `DST_REG` 发现该寄存器不在 `busy` 状态时，P1 就会在同一个时钟周期内，通过组合逻辑连线直接从这个大池子里抽取出干净的、毫无争议的真实数据，并塞给即将进入发射队列的年轻指令。

## 4. 在全局冲刷中的作用 (Flush Behavior)

在异常恢复（Late Flush）发生时，乱序执行的核心（如 ISQ、部分 ROB 状态、LSU 的投机 STB）会被瞬间清零。
**而 ARF 完全不动如山。**
因为它里面存放的，永远是那条出错指令**之前**的所有指令规规矩矩执行后的清白状态。只要前端重新从那条出错的 PC 取指，处理器就能利用 ARF 里的这批干净数据，从灾难发生的这一刻精准地原地复活。