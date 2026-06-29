# csr_unit.sv 深度解析 (CSR 执行单元与架构 CSR 文件)

`csr_unit.sv` 是 Group 0 中的 CSR 功能单元。它承担两类职责：一是在 P2/P3 阶段像普通执行单元一样产生 CSR 指令的 GPR 返回值和 `result_payload_t`，二是在 P4 精确提交或异常入口时更新内部的架构 CSR 状态。

---

## 1. 模块定位

CSR 在本后端中不是普通 ALU 指令。根据项目设计理念，CSR 是一个序列化屏障：

*   P1 只允许 CSR 从 `slot0`、且 ROB 为空时进入。
*   CSR in-flight 期间，后续年轻指令不能进入后端。
*   P2/P3 可以计算旧 CSR 值和新 CSR 写值，但不能提前修改架构 CSR 文件。
*   真正的 CSR 架构副作用只允许在 P4 commit 时发生。

`csr_unit.sv` 负责执行阶段和架构 CSR 文件本体；CSR 生命周期跟踪和 pending sideband 则由 `csr_control.sv` 负责。

---

## 2. 输入输出接口

### 2.1 P2/P3 执行接口

*   `en`: CSR 指令从 Group 0 ISQ 发射时拉高。
*   `self_rob_tag`: 当前 CSR 指令的 ROB tag。
*   `rs1_data`: register-form 的 `rs1` 数据，或 immediate-form 的 zero-extended `zimm`。
*   `exe_subop`: CSR 子操作，例如 `CSR_CSRRW`, `CSR_CSRRS`, `CSR_CSRRCI`。
*   `rd_idx`: GPR 返回目的寄存器。
*   `imm_data[11:0]`: CSR 地址。
*   `csr_write_intent`: P1 预先计算的“该 CSR 形式是否具有写副作用”。

### 2.2 P4 提交与异常接口

*   `p4_csr_write`: P4 已确认该 CSR 是写型 CSR，且 `CSR_PEND_BUF` 与 commit tag 匹配，可以写架构 CSR 文件。
*   `csr_pend_addr/csr_pend_wdata`: P3 缓存到 pending sideband 中的 CSR 写地址和值。
*   `exception_taken`: P4 选择异常 flush 时拉高，用于写 `mepc/mcause`。
*   `exception_pc/exception_cause`: precise trap 元数据，来自 `ROB_MetaArray[flush_tag]`。
*   `csr_mtvec_out`: 提供给 P4 redirect 逻辑的 trap vector。

---

## 3. 内部架构 CSR 状态

模块当前实现以下机器 CSR：

*   `mstatus` (`12'h300`)
*   `mie` (`12'h304`)
*   `mtvec` (`12'h305`)
*   `mepc` (`12'h341`)
*   `mcause` (`12'h342`)
*   `mip` (`12'h344`)

`legal_csr_addr` 只认可这些地址。未知 CSR 地址被视为非法 CSR 访问，并在执行结果中置 `exception_flag=1`、`exception_cause=2`，后续由 ROB/SideArray/P4 late flush 走 precise exception 路径。

---

## 4. 执行阶段行为

### 4.1 读旧 CSR 值

执行阶段先根据 `imm_data[11:0]` 组合读出 `csr_rdata`。该旧值：

*   写入 `wb_payload.result_data`
*   通过 ROB 在 P4 commit 时写入目标 GPR
*   也会出现在 bypass 网络中，供依赖该 CSR 返回值的后续逻辑使用

因为 CSR 是全局序列化的，年轻指令不会绕过 in-flight CSR 观察 speculative CSR state。

### 4.2 计算待写 CSR 值

`next_csr_wdata` 按 CSR 子操作计算：

*   `CSRRW/CSRRWI`: 写入 `rs1_data`
*   `CSRRS/CSRRSI`: 写入 `csr_rdata | rs1_data`
*   `CSRRC/CSRRCI`: 写入 `csr_rdata & ~rs1_data`

最终 `wb_payload.csr_write_enable` 由三项共同决定：

```systemverilog
csr_write_en && csr_write_intent && legal_csr_addr
```

这里 `csr_write_intent` 很关键。对 register-form `CSRRS/CSRRC`，是否写 CSR 取决于 `rs1_idx != x0`，不是 `rs1_data != 0`。因此该位必须由 P1 根据指令编码语义生成并随 ISQ payload 携带到 CSR FU。

### 4.3 非法 CSR 访问

当 CSR 地址不在当前支持集合内：

*   `exception_flag = 1`
*   `exception_cause = 2`
*   `csr_write_enable = 0`

这样 P3 不会分配 `CSR_PEND_BUF`，P4 也不会正常提交该 CSR，而是按普通同步异常进行 late flush。

---

## 5. P4 架构更新

CSR 架构文件有两个更新入口。

### 5.1 异常入口

当 `exception_taken` 为 1：

*   `mepc <= exception_pc`
*   `mcause <= exception_cause`
*   `mstatus.MPIE <= mstatus.MIE`
*   `mstatus.MIE <= 0`

这对应 precise trap 入口。异常路径优先于普通 CSR commit 写。

### 5.2 正常 CSR 写提交

当 `p4_csr_write` 为 1，才允许使用 `csr_pend_addr/csr_pend_wdata` 写 CSR 文件。

只读 CSR commit 只应清除 CSR tracker，不应写 CSR 文件。因此 `p4_csr_write` 必须与 `p4_csr_retire` 分离：

*   `p4_csr_retire`: CSR 正常退休，用于清 `csr_inflight` 和 `csr_pend`
*   `p4_csr_write`: CSR 有真实架构写副作用，用于写 CSR 文件

这个拆分避免了只读 CSR 错误重放旧 `CSR_PEND_BUF` 的 stale write。

---

## 6. 与其他模块的关系

*   `p1_rob_allocation_and_isq_write.sv`: 生成 `csr_write_intent` 并写入 `isq_payload_t`。
*   `p3_intra_group_arbiter.sv`: CSR 与 ALU0/DIV/BRU 共用 Group 0 写回通道；当前 Group 0 优先级为 `ALU0 > BRU > CSR > DIV`，CSR 高于具备 hold/retry 能力的 DIV，但低于 ALU0/BRU。
*   `csr_control.sv`: 在 P3 捕获 CSR pending side effect，并在 P4 retire 或 flush 时清理 tracker。
*   `p4_commit_control.sv`: 检查 `csr_inflight` 和 `csr_pend` 是否与 commit tag 匹配，产生 `p4_csr_retire/p4_csr_write`。
*   `rob_sidearray.sv`: 保存异常 PC/cause，供 `csr_unit` 在 P4 异常入口写 `mepc/mcause`。

---

## 7. 当前验证覆盖点

`sim_tb/case.sv` 的 Case 7 覆盖 CSR 主路径：

*   `CSRRW mtvec` 写入并回读
*   CSR read-only commit 不应写 CSR 文件
*   `CSRRS rs1!=x0` 且 `rs1_data==0` 仍应产生 CSR 写意图
*   DIV/illegal instruction precise trap 更新 `mepc/mcause`
*   illegal CSR address precise trap

当前本机 PowerShell 环境缺少 `bash/verilator/make/g++`，因此新增覆盖点需要在可用 Verilator 环境中运行确认。
