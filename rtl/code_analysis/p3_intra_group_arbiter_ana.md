# p3_intra_group_arbiter.sv 深度解析

当多条指令在同一个时钟周期内在同一个执行组（Group）中完成计算时，为了争夺通往 ROB 和 Bypass 网络的唯一的写回端口，就需要 `p3_intra_group_arbiter.sv` 出面进行**总线仲裁 (Arbitration)**。

---

## 1. 为什么需要仲裁？(资源争夺模型)

在我们的后端物理拓扑中，四个 Group 的写回端口资源是这样分配的：
*   **Group 0**: 包含 ALU0/BRU (联合单元), DIV, CSR 等物理黑盒，但它们向外**只共享一个**结果输出端口 (`group_wb_payload[0]`)。
*   **Group 1**: 包含 ALU1, MUL 两个黑盒，共享 `group_wb_payload[1]`。
*   **Group 2 & 3**: FPU 和 LSU 独自霸占一个端口，不需要竞争（Direct connection）。

假设在 Cycle 10，长延迟的除法器 (DIV) 算完了，而单拍延迟的加法器 (ALU0) 也恰好算完了一条新指令。此时它们都会举手（拉高 `result_valid`），这就产生了端口碰撞。

---

## 2. 核心机制：固定优先级多路选择 (Fixed Priority MUX)

`p3_intra_group_arbiter` 采用全组合逻辑解决冲突。它使用了级联的 `if-else` 结构，这在硅片上综合出来的就是一个硬连接的优先级编码器。

### 2.1 Group 0 仲裁链
```systemverilog
always_comb begin
    alu0_ack = 1'b0; div_ack  = 1'b0; bru_ack  = 1'b0; csr_ack  = 1'b0;
    group_wb_payload[0] = '0;

    // 注意：这里的 alu0_payload 在 backend_top 中已经与 BRU 结果分离或共用，
    // 仲裁器层面优先保障高频基础运算/分支单元写回。
    if (alu0_payload.result_valid) begin
        alu0_ack = 1'b1;
        group_wb_payload[0] = alu0_payload;
    end else if (bru_payload.result_valid) begin
        bru_ack = 1'b1;
        group_wb_payload[0] = bru_payload;
    end else if (csr_payload.result_valid) begin
        // ...
    end else if (div_payload.result_valid) begin
        div_ack = 1'b1;
        group_wb_payload[0] = div_payload;
    end
end
```
*   **优先级排序：ALU0 > BRU > CSR > DIV**。
*   如果 ALU0 和 DIV 同拍有效，ALU0 会抢走总线（`alu0_ack=1`），其结果被送到 `group_wb_payload[0]`。
*   而未抢到的单元（如 DIV，此时 `div_ack=0`），由于自身控制逻辑的闭环，必须被迫将结果缓存在自己的寄存器中，在下一拍继续举手申请，直到轮到它为止。

### 2.2 反压效应的阻断
这个简单的优先选择器隐藏着巨大的微架构影响。由于我们的各个 FU（特别是 ALU/BRU）不支持结果内部阻塞缓冲，如果它算完却没抢到 `ack`，它就没法清空自己去接新的指令。这会反向拉高 `alu_busy`，进而将反压传递给 ISQ，阻挡新的指令发射。
因此，在这个架构中，让使用频率最高的基础运算器和分支解析器拥有最高优先级，是保证 IPC 吞吐量最不坏的选择。

Current RTL note: `ALU0`, `BRU`, and `CSR` are single-cycle no-hold producers, so the arbiter must prevent them from losing to hold-capable `DIV`. `DIV` is the intended retrying loser in Group 0 contention.
