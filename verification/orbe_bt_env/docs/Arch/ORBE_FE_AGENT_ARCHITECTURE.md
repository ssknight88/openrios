# ORBE FE Agent 架构文档

> 层定位：本文是 ORBE FE Agent 的**架构/实现层文档**，回答"怎么实现、代码在哪、ISA_model 里落在哪个函数"。
> 需求、接口语义与边界见同目录 `ORBE_FE_AGENT_REQUIREMENT.md`。
> 权威实现以 `tb/modified_agents/fe/` 为准；`tb/agents/fe/` 为早期变体，不在本文范围内。

## 1. 文档目的与范围

本文记录 ORBE FE Agent 当前实现的代码结构、状态、控制流、关键逻辑伪代码，以及每一条 ISA Model DPI 在 ISA_model 仓库中的精确落点。所有路径以下列两个根为基准：

```text
ORBE_ENV_ROOT = openrios/verification/orbe_bt_env
ISA_MODEL_ROOT = <isa_model checkout>
```

本文描述的是 **FE-only 初步实现**；与真实后端联调后的生命周期变更在 §9 说明。

## 2. 代码结构与编译集成

### 2.1 文件清单与角色

| 文件（相对 `ORBE_ENV_ROOT`） | 角色 |
| --- | --- |
| `tb/modified_agents/fe/orbe_fe_if.sv` | `orbe_fe_types_pkg` 类型定义 + `orbe_fe_if` 接口 |
| `tb/modified_agents/fe/fe_agent.sv` | 入口壳类 `fe_agent` |
| `tb/modified_agents/fe/fe_driver.sv` | 驱动类 `fe_driver`，全部逻辑所在 |
| `tb/env/be_config.sv` | 配置类 `be_config`（FE 侧经别名使用） |
| `tb/env/be_reporter.sv` | 报告类 `be_reporter`（`print` / `fatal` / `fatal_static`） |
| `dpi/isa_dpi_pkg.sv` | ISA Model DPI 的 SV 声明与常量 |
| `dpi/isa_dpi_wrapper.cc` | DPI-C 包装层，持有唯一 `FuncMultiCore*` |
| `cfg/filelist/tb.f` / `cfg/filelist/common.f` | 源码清单与 include 路径 |

### 2.2 类型定义

`orbe_fe_if.sv` 中：

- `orbe_fe_types_pkg::ORBE_FE_LANES = 2`
- `orbe_fe_types_pkg::orbe_fe_instr_pld_t`：64 + 32 + 1 + 1 + 64 + 1 + 5 + 64 = 232 bit
- `orbe_fe_types_pkg::orbe_fe_redirect_pld_t`：64 + 1 + 1 = 66 bit
- `orbe_fe_if` 提供 `dut` 与 `tb` 两个 modport；`fe_driver` 使用 `virtual orbe_fe_if.tb`

### 2.3 编译集成

`orbe_fe_if.sv` 由 filelist 单独编译：

```text
cfg/filelist/tb.f:18    tb/modified_agents/fe/orbe_fe_if.sv
cfg/filelist/tb.f:7     +incdir+tb/modified_agents/fe
```

FE 的类由 `be_tb_pkg` 打包 include：

```systemverilog
// tb/pkg/be_tb_pkg.sv:10-13
typedef be_config   orbe_fe_config;
typedef be_reporter orbe_fe_reporter;
`include "../modified_agents/fe/fe_driver.sv"
`include "../modified_agents/fe/fe_agent.sv"
```

因此 `fe_driver` 里的 `orbe_fe_config` / `orbe_fe_reporter` 是 `be_config` / `be_reporter` 的别名，与 `tb/env/` 是同一份实现。

`tb/agents/fe/` 目录在 `cfg/filelist/common.f:8` 只提供 `riscv_rvc_pkg.sv`，其 `fe_driver.sv` 未被 `be_tb_pkg` include。

### 2.4 顶层装配与调用

```systemverilog
// tb/top/be_tb_top.sv
orbe_fe_if fe_vif(clk, rstn);            // :23
fe_agent   fe_agent_h;                   // :16

fe_agent_h = new(fe_vif, cfg);           // :266
fork
  fe_agent_h.run();                      // :280
  be_agent_h.run();
  cache_agent_h.run();
  ...
join

fe_agent_h.finish_model();               // :293
```

`shutdown()` 在 `be_tb_top` 中未被调用；`finish_model()` 内部完成模型销毁。

## 3. 类结构与状态

### 3.1 `fe_agent`（`fe_agent.sv`）

纯委托壳，无自有状态：

| 成员 | 说明 |
| --- | --- |
| `orbe_fe_config cfg` | 配置引用，`null` 时 `fatal_static` |
| `fe_driver driver` | 在 `new()` 中创建 |
| `run()` / `shutdown()` / `finish_model()` | 逐一直通 `driver` |

### 3.2 `fe_driver` 成员（`fe_driver.sv`）

| 成员 | 行 | 说明 |
| --- | ---: | --- |
| `LANES` | 2 | `= orbe_fe_types_pkg::ORBE_FE_LANES`（2） |
| `MODEL_CORE_ID` | 3 | `0`，单核 |
| `MODEL_ROB_SIZE` | 4 | `16`，传给 `isa_dpi_create` |
| `vif` | 6 | `virtual orbe_fe_if.tb` |
| `pending_valid[LANES]` | 11 | 队列 entry 有效位 |
| `pending_info[LANES]` | 12 | 队列 entry payload |
| `compact_valid` / `compact_info` | 13-14 | 压缩暂存 |
| `sampled_fire[LANES]` | 15 | 本拍驱动出的 valid（用于回采握手） |
| `next_pc` | 16 | 下一个待取指 PC |
| `fetch_eof` | 17 | 零填充结束标志 |
| `fetch_stop_after_fault` | 18 | 取指 fault 后停止产生 younger entry |
| `model_created` | 19 | 模型生命周期保护 |
| `redirect_pending` | 20 | 已采样、待下一拍生效的 redirect |
| `redirect_pc` | 21 | redirect 目标 |

队列约定：下标 0 恒为最老 entry，映射到 lane 0；其余按下标映射到后续 lane。

## 4. 运行流程实现

### 4.1 构造与复位等待

`fe_driver.run()`（`:284`）入口：

1. `drive_idle()` 先把 `valid=0`、`pld=0` 驱干净，避免复位期间出现未知值。
2. `wait (vif.rst_n === 1'b1)` 等待复位释放（`be_tb_top` 在创建 agent 前已完成复位）。
3. `initialize_model()`。
4. 清空队列与状态，`refill_pending()` 预取；若队列仍为空则 fatal。
5. `drive_pending()` 在进入循环前先摆好第一组。

### 4.2 模型初始化 `initialize_model()`（`:60`）

```text
+ISA_CFG 缺失 -> fatal
+ISA_ELF 缺失 -> fatal
isa_dpi_create(1, 16)                     -> check_rc
model_created = 1
[可选] +ISA_RUN_LOG    -> isa_dpi_set_run_log + isa_dpi_enable_run_log(ISA_API_LOG_GLOBAL)
[可选] +ISA_COMMIT_LOG -> isa_dpi_set_commit_log + isa_dpi_enable_commit_log(ISA_API_LOG_GLOBAL)
isa_dpi_load_config(isa_cfg)              -> check_rc
isa_dpi_load_elf(isa_elf)                 -> check_rc
isa_dpi_add_arg(isa_elf)
isa_dpi_finalize_config()                 -> check_rc
next_pc = isa_dpi_get_spec_pc(0)
print_fe(1, entry_pc)
```

`check_rc`（`:31`）把任何非 `ISA_API_PASS` 转为 `reporter.fatal`。

### 4.3 主循环 `run()`（`:284` 的 `forever`）

每个 `@(posedge vif.clk)` 依次处理：

1. **退出检查**：`model_created && isa_dpi_is_to_exit()` → `drive_idle()` 并 `return`。
2. **redirect 采样**：`be_fe_redirect_valid === 1'b1` 时保存 `redirect_pc`、置 `redirect_pending`、清空队列与 `fetch_eof` / `fetch_stop_after_fault`、`drive_idle()`、`continue`。
3. **redirect 生效**：`redirect_pending` 为真时调用 `apply_redirect()` 并清标志。
4. **握手回采**：逐 lane 计算 `sampled_fire[lane] = fe_be_instr_valid[lane] && (be_fe_instr_ready[lane] === 1'b1)`。
5. **队列更新**：`remove_accepted_entries(sampled_fire)` → `refill_pending()` → `drive_pending()`。

注意：`sampled_fire` 回采的是 FE 自己驱动出的 `fe_be_instr_valid`（非阻塞赋值后的当前值），不是 `pending_valid`，因此与 ready 的采样点一致。

### 4.4 收尾

- `shutdown()`（`:346`）：若 `model_created` 则 `isa_dpi_destroy()` 并清标志。
- `finish_model()`（`:353`）：
  1. 未创建模型直接返回；
  2. `isa_dpi_is_to_exit()` 为假 → fatal；
  3. `pass = isa_dpi_is_good()`，打印 `[DPI_EXIT_RESULT] PASS|FAIL`；
  4. `isa_dpi_destroy()`；
  5. `!pass` → fatal。

## 5. 关键逻辑实现

### 5.1 `fetch_instruction()`（`:90`）

流程：

1. 用 `lo[0:1]` 接收 `isa_dpi_fetch_mem_bank_virt(0, pc, 2, lo, trap_type)`。
2. `rc != ISA_API_PASS` → 置 `fetch_exception=1`、`fetch_ok=1`、`instr=32'h0000_0013`，调用 `report_fetch_fault(pc, pc, trap_type, ...)`，返回。
3. `compressed = {lo[1], lo[0]}`（小端拼接）。
4. `compressed == 16'h0000` → `end_of_stream=1`，返回（零填充结束，不产生 entry）。
5. `compressed[1:0] != 2'b11` → RVC：`instr = {16'b0, compressed}`、`is_compressed=1`、`instr_bytes=2`，返回。
6. 否则再取 `hi`：`isa_dpi_fetch_mem_bank_virt(0, pc+2, 2, hi, trap_type)`；失败 → 异常 entry，`report_fetch_fault(pc, pc+2, ...)`。
7. 成功：`instr = {hi[1], hi[0], lo[1], lo[0]}`、`instr_bytes=4`。

`report_fetch_fault()`（`:42`）先用 `is_supported_fetch_cause()`（`:36`）校验 `trap_type ∈ {0x0, 0x1, 0xc}`，不支持则 fatal；随后 `exception_cause = trap_type[4:0]`、`exception_tval = failed_access_pc`。

### 5.2 `fetch_pending_entry()`（`:159`）

调用 `fetch_instruction(next_pc, ...)` 后：

- `end_of_stream` → `fetch_eof = 1` 并返回（`fetch_ok` 保持 0，调用方据此停止 refill）。
- `!fetch_ok` → fatal。
- 正常/异常 entry 统一写入：`pc = next_pc`、`inst_bits`、`is_compressed`、`pred_taken = 0`。
- 若 `fetch_exception`：`pred_target_pc = next_pc`，填 `fetch_excp_vld` / `exception_cause` / `exception_tval`，并置 `fetch_stop_after_fault = 1`；**不推进 `next_pc`**。
- 否则：`pred_target_pc = next_pc + instr_bytes`，异常字段清零，`next_pc += instr_bytes`。

### 5.3 `refill_pending()`（`:238`）

统计 `pending_valid` 数量，在 `count < LANES && !fetch_eof && !fetch_stop_after_fault` 时循环调用 `fetch_pending_entry(count, ok)`，`!ok` 时跳出；最后把 `count..LANES-1` 的槽清零。由于 `next_pc` 在 entry 入队时推进，被 stall 的 entry 不会被重复取指。

### 5.4 `remove_accepted_entries(edge_fire)`（`:206`）

两遍扫描：

1. 计算前缀 fire：`fire[0] = pending_valid[0] && edge_fire[0]`；`fire[lane] = pending_valid[lane] && edge_fire[lane] && fire[lane-1]`。
2. 把 `pending_valid && !fire` 的 entry 依序写入 `compact_*`，再回填 `pending_*`。

该压缩即"lane 1 未 fire 时下一拍前移到 lane 0"的实现。

### 5.5 `apply_redirect()`（`:261`）与优先级

`apply_redirect()` 清空 `pending_*` 与 `compact_*`，`next_pc = redirect_pc`，清 `fetch_eof` / `fetch_stop_after_fault`，再 `refill_pending()` 并打日志。

优先级由主循环顺序保证：redirect 采样分支带 `continue`，当拍不进入握手/压缩路径，因此 redirect 优先于普通交付；生效落在下一拍。

## 6. 关键逻辑伪代码

### 6.1 主循环

```text
run():
    drive_idle()
    wait(rst_n == 1)
    initialize_model()
    clear queue / fetch_eof / fetch_stop_after_fault
    refill_pending()
    assert queue not empty
    drive_pending()

    forever:
        @(posedge clk)
        if is_to_exit(): drive_idle(); return

        if be_fe_redirect_valid:
            redirect_pc      = be_fe_redirect_pld.redirect_pc
            redirect_pending = 1
            clear queue and compact
            fetch_eof = 0; fetch_stop_after_fault = 0
            drive_idle()
            continue

        if redirect_pending:
            apply_redirect(); redirect_pending = 0

        for lane in 0..LANES-1:
            sampled_fire[lane] = fe_be_instr_valid[lane] && (be_fe_instr_ready[lane] === 1)

        remove_accepted_entries(sampled_fire)
        refill_pending()
        drive_pending()
```

### 6.2 取指

```text
fetch_instruction(pc):
    rc = fetch_mem_bank_virt(core=0, pc, 2) -> lo
    if rc != PASS:
        return EXCEPTION_ENTRY(pc, tval = pc)

    low = {lo[1], lo[0]}
    if low == 0x0000:  return EOF
    if low[1:0] != 2'b11:
        return ENTRY(pc, inst = {16'h0, low}, compressed = 1, bytes = 2)

    rc = fetch_mem_bank_virt(core=0, pc+2, 2) -> hi
    if rc != PASS:
        return EXCEPTION_ENTRY(pc, tval = pc+2)

    return ENTRY(pc, inst = {hi[1],hi[0],lo[1],lo[0]}, compressed = 0, bytes = 4)

EXCEPTION_ENTRY(pc, tval):
    require trap_type in {0x0, 0x1, 0xc} else fatal
    inst_bits = 32'h0000_0013; is_compressed = 0; pred_taken = 0
    pred_target_pc = pc; fetch_excp_vld = 1
    exception_cause = trap_type[4:0]; exception_tval = tval
```

### 6.3 队列压缩与补满

```text
remove_accepted_entries(edge_fire):
    fire[0] = pending_valid[0] && edge_fire[0]
    for lane in 1..LANES-1:
        fire[lane] = pending_valid[lane] && edge_fire[lane] && fire[lane-1]
    w = 0
    for lane in 0..LANES-1:
        if pending_valid[lane] && !fire[lane]:
            compact[w] = pending[lane]; w++
    pending = compact

refill_pending():
    n = count(pending_valid)
    while n < LANES and !fetch_eof and !fetch_stop_after_fault:
        ok = fetch_pending_entry(n)
        if !ok: break
        n++
    clear pending[n .. LANES-1]
```

### 6.4 redirect

```text
// cycle N: sample
if be_fe_redirect_valid:
    redirect_pc = pld.redirect_pc
    drop old queue; drive_idle(); continue

// cycle N+1: rebuild
if redirect_pending:
    clear queue; next_pc = redirect_pc
    fetch_eof = 0; fetch_stop_after_fault = 0
    refill_pending()
    redirect_pending = 0
```

## 7. 在 ISA_model 仓库中的调用路径

### 7.1 三层调用关系

FE 侧的 DPI 调用要穿过三层才落到 ISA_model 的实现：

```text
fe_driver.sv
   │  import "DPI-C" 声明
   ▼
dpi/isa_dpi_pkg.sv        (SV 侧声明与常量)
   ▼
dpi/isa_dpi_wrapper.cc    (DPI-C 包装，持有 static FuncMultiCore* g_sim；本仓库自有)
   ▼
src/libs/IsaApi.h         (ISA_model 对外 C++ API)
   ▼
src/libs/lib_FuncMultiCore.cpp   (API → FuncMultiCore/SpecCore 方法)
   ▼
src/arch/processors/FuncMultiCore.cpp / src/isa_riscv/SpecCore.cpp  (真正实现)
```

### 7.2 逐 DPI 路径表

在编 FE 驱动实际调用的条目（`—` 表示该层不存在/不经过）：

| SV DPI | `isa_dpi_pkg.sv` | `isa_dpi_wrapper.cc` | `IsaApi.h` | `lib_FuncMultiCore.cpp` | 深层实现 |
| --- | ---: | ---: | ---: | ---: | --- |
| `isa_dpi_create` | 34 | 107 | 176 | 184 `funcMultiCore_create` | `new FuncMultiCore(core_num, rob_size)` |
| `isa_dpi_destroy` | 38 | 120 | 177 | 189 `funcMultiCore_destroy` | `delete sim_ptr` |
| `isa_dpi_load_config` | 173 | 477 | 279 | 474 `funcMultiCore_loadConfigFile` | `FuncMultiCore::loadConfigFile` @ `src/arch/processors/FuncMultiCore.cpp:530` |
| `isa_dpi_load_elf` | 138 | 415 | 259 | 425 `funcMultiCore_loadElf` | `FuncMultiCore::loadElf` @ `src/arch/processors/FuncMultiCore.cpp:541` |
| `isa_dpi_add_arg` | 148 | 434 | 262 | 440 `funcMultiCore_addArg` | `FuncMultiCore::addArg` |
| `isa_dpi_finalize_config` | 176 | 483 | 280 | 479 `funcMultiCore_finalizeConfig` | `FuncMultiCore::finalizeConfig` @ `src/arch/processors/FuncMultiCore.cpp:409` |
| `isa_dpi_get_spec_pc` | 121 | 383 | 252 | 390 `funcMultiCore_getCoreSpecPc` | `SpecCore::specNextPc` @ `src/isa_riscv/SpecCore.cpp:624` |
| `isa_dpi_fetch_mem_bank_virt` | 68 | 288 | 214 | 250 `funcMultiCore_fetchMemBankVirt` | `FuncMultiCore::fetchMemBankVirt` @ `src/arch/processors/FuncMultiCore.cpp:834` |
| `isa_dpi_is_to_exit` | 189 | 521 | 288 | 511 `funcMultiCore_isToExit` | `htif_device.to_exit` |
| `isa_dpi_is_good` | 190 | 527 | 289 | 516 `funcMultiCore_isGood` | `htif_device.is_good` |
| `isa_dpi_enable_run_log` | 366 | 864 | 431 `enable_run_log` | — | 全局日志（`src/utils/logs/`） |
| `isa_dpi_set_run_log` | 369 | 870 | 434 `set_run_log` | — | 同上 |
| `isa_dpi_enable_commit_log` | 370 | 872 | 436 `enable_commit_log` | — | 同上 |
| `isa_dpi_set_commit_log` | 373 | 878 | 439 `set_commit_log` | — | 同上 |

常量：`ISA_API_PASS = 0`、`ISA_API_FAIL = -1`（`isa_dpi_pkg.sv:5/8`，与 `IsaApi.h` 一致）；`ISA_API_LOG_GLOBAL = -1`（`isa_dpi_pkg.sv:10`）。

### 7.3 取指调用链展开

`isa_dpi_fetch_mem_bank_virt` 是 FE 唯一的热路径调用，完整链路为：

```text
fe_driver.fetch_instruction()
  -> isa_dpi_fetch_mem_bank_virt(...)                 dpi/isa_dpi_pkg.sv:68
  -> isa_dpi_fetch_mem_bank_virt(...)                 dpi/isa_dpi_wrapper.cc:288
       校验 g_sim 非空、开放数组容量足够，取连续地址
  -> funcMultiCore_fetchMemBankVirt(...)              src/libs/IsaApi.h:214
  -> funcMultiCore_fetchMemBankVirt(...)              src/libs/lib_FuncMultiCore.cpp:250
       把返回码与 ISA_RISCV::TrapType 转成 uint64 trap_type
  -> FuncMultiCore::fetchMemBankVirt(core_id, ...)    src/arch/processors/FuncMultiCore.cpp:834
       取 mmus[core_id]、memory、cores[core_id].priv_state
  -> fetchMemBankVirtImpl(...)                        src/arch/processors/FuncMultiCore.cpp:783
       1) 若开启 ISA_MODEL_MISALIGN_CHECK_ENABLED 且 vaddr 为奇数
          -> trap = INSN_ADDR_MISSALIGN, FAIL
       2) 按 4 KiB 页边界切块，逐块构造 MemReq{mem_op = FETCH}
       3) mmu.translate(req, priv, virt)；trap.valid -> 返回 trap
       4) 逐 2 字节 memory.accessValid(pa, READ) 检查
          失败 -> trap = INSN_ACCESS_FAULT, FAIL
       5) memory.read(pa, step, dst)
       6) 全部成功 -> trap = NO_TRAP, PASS
```

FE 侧据此把非 PASS 解释为 fetch fault，并把 `trap_type` 低 5 bit 作为 `exception_cause`。

### 7.4 入口 PC 路径

```text
fe_driver.initialize_model()
  -> isa_dpi_get_spec_pc(0)                  dpi/isa_dpi_pkg.sv:121 / wrapper:383
  -> funcMultiCore_getCoreSpecPc             IsaApi.h:252 / lib_FuncMultiCore.cpp:390
  -> SpecCore::specNextPc()                  src/isa_riscv/SpecCore.cpp:624
       若 ROB 非空，自 tail→head 找第一个 output.dir.redirect 为真的 entry，
       返回其 next_pc；否则返回 CoreState::pc
```

### 7.5 生命周期与日志

- `g_sim` 是 `isa_dpi_wrapper.cc` 内的 static 句柄，同一时刻仅允许一个模型；重复 `isa_dpi_create` 返回 `ISA_API_FAIL`。
- 本环境中 **只有 `fe_driver` 调用 `isa_dpi_create` / `isa_dpi_destroy`**；`be_getter.sv:225`、`be_agent.sv:1675` 只读 `isa_dpi_get_spec_pc`；`cosim_pkg.sv:105` 使用独立的 `isa_cosim_dpi_create`（另一句柄 `g_cosim_sim`），两者互不冲突。
- 日志 DPI 是全局 API，不需要模型句柄：`enable_run_log(core_id)` / `disable_run_log(core_id)`（`IsaApi.h:431-434`）。

## 8. 时序说明

| 阶段 | 行为 |
| --- | --- |
| 复位 | `drive_idle()`，`valid=0`、`pld=0`；`wait(rst_n)` |
| 首拍 | 进入循环前 `drive_pending()` 先摆第一组 |
| 普通拍 | `posedge` 采样退出/redirect/ready → 压缩 → refill → `drive_pending()`（非阻塞，下一拍稳定） |
| redirect 采样拍 N | 保存目标、清队列、`drive_idle()`、`continue`（不参与握手） |
| redirect 生效拍 N+1 | `apply_redirect()` 从 `redirect_pc` 预取并展示；本拍 `sampled_fire` 因 valid 已为 0 而全 0 |
| 退出 | `is_to_exit()` 为真 → `drive_idle()` → `return` |

payload 稳定性：`pending_info` 只有在 entry fire 或被 redirect 清空时才变化，满足 ready 拉低期间保持的要求。

## 9. 已知约束与实现注意

1. **RVC 不解压**：`inst_bits` 保留原始 16-bit（高位清零），decode 归 BE。
2. **零填充启发式**：`16'h0000` 一律按结束处理；这是工程约定，不是体系结构语义。
3. **预测字段为占位**：`pred_taken` 恒 0，`pred_target_pc` 为顺序目标。
4. **异常 cause 白名单**：仅 `0x0` / `0x1` / `0xc`，其余 fatal；`NO_TRAP` 与带 interrupt 位的 cause 不得作为 fetch exception 传出。
5. **异常 entry 不推进 `next_pc`**：靠 `fetch_stop_after_fault` 阻止后续 refill，直到 redirect 清除该状态。
6. **采样依赖仿真调度**：`sampled_fire` 在 `posedge` 回采样 FE 自己驱动的 valid，与 ready 的采样点必须一致；若集成层调整采样边沿，需同步修改 `fe_driver`。
7. **生命周期单所有者**：当前 FE 既取指又 `create`/`destroy` 共享模型。集成模式下应由统一 owner 负责 `create/load/finalize/destroy`，FE 只保留 `isa_dpi_get_spec_pc`、`isa_dpi_fetch_mem_bank_virt` 与只读退出查询。
8. **行号时效性**：§7 行号基于当前检出；ISA_model 或 wrapper 变动后需重新核对。
