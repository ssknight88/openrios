# isq.sv 深度解析 (发射队列)

`isq.sv` (Issue Queue) 是 P2 阶段的核心缓冲阵列，也是实现**数据驱动乱序执行 (Data-driven Out-of-Order Execution)** 的引擎盖。在我们的架构中，4 个执行组 (G0~G3) 各有一个独立例化的 `isq` 模块。

---

## 1. 设计极简主义：单条目 ISQ
在这个教学/最小化（Minimal Bring-Up）架构中，为了控制复杂度和提升 Fmax，每个 `isq` 被设计为**深度仅为 1** 的锁存器。
这意味着如果一条指令卡在某个 Group 的 ISQ 里（比如在等老数据，或者 LSU 物理资源忙），后续分配给同一个 Group 的指令就会直接在 P1 阶段被挡住。这简化了选择逻辑（Select Logic），但在极致性能上略有妥协。

---

## 2. 核心机制：旁路监听与就绪唤醒 (Bypass Snooping & Wakeup)

当一条带着未准备好操作数（`ready=0` 且带着 `wait_tag`）的指令进入 ISQ 后，ISQ 会变成一个"监听者"。

### 2.1 组合逻辑唤醒 (Combinational Wakeup)

在 `always_comb` 组合逻辑块中，ISQ 盯着从 P3 广播过来的 4 条 `bypass_bus`（分别来自 4 个执行组的写回通道）。

```systemverilog
// Line 36-49: 纯组合逻辑 tag 比对
assign rs1_wakeup = (bypass_bus[0].valid && !entry_payload.rs1_ready && 
                     (entry_payload.rs1_wait_tag == bypass_bus[0].tag)) ||
                    (bypass_bus[1].valid && !entry_payload.rs1_ready && 
                     (entry_payload.rs1_wait_tag == bypass_bus[1].tag)) ||
                    ... // 其他 bypass 通道

// Line 53-55: 组合逻辑 ready 信号
assign rs1_ready_final = entry_payload.rs1_ready || rs1_wakeup;

// Line 58: issue_en 判定立刻使用 ready_final
assign issue_en = entry_valid && rs1_ready_final && rs2_ready_final && 
                  rs3_ready_final && !fu_busy && !flush_late;
```

**这部分支持零延迟唤醒**: 当拍 bypass 到达 → 当拍 `rs1_wakeup=1` → 当拍 `rs1_ready_final=1` → 如果 FU 不忙，当拍 `issue_en=1`。

### 2.2 时序逻辑数据锁存 (Sequential Data Capture)

当 bypass 匹配发生后，ISQ 不仅会组合唤醒，还会在**下一个时钟边沿**把匹配到的数据**永久锁存**到内部寄存器中：

```systemverilog
// Line 70-76: 在时钟边沿锁存 bypass 数据
always_ff @(posedge clk or negedge rst_n) begin
    if (entry_valid) begin
        if (rs1_wakeup) begin
            entry_payload.rs1_ready <= 1'b1;    // ← 寄存器锁存 ready 位
            entry_payload.rs1_data  <= bypass_bus[0].valid && ... ? 
                                       bypass_bus[0].data : ...;  // ← 寄存器锁存数据
        end
    end
end
```

**为什么需要锁存数据？** 因为 bypass 总线是一个瞬时脉冲信号，只在当拍有效。如果当拍 FU 正好忙碌（`fu_busy=1`），指令无法发射，那么 bypass 数据会在下一拍消失。通过时序锁存，ISQ 把数据"抓住"并永久保存，等 FU 空闲时再使用。

### 2.3 核心发射决定信号：`issue_en`

决定指令何时从 ISQ 发射至执行单元的终极组合逻辑信号是 **`issue_en`**。其代码实现极其严密：

```systemverilog
assign issue_en = entry_valid && rs1_ready_final && rs2_ready_final && rs3_ready_final && !fu_busy && !flush_late;
```

这包含 4 大决定性判定因子：
1. **指令存在性 (`entry_valid`)**：ISQ 条目中当前必须存有有效的待执行指令（由 P1 Dispatch 阶段写入拉高，Issue 发射后复位）。
2. **操作数全就绪 (`rsX_ready_final` 且关系)**：所有指令涉及的源操作数必须全部变为 `ready_final` 状态。
3. **执行单元不忙 (`!fu_busy`)**：该组绑定的具体物理执行单元（例如普通 ALU、除法器等）当前不能处于忙碌状态。
4. **无异常冲刷 (`!flush_late`)**：当前拍不能有晚期异常或分支预测错误触发的流水线全局冲刷。

---

## 3. 完整时序场景分析

### 场景 A: 零延迟 back-to-back 执行 (FU 不忙)

```
Cycle N:   inst0 在 FU 完成计算
           ├─ P3 arbiter 输出 bypass_bus[0] = {valid=1, tag=5, data=0x30}
           ├─ ISQ 组合逻辑: rs1_wakeup = 1 (tag 匹配)
           ├─ ISQ 组合逻辑: rs1_ready_final = 1
           ├─ ISQ 组合逻辑: issue_en = 1 (FU 不忙)
           └─ p2_fu_input_mux: ready=0, 从 bypass_bus[0] 实时抓数据 0x30 送给 FU

Cycle N+1: inst3 在 FU 开始执行 (使用 0x30)
           └─ ISQ 时序逻辑锁存: entry_payload.rs1_ready <= 1, rs1_data <= 0x30
```

**结果**: 零气泡，数据通过组合逻辑穿透。ISQ 虽然在 Cycle N+1 锁存了数据，但指令已经发射了。

---

### 场景 B: FU 忙时的数据保护 (FU 忙)

```
Cycle N:   inst0 在 FU 完成计算
           ├─ P3 arbiter 输出 bypass_bus[0] = {valid=1, tag=5, data=0x30}
           ├─ ISQ 组合逻辑: rs1_wakeup = 1
           ├─ ISQ 组合逻辑: rs1_ready_final = 1
           ├─ 但 fu_busy = 1 → issue_en = 0 (不发射)
           └─ 指令继续停留在 ISQ

Cycle N+1: bypass_bus[0] 已经切换到其他数据 (0x40)
           ├─ 但 ISQ 已经在 Cycle N 的时钟边沿锁存: 
           │  entry_payload.rs1_ready = 1
           │  entry_payload.rs1_data  = 0x30 (永久保存)
           ├─ fu_busy = 0 → issue_en = 1
           └─ p2_fu_input_mux: ready=1, 使用 ISQ 中锁存的 0x30

Cycle N+2: inst3 在 FU 开始执行 (使用正确的 0x30，不是 0x40)
```

**结果**: 数据被正确保护，不会因为 FU 忙而丢失 bypass 数据。

---

## 4. 实战拆解：Case 10K 中的双源同时旁路

在 `sim_tb/case.sv` 的 **Case 10K**（Dual-Source Simultaneous Bypass）中，这一整套逻辑发挥了淋漓尽致的威力：

### 4.1 测试指令流与依赖关系
* **`inst1 (Group 1)`**: `emit_mul(3, 1, 2)` → 计算 x3 = 10 × 3 = 30（产生 x3 的 `bypass[1]` 通道广播，带 Tag A）。
* **`inst2 (Group 0)`**: `emit_add(7, 5, 6)` → 计算 x7 = 20 + 4 = 24（产生 x7 的 `bypass[0]` 通道广播，带 Tag B）。
* **`inst3 (Group 0)`**: `emit_add(8, 3, 7)` → 计算 x8 = x3 + x7（依赖 x3 和 x7）。

### 4.2 当 `inst3` 待发射时的逻辑变化：
1. **Dispatch 阶段**：`inst3` 被写入 Group 0 的 ISQ，其 `rs1`（等待 Tag A）、`rs2`（等待 Tag B）全部未就绪。
2. **Snoop 广播时刻**：在某个时钟周期内，`inst1` 在 Group 1 计算完毕，`inst2` 在 Group 0 计算完毕。两者*在同一拍*分别把 Tag A 的数据 `30` 和 Tag B 的数据 `24` 广播在 `bypass_bus[1]` 和 `bypass_bus[0]` 上。
3. **即时唤醒**：在这一拍，`inst3` 所在的 ISQ 中，`rs1_wakeup` 和 `rs2_wakeup` 组合逻辑瞬间同时被拉高，使得 `rs1_ready_final` 和 `rs2_ready_final` 当拍全部变为 `1`。
4. **即时发车与多路分拣**：因为所有条件齐备，`issue_en` 当拍拉高，指令直接发射。`p2_fu_input_mux` 模块利用组合逻辑，直接从 `bypass_bus[1]` 中拉出 `30`，从 `bypass_bus[0]` 中拉出 `24`，合并送入 ALU。
5. **完美结果**：ALU 顺利完成 30 + 24 = 54 的计算，零时钟周期气泡！

---

## 5. 全局冲刷的避风港
```systemverilog
if (flush_late) begin
    entry_valid <= 1'b0; // 遭遇核弹，就地销毁
end
```
ISQ 是投机执行的巢穴。一旦 P4 发出 `flush_late`，ISQ 里面的指令（无论等没等齐数据）都会在下一个时钟周期被无情清除（`valid` 置 0）。这保证了流水线在异常后能被彻底洗净。

---

## 6. Flush-masked bypass behavior

The ISQ may only treat a bypass lane as a real wakeup when that lane's `valid` bit is high. `backend_top.sv` forces every bypass `valid` low during `global_flush_late`, so a same-cycle killed P3 result cannot trigger `rs*_wakeup`, cannot be latched into `entry_payload.rs*_data`, and cannot open `issue_en`.

This complements the local ISQ rule `issue_en = ... && !flush_late`: the ISQ both refuses to launch during flush and refuses to learn data from a producer killed by the same flush boundary.

---

## 7. 总结
`isq.sv` 是典型的**唤醒-选择 (Wakeup & Select)** 逻辑的具体实现。它实现了乱序处理器中最迷人的部分：指令不是按顺序走的，而是**谁的数据先准备好，谁就先发射（Data-flow driven）**。

它采用了**组合逻辑唤醒 + 时序逻辑数据锁存**的双轨道设计：
- **组合逻辑路径**：支持零延迟 back-to-back 执行（当拍 bypass 到达 → 当拍发射）
- **时序逻辑路径**：保护数据不因 FU 忙而丢失（bypass 数据在时钟边沿被锁存到 ISQ 内部）

与 `p2_fu_input_mux.sv` 的强强联手，更保证了前推网络的超高性能。
