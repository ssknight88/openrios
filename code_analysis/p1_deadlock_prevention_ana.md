# p1_deadlock_prevention.sv 深度解析

这个模块是一个极小的防御性组合逻辑块，但它对于乱序执行引擎（OoO Engine）的存活至关重要。它专门解决一种叫做**“旁路丢失引发的饥饿死锁 (Bypass Miss Starvation)”**的微架构边界问题。

---

## 1. 危险场景：什么是旁路死锁？

我们来看看在乱序流水线中数据是如何流转的：
1.  FU 算出结果。
2.  结果在 **P3 阶段**通过 Bypass 总线广播。ISQ 里的指令看到它等的数据来了，当即抓取（`ready = 1`）。
3.  结果写入 ROB，对应的 ROB 条目变成 `done = 1`。
4.  几拍或几十拍后，这条指令成了 ROB 头部，在 **P4 阶段** Commit 写入 ARF。

**致命漏洞出现在第 3 步到第 4 步之间的时间差（真空期）。**

假设有一条新指令在 P1 阶段重命名，它需要 Tag 5 的数据：
*   **查 DST_REG**：发现 Tag 5 是 busy 的。于是它拿着 Tag 5 准备进 ISQ 监听。
*   **但事实是**：Tag 5 早就过了 P3 的 Bypass 广播期，现在正安安静静地躺在 ROB 里等 P4 提交！
*   **后果**：这条新指令拿着 Tag 5 进了 ISQ，但 Tag 5 的数据永远不会再出现在 Bypass 总线上了。这条指令将被永远挂起，导致后续所有指令排队，CPU 彻底**死锁**。

---

## 2. 核心防御机制

`p1_deadlock_prevention.sv` 就是为了掐死这种“在真空期发车”的危险行为。

### 2.1 状态侦测
模块包含了核心侦测逻辑 `check_stall()`：
```systemverilog
function automatic logic check_stall(input logic ready, input logic [TAG_W-1:0] tag, ...);
    if (ready) return 1'b0; // 如果数据早就拿到手里了，或者直接从 ARF/Commit 拿到了，绝对安全。
    
    // 如果拿着 Tag 去排队，检查这个 Tag 的老指令是不是已经算完进入“真空期”了？
    if (rob_done_bits[tag]) begin
        // 真空期告警！检查一下它是不是恰好还在最后挣扎的边缘？
        // (1) 它是不是正好在当拍通过 Bypass 最后一次广播？
        // (2) 或者是某种提前吐出的 tag (agu_early_tag)？
        if (!tag_on_bypass && !tag_is_early) return 1'b1; // 彻底错过！强制 Stall！
    end
    return 1'b0;
endfunction
```

### 2.2 施加反压 (Stall)
如果 `check_stall` 对指令的任意一个操作数返回 `1`，模块就会输出 `slotX_stall = 1`。
这个 `stall` 信号会被送到 P1 分配模块，强制这条指令停留在前端缓冲区（ISB）不要发射。

指令只能在 ISB 里傻等，直到产生那个结果的老指令在 P4 阶段完成 Commit（数据进了 ARF，`DST_REG` 清除 busy）。在那个周期的下一拍，新指令重新查表，就会发现数据可以直接从 ARF 读了（`ready = 1`），死锁危机解除。

## 3. 总结
虽然这种“真空期”死锁发生的概率极低（只有在 ROB 积累了大量已完成但未提交的指令时才会出现），但这个模块是乱序处理器鲁棒性的试金石。它通过牺牲 1~2 拍的 Stall，换取了整个系统的绝对安全。