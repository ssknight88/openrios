# typedefs.sv 深度解析 (基础数据结构)

`typedefs.sv` (`orca_types` 包) 是整个 Orca Backend 的数据基石。它定义了全局物理参数以及贯穿 P1 到 P4 各个流水线阶段的标准总线结构体。

---

## 1. 核心物理参数 (Parameters)
*   `XLEN = 64`, `FLEN = 64`: 定义了整数和浮点数据路径的位宽。
*   `ROB_DEPTH = 16`: 定义了重排序缓存的深度，直接决定了后端可以“在飞 (in-flight)”的指令数量。
*   `TAG_W = 4`: ROB 标签的位宽 (`$clog2(ROB_DEPTH)`），用于唯一标识每一条在飞指令。
*   `REG_ADDR_W = 5`: 架构/物理寄存器索引位宽（32 个寄存器）。

---

## 2. 关键握手负载结构体 (Payload Structures)

### 2.1 `isb_payload_t` (Frontend -> P1)
**前端指令流缓冲负载**：前端解码后送入后端的原始信息。
*   包含基础信息：`inst_valid`, `pc`。
*   控制信号：`exe_type` (目标执行组), `exe_subop` (具体操作), `use_rd`, `use_rs1`, `use_rs2` 等。
*   操作数特征：`rd_idx`, `imm_valid`, `imm_data`。
*   特殊标记：`is_csr` (控制状态寄存器访问), 预测信息 (`pred_taken`, `pred_target_pc`)。

### 2.2 `isq_payload_t` (P1 -> P2 -> EX)
**发射队列负载**：P1 完成重命名后，驻留在 ISQ 中等待发射的信息。
*   **身份与路由**：`self_rob_tag` (自己在 ROB 的身份), `exe_subop`。
*   **执行上下文**：`pc`, `pred_taken`, `pred_target_pc` 只作为 Group 0 的 AUIPC/BRU 快路径上下文使用；Group 1/2/3 写入时不携带真实 PC，精确异常/trace PC 由 ROB sidearray 按 tag 提供。
*   **物理操作数状态**：
    *   `rs1_ready`, `rs2_ready`, `rs3_ready`：标识操作数是否已就绪。
    *   `rs1_wait_tag` 等：如果不 ready，则记录它在等哪个老指令的结果（用于在 ISQ 内部监听 Bypass 总线）。
    *   `rs1_data` 等：如果已 ready，则存放实际的 64 位数据。

### 2.3 `lsu_req_t` (Backend -> LSU)
**访存请求负载**：Group 3 LSU 的执行请求边界。
*   地址计算使用 `base_addr + imm_data`，不依赖指令 PC。
*   请求中不携带 `pc`；load/store 异常只需返回 tag 与 cause，faulting PC 由 ROB sidearray 在 P4 精确恢复。

### 2.4 `result_payload_t` (EX -> P3 -> ROB)
**执行写回负载**：功能单元 (FU) 算完后吐出的结果，也是 Bypass 旁路总线广播的来源。
*   `result_valid`: 标识计算完成。
*   `tag_out`: 指令的 ROB Tag。
*   `result_data`: 算出的 64 位结果（用于写回 ARF 或用于 Forwarding）。
*   `exception_flag`, `mispredict_flag`: 异常与分支预测失败的报错信号。

### 2.5 `commit_payload_t` (P4 -> ARF & DST_REG)
**提交负载**：指令安全退休时，用于更新最终机器状态的信息。
*   `commit_valid`: 授权提交。
*   `commit_tag`: 正在退休的指令 Tag。
*   `rd_idx`, `result_data`: 指示 ARF 更新哪个寄存器为哪个值。

## 3. 总结
这个文件是所有其他 SV 文件能互相“听懂”对方说话的前提。任何跨阶段传输的数据增减，都必须在这里修改结构体。
