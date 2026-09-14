# ORBE FE Agent 需求文档（初步实现）

> 层定位：本文是 ORBE FE Agent 的**需求层文档**，回答"要什么、为什么、边界在哪"。
> 实现细节、代码位置、ISA_model 调用路径见同目录 `ORBE_FE_AGENT_ARCHITECTURE.md`。
> 权威实现以 `tb/modified_agents/fe/` 为准。

## 1. 文档目的与范围

本文定义 ORBE FE Agent 在 ORBE BT 验证环境中的职责、对外接口、所使用的 ISA Model DPI，以及设计需求与设计思路。本文只覆盖 **FE Agent 初步实现** 阶段，即 FE Agent 独立驱动、尚未与真实 BE/DUT 后端联调时的形态。

## 2. 初步实现

### 2.1 FE Agent 在环境中的位置

ORBE BT 验证环境由 `be_tb_top` 顶层装配，其中与 FE 相关的部分为：

```text
be_tb_top
  ├─ orbe_fe_if  fe_vif          # FE Agent <-> DUT/Wrapper 的接口实例
  ├─ fe_agent    fe_agent_h      # 本文对象
  └─ DUT 侧：rtl_v1_wrapper / mock_rtl（二选一，由编译宏决定）
```

FE Agent 位于 ISA Model 与 ORBE DUT 之间：向上从 ISA Model 取指令，向下按 ORBE FE/BE 外部接口把原始指令流交给 DUT。

```text
ISA Model (指令内存 + 生命周期)
        ▲  DPI
        │
   fe_driver ── orbe_fe_if ──▶ DUT/Wrapper ──▶ ORBE BE
        ▲
        │ new/run/finish_model
     fe_agent ◀── be_tb_top
```

### 2.2 本阶段做什么

初步实现阶段的 FE Agent 需要完成：

1. 初始化 ISA Model，并通过 plusarg 加载平台配置与测试 ELF。
2. 从 ISA Model 的虚拟内存中按 PC 取指，得到原始指令字节。
3. 判断 16-bit RVC 与 32-bit 指令，组装原始编码（不解压）。
4. 维护按程序顺序排列的 pending 队列，形成 2 条 FE lane。
5. 按 valid/ready 前缀顺序交付指令，并对未接收的 entry 做保持与压缩。
6. 处理 redirect：丢弃旧路径 pending，并从新的 `redirect_pc` 重新取指。
7. 区分"零填充结束"与"真实取指 fault"，并以异常 entry 形式把 fault 交给 BE 侧。
8. 记录足够日志（PC、指令编码、lane fire、redirect）以支持调试。

## 3. 用到的接口

FE Agent 唯一的外部接口是 `orbe_fe_if`，定义于 `tb/modified_agents/fe/orbe_fe_if.sv`。接口时钟与复位为 `clk` / `rst_n`，2 条 lane（`ORBE_FE_LANES = 2`）。

### 3.1 信号清单

| 方向 | 信号 | 位宽 | 含义 |
| --- | --- | ---: | --- |
| FE → BE | `fe_be_instr_valid[lane]` | 2 | 本拍该 lane 是否提供一条原始指令 |
| FE → BE | `fe_be_instr_pld[lane]` | 2 × 232 | 该 lane 的原始指令 payload |
| BE → FE | `be_fe_instr_ready[lane]` | 2 | 本拍 DUT 是否接收该 lane |
| BE → FE | `be_fe_redirect_valid` | 1 | 本拍发生 redirect |
| BE → FE | `be_fe_redirect_pld` | 66 | redirect 目标，含 `redirect_pc` / `interrupt_valid` / `trap_valid` |

### 3.2 指令 payload 需求

指令 payload 只承载**原始指令和前端已有信息**，不得携带后端 decode 语义（FU 路由、源/目的寄存器元数据、immediate、execution sub-op 等）。

| 字段 | 位宽 | 需求 |
| --- | ---: | --- |
| `pc` | 64 | 本条指令地址 |
| `inst_bits` | 32 | 原始指令编码；RVC 仅低 16 bit 有效、高位清零 |
| `is_compressed` | 1 | 是否为 16-bit compressed instruction |
| `pred_taken` | 1 | 分支预测方向；本阶段为静态占位值 0 |
| `pred_target_pc` | 64 | 顺序预测目标：RVC 为 `pc + 2`，其余为 `pc + 4` |
| `fetch_excp_vld` | 1 | 真实取指 fault entry 为 1，正常 entry 为 0 |
| `exception_cause` | 5 | 同步 instruction-fetch cause 编号 |
| `exception_tval` | 64 | 实际失败的取指虚拟地址 |

单 lane payload 合计 232 bit。

### 3.3 握手语义需求

指令交付通道存在双向 valid/ready，必须满足前缀顺序：

```text
fire[0] = valid[0] && ready[0]
fire[1] = valid[1] && ready[1] && fire[0]
```

- lane 0 为较老指令，lane 1 为较新指令。
- 禁止"lane 0 未 fire 而 lane 1 单独 fire"。
- 该前缀约束由 FE Agent 自己计算与保证，不依赖 DUT/Wrapper 修正。
- ready 拉低时，未接收 entry 的 payload 必须保持稳定，直到该 entry fire 或被 redirect 丢弃。

### 3.4 Redirect 需求

- `be_fe_redirect_valid` 为单周期事件语义；`be_fe_redirect_pld` 与 valid 同拍有效。
- redirect 优先级高于普通指令交付；同拍冲突时 redirect 优先。
- 收到 redirect 后，必须丢弃所有未 fire 的旧 pending entry。
- 在第 N 拍采样到 redirect 后，该拍暂停普通指令输出；第 N+1 拍从 `redirect_pc` 重新取指，且重新输出的首条指令必须满足 `pc == redirect_pc`。
- 连续 redirect 时，以最新一次采样的目标为准。

### 3.5 时钟与复位需求

- `rst_n = 0` 期间，FE Agent 必须保持 `fe_be_instr_valid = 0` 并清零 payload，不得让 Wrapper 把复位期间的取值当请求。
- 复位释放后才开始取指与驱动。

## 4. 用到的 DPI

FE Agent 把 ISA Model 当作**指令内存**和**阶段收尾状态来源**，只使用只读/取指类 DPI。

### 4.1 功能 DPI

| DPI | 用途 |
| --- | --- |
| `isa_dpi_create(core_num, rob_size)` | 创建单核共享模型（本阶段 `1, 16`） |
| `isa_dpi_load_config(yaml)` | 加载平台 YAML 配置 |
| `isa_dpi_load_elf(elf)` | 装载测试 ELF（提供指令字节与入口信息） |
| `isa_dpi_add_arg(elf)` | 向目标程序传 argv |
| `isa_dpi_finalize_config()` | 完成配置，允许后续取指 |
| `isa_dpi_get_spec_pc(core_id)` | 取得入口 PC |
| `isa_dpi_fetch_mem_bank_virt(core_id, pc, 2, buf, trap)` | 按虚拟地址取 2 字节指令块 |
| `isa_dpi_is_to_exit()` | 判断模型是否进入退出状态 |
| `isa_dpi_is_good()` | 退出后判断结果是否 PASS |
| `isa_dpi_destroy()` | 释放共享模型 |

### 4.2 可选日志 DPI

由 plusarg 触发，用于生成参考侧日志：

| DPI | 用途 |
| --- | --- |
| `isa_dpi_set_run_log(path)` / `isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL)` | run log 路径与开关 |
| `isa_dpi_set_commit_log(path)` / `isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL)` | commit log 路径与开关 |

### 4.3 明确不使用的 DPI

`isa_dpi_decode_and_issue`、`isa_dpi_execute_insn`、`isa_dpi_commit`、`isa_dpi_commit_auto`、`isa_dpi_flush`、`isa_dpi_flush_all`、`isa_dpi_tick_finish`、`isa_dpi_trigger_trap`、`isa_dpi_proc_mem_*`、`isa_dpi_store_commit` 等属于后端生命周期，不属于 FE 职责。

### 4.4 输入来源

- `+ISA_CFG=<platform.yaml>`：平台配置路径，缺失即 fatal。
- `+ISA_ELF=<test.elf>`：测试 ELF 路径，缺失即 fatal。
- `+ISA_RUN_LOG=<path>` / `+ISA_COMMIT_LOG=<path>`：可选日志路径。

## 5. Agent 设计需求

### 5.1 功能需求

| 编号 | 需求 |
| --- | --- |
| FE-F1 | 从 ELF 入口 PC 开始按程序顺序产生原始指令流 |
| FE-F2 | RVC 保留原始 16-bit 编码于 `inst_bits[15:0]`，`inst_bits[31:16]` 清零，`is_compressed=1` |
| FE-F3 | 32-bit 指令保留原始 32-bit 编码，`is_compressed=0` |
| FE-F4 | 每条 entry 的 `pred_target_pc` 为顺序目标（`pc+2` / `pc+4`），`pred_taken=0` |
| FE-F5 | 未 fire 的 entry 必须保持，且在下一次展示时压缩到 lane 0 |
| FE-F6 | 零填充（`16'h0000`）按结束处理，不产生非法指令 entry |
| FE-F7 | 真实取指 fault 产生异常 entry，并在其后停止产生更年轻的 entry |
| FE-F8 | redirect 丢弃旧路径 pending 并从 `redirect_pc` 重启 |

### 5.2 接口与时序需求

| 编号 | 需求 |
| --- | --- |
| FE-T1 | 满足 §3.3 前缀 fire 规则，绝不出现 `fire[1]=1 且 fire[0]=0` |
| FE-T2 | ready 拉低时 payload 稳定，不被新指令覆盖 |
| FE-T3 | redirect 优先于普通交付；采样拍暂停输出，下一拍重建 |
| FE-T4 | `rst_n=0` 期间输出静止且 payload 清零 |
| FE-T5 | 任意周期不得出现"lane 1 valid 而 lane 0 invalid" |

### 5.3 异常 entry 需求

- `pc` 为逻辑指令起始地址；`inst_bits = 32'h0000_0013`（占位 NOP）；`is_compressed=0`；`pred_taken=0`；`pred_target_pc=pc`。
- `fetch_excp_vld=1` 是异常语义的唯一来源，BE 不得依赖占位编码判断异常。
- `exception_cause` 取同步 instruction-fetch cause 的低 5 bit，当前支持 `INSN_ADDR_MISSALIGN=0x0`、`INSN_ACCESS_FAULT=0x1`、`INSN_PAGE_FAULT=0xc`。
- `exception_tval` 为实际失败的取指虚拟地址：低 halfword fault 为 `pc`，32-bit 指令 high halfword fault 为 `pc+2`。
- 不支持的 cause 必须报错，不得静默转成 EOF 或 cause 0。
- 异常 entry 必须遵守与普通 entry 相同的 ready/valid、lane 顺序与稳定性规则。

### 5.4 职责边界需求

- FE Agent 只保证"外部可见的取指与交付协议"，不解释后端语义。
- 例外地，本阶段 FE 是共享 ISA Model 的创建者与销毁者；集成模式下的所有权约定见架构文档。
- FE 不调用 `isa_dpi_trigger_trap()`，cause/tval 到 trap 的转换由 BE/Wrapper 完成。

### 5.5 可观测性需求

必须能通过日志区分：入口 PC、每条 entry 的 PC/编码/压缩标记、取指异常、redirect 捕获与重启、以及阶段结束判定。

## 6. Agent 设计的大致思路

### 6.1 组件划分

采用"壳 + 驱动"两级：

- `fe_agent`：入口壳，持有配置并创建 `fe_driver`，对外暴露 `run()` / `shutdown()` / `finish_model()`。
- `fe_driver`：全部取指、队列、握手、redirect、生命周期逻辑的载体。
- `orbe_fe_if`：只承载 FE 与 DUT 之间的事务，FE 不感知 Wrapper 内部结构。

### 6.2 取指思路

按 2 字节粒度取指：先读 `pc` 处 2 字节；若低 halfword 指示 32-bit 指令，再读 `pc+2` 的 2 字节并拼接。读取统一走 `isa_dpi_fetch_mem_bank_virt`，由 ISA Model 负责地址翻译与访问检查，FE 不自己做 MMU。

### 6.3 队列与保持思路

维护一个按程序顺序排列、容量等于 lane 数的 pending 队列：

- `next_pc` 在"指令进入队列"时推进，保证被 stall 的 entry 不会被重复取指。
- 每拍按 ready 计算哪些 entry 被接收；未接收的 entry 压缩前移（这天然实现了"lane 1 → lane 0"）。
- 压缩后再补满队尾，形成下一拍展示的 group。

### 6.4 握手与前缀顺序思路

FE 自己计算 fire：只有当 lane 0 同拍 fire 时，lane 1 才允许 fire；据此决定哪些 entry 保留。该约束不外包给 Wrapper。

### 6.5 redirect 思路

redirect 走"采样 → 下一拍生效"两段式：采样拍到 redirect 后立刻丢弃旧 pending 并停止输出；下一拍从 `redirect_pc` 重新预取并展示。redirect 优先于普通交付与压缩。

### 6.6 生命周期思路

- 初始化：复位释放后创建/配置/装载 ISA Model，取入口 PC。
- 运行：主循环每拍检查退出状态、redirect、握手与 refill。
- 收尾：模型请求退出后停止输出并返回；结束阶段检查 `is_to_exit` / `is_good` 并销毁模型。

## 7. 验收要点（初步）

在 FE-only 环境中，以下行为同时成立即视为初步实现通过：

1. 从入口 PC 起连续送出符合程序顺序的指令流。
2. RVC 与 32-bit 指令的 `inst_bits` / `is_compressed` / `pred_target_pc` 符合 §5.1。
3. ready 拉低时 entry 保持；lane 0 fire、lane 1 未 fire 时，原 lane 1 在下一拍压缩到 lane 0。
4. 任意拍不出现非法 lane 组合与前缀 fire 违规。
5. redirect 后旧路径 entry 不再输出，且重启首条 `pc == redirect_pc`。
6. 取指 fault 生成格式正确的异常 entry 并在其后停止产生 younger entry。

> 完整集成后，`is_to_exit` / `is_good` / `destroy` 的所有权将移交给统一的 Model owner，本文相关条目需同步修订。

## 8. 与架构文档的分工

| 问题 | 本文（需求层） | 架构文档 |
| --- | --- | --- |
| 要不要做、做到什么程度 | ✅ | — |
| 接口字段与语义 | ✅ | 引用 |
| 用哪些 DPI、为什么 | ✅ | 精确到函数与文件行号 |
| 怎么实现、代码在哪 | — | ✅ |
| 关键逻辑伪代码 | —— | ✅ |
| ISA_model 内部调用路径 | — | ✅ |
