# p2_fu_input_mux.sv 深度解析 (操作数多路复用)

在 P2 阶段指令即将跃入功能单元（FU）执行的最后半个时钟周期，`p2_fu_input_mux.sv` 充当了**“数据流最后一公里”**的高速分拣枢纽。

---

## 1. 为什么需要这个模块？

当 ISQ 决定发射一条指令（`issue_en = 1`）时，这条指令所需的操作数（比如 rs1）可能处于三种截然不同的状态：
1. **老态龙钟（Stored）**：数据早就在前几个周期算好了，安安稳稳地存在 ISQ 内部的 `rs1_data` 寄存器里。
2. **千钧一发（Bypass-Caught）**：数据根本没存在 ISQ 寄存器里，而是恰好在**这一拍的同一个瞬间**，刚刚被 P3 的另一个计算单元算出来，并通过 `bypass_bus` 广播到了半空中！
3. **早产儿（Early-Awakened）**：对于依赖 Load 指令的操作数，因为 Load 只吐出了一个没有携带数据的 `agu_early_tag`，导致 ISQ 被骗着提前一拍发射了。

功能单元（如 ALU）是非常单纯的，它们只想要一个稳定、确定的 64 位硬数据输入通道。`p2_fu_input_mux` 的工作就是处理这些混乱的数据来源，将其**规范化 (Normalize)** 成纯粹的 64 位信号。

---

## 2. 核心组合逻辑：MUX 优先权 (Select Operand)

对于每一个源操作数（rs1, rs2, rs3），模块调用以下函数进行物理多路选择：

```systemverilog
function automatic logic [XLEN-1:0] select_operand(
    input logic ready, 
    input logic [XLEN-1:0] data, 
    input logic [TAG_W-1:0] wait_tag, 
    input bypass_t [3:0] bypass_bus
);
    // 优先级 1：静态驻留数据 (Registered Data)
    // 如果 ready 为 1，说明数据早已就绪（在 P1 从 ARF 读取并暂存在 ISQ 中），直接使用暂存的数据。
    // 这也可以防止 ready 为 1 且 wait_tag = 0 时，误匹配空中飞着的无关 Tag 0 前递结果。
    if (ready) begin
        return data; 
    end

    // 优先级 2：背靠背旁路转发 (Bypass Forwarding)
    // 如果 ready 为 0，则说明在等待数据，我们需要检查当拍 Bypass 总线上是否有匹配的 Tag，如果有则直接截胡！
    for (int i = 0; i < 4; i++) begin
        if (bypass_bus[i].valid && bypass_bus[i].tag == wait_tag) begin
            return bypass_bus[i].data;
        end
    end

    // 优先级 3：兜底 (Fallback)
    return '0; 
endfunction
```

## 3. 架构级意义：背靠背执行 (Zero-cycle Forwarding)

这个仅包含组合逻辑的简短文件，是实现 **1 IPC (每周期执行 1 条指令) 满血性能**的关键。

如果去掉了 `bypass_bus` 这条路径，一条指令算出结果存入 ISQ 寄存器需要经过一个时钟上升沿（DFF 锁存），下一条依赖它的指令才能发射，这会硬生生拉出一个 **1 拍的流水线气泡 (Bubble)**。
有了 `p2_fu_input_mux` 的组合逻辑穿透，如果上一拍指令出结果，这一拍依赖它的指令可以直接抓着总线上的信号和 ALU 握手。这就是超标量处理器中大名鼎鼎的 **"0-cycle Forwarding" / "Bypass Network"**。