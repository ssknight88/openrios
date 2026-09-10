# LEVEL-2 观测点

## 1. 目标与统一规则

Level 2 观测点服务于数据通路还原和首个失配点定位。按照流水线节点，本页
固定为以下五大类：

1. FE-BE interface；
2. decode 之后；
3. 进入 FU 之前（before execute）；
4. 出 FU 之后（after execute）；
5. BE-LSU interface。

### 1.1 字段可用性定义

除“进入 FU 之前”以外，纳入本页 Level 2 共用提取面的字段必须满足以下
条件之一：

- `DPI 直接`：DPI-C API 或 DPI 调用参数直接给出该字段；
- `DPI 间接`：DPI 可以取得原始指令、模型状态或 per-ROB metadata，并可依据现有的确定性规则（例如 RVA23_IMAFDC_Classification.xlsx 中的指令编码与分类规则）推导或重构出目标字段。

不能稳定地从当前 DPI 取得，或者字段只代表 DUT 的调度实现细节的字段，不进入 ISA_model/DUT 共用 payload。

`self_tag`、`rob_idx`、`tag` 是事件关联键。它们用于把 DUT entry 与
ISA_model 的 `(model_core_id, rob_idx)` 对齐，不要求 ISA_model 重新产生
同名的物理 tag。

### 1.2 当前 DPI 的实际能力边界

当前 `isa_dpi_pkg.sv` / `isa_dpi_wrapper.cc` 可用于 Level 2 的主要接口为：

| DPI | 可取得的信息 |
| --- | --- |
| `isa_dpi_decode_and_issue()` | `pc`、`inst_bits`、`force_rvc` 的模型输入；建立 `(core, rob_idx)` anchor |
| `isa_dpi_decode_mnemonic()` | 由原始指令编码得到 mnemonic；当前受 `ORBE_EXTERNAL_MNEMONICS` 宏控制 |
| `isa_dpi_get_decode_metadata()` | `is_lsu`、decode 阶段 trap valid/cause/tval |
| `isa_dpi_get_lsu_issue_metadata()` | LSU issue 的分类、subop、访问属性、操作数和立即数 |
| `isa_dpi_get_execute_metadata()` | execute 阶段 trap valid/cause/tval |
| `isa_dpi_get_commit_auto_trap_info()` | `commit_auto` 之后的 trap 记录 |
| `isa_dpi_get_insn_rd_value()` | 当前 in-flight entry 的 `rd` 结果 |
| `isa_dpi_get_next_pc_of_insn()` / `isa_dpi_is_insn_redirect()` | 指令的 next PC 和 redirect 判定 |
| `isa_dpi_get_csr()` / `isa_dpi_get_priv()` | CSR 状态和当前特权级 |
| `isa_dpi_has_pending_interrupt()` / `isa_dpi_take_interrupt()` | pending interrupt 及其 redirect PC |
| `isa_dpi_translate_pte()` | 给定 virtual address 的地址转换、PTE trace 和 translation trap |

`isa_dpi_get_execute_metadata()` 只返回 trap 三元组，不是完整的 FU output
payload getter。FU 结果必须结合 `get_insn_rd_value`、redirect getter 和
execute metadata 使用。

ISA_model 的 `IsaApi.h` 中虽然声明了 `funcMultiCore_getInsnType()`，但当前
ORBE DPI wrapper/package 没有对应的 `isa_dpi_get_insn_type()` 导出。因此
本页的 `inst_type` 统一按原始编码、`is_compressed` 和
`isa_dpi_decode_mnemonic()` 间接获得；不能把未导出的函数当作现成 DPI 信号。

## 2. FE-BE interface

### 2.1 节点边界

本节点包含：

- FE -> BE instruction transaction；
- BE -> FE redirect transaction。

### 2.2 FE -> BE payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `pc` | `fe_be_instr_pld[lane].pc` | `isa_dpi_decode_and_issue()` 输入；也可由 `isa_dpi_get_insn_pc()` 交叉确认 | 自动比较 | 指令身份和顺序对齐 |
| `inst_bits` | `fe_be_instr_pld[lane].inst_bits` | `isa_dpi_decode_and_issue()` 的 `encoding` 参数 | 自动比较 | 原始指令编码 |
| `is_compressed` | `fe_be_instr_pld[lane].is_compressed` | `decode_and_issue()` 的 `force_rvc` 参数；模型内部 `Inst::is_rvc` 由此确定 | 自动比较 | `pc+2/pc+4` 和 RVC 语义 |
| `fetch_excp_vld` | FE payload | 异常 entry 触发 `isa_dpi_trigger_trap()`；随后由 `get_decode_metadata()` 取得 trap valid | DPI 间接 | 取指异常边界 |
| `fetch_excp_cause` / `exception_cause` | FE payload | `isa_dpi_trigger_trap(trap_type, ...)` 的 `trap_type`；decode metadata 可复核 | DPI 间接 | 取指异常 cause |
| `fetch_excp_tval` / `exception_tval` | FE payload | `isa_dpi_trigger_trap()` 的 `tvalue`；decode metadata 可复核 | DPI 间接 | 取指异常地址 |

取指异常 entry 的 pc、inst_bits 和 is_compressed 按 FE interface 规范记录；异常语义以 fetch_excp_* 和模型 trap metadata 为准。

### 2.3 BE -> FE redirect payload

最终 `redirect_pc` 和 `recovery_kind` 已由 Level-1 的
`commit_redirect_pc` / `commit_recovery_kind` 统一观测；本节点只保留
BE-FE 边界特有的 redirect 原因分类字段。

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `interrupt_valid` | `be_fe_redirect_pld.interrupt_valid` | `isa_dpi_has_pending_interrupt()` 与 `isa_dpi_take_interrupt()` 调用边界间接确认 | DPI 间接 | 区分 interrupt redirect |
| `trap_valid` | `be_fe_redirect_pld.trap_valid` | `get_decode_metadata()` / `get_execute_metadata()` 的 trap 信息或 trap recovery 事件 | DPI 间接 | 区分同步 trap redirect |

## 3. decode 之后

### 3.1 节点边界

本节点定义为 `decode` 输出经过 dispatch 前的规范化译码 payload。

DUT 的主要来源是 `decode.dec_info`、`decode.rs{1,2,3}_idx`、
`decode.rd_idx`、`decode.dec_is_fp_opcode`，以及
`isq_payload_assembly` 中由 decode 直接产生的静态字段。

### 3.2 规范化 decode payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `pc` | `decode_payload.pc` | `decode_and_issue()` 输入 / `get_insn_pc()` | 自动比较 | 指令关联 |
| `inst_bits` | `decode_payload.inst_bits` | `decode_and_issue()` 输入 | 自动比较 | decode 原始输入 |
| `is_compressed` | `decode_payload.is_compressed` | `force_rvc` / 模型 `Inst::is_rvc` | 自动比较 | RVC 规范化 |
| `inst_type` / mnemonic | 原始编码和 DUT decode 结果 | `isa_dpi_decode_mnemonic()`；模型 `Mnemonics` 分类 | DPI 间接 | 指令类别和 AI 标签 |
| `rs1_idx` / `rs2_idx` / `rs3_idx` | `decode.rs*_idx` | 由模型规范指令字段或原始 encoding 重构 | DPI 间接 | 源寄存器定位 |
| `rd_idx` | `decode.rd_idx` | 由原始 encoding 重构 | DPI 间接 | 目的寄存器定位 |
| `rs1_is_fp` / `rs2_is_fp` / `rs3_is_fp` | `dec_info` | mnemonic/规范 opcode 的源寄存器类型规则 | DPI 间接 | GPR/FPR 源选择 |
| `rd_is_fp` | `dec_info.rd_is_fp` | load/FP/move/convert 指令分类规则；LSU 指令还可由 LSU metadata 复核 | DPI 间接 | GPR/FPR 目的选择 |
| `use_rs1` / `use_rs2` / `use_rs3` / `use_rd` | `dec_info` | 由模型指令类别和 operand form 重构 | DPI 间接 | 依赖检查输入 |
| `is_store` | `dec_info.is_store` | 模型 mnemonic 的 store 分类 | DPI 间接 | store 路径选择 |
| `is_lsu` | `dec_info` / dispatch 分类 | `isa_dpi_get_decode_metadata().is_lsu` | DPI 直接 | LSU 与非 LSU 分流 |
| `is_atomic` | dispatch/decode 分类 | AMO/LR/SC mnemonic 分类 | DPI 间接 | 原子访问和顺序约束 |
| `is_serial` | `dec_info.is_serial` | CSR/system/atomic/fence 等模型指令类别分类 | DPI 间接 | serial 入口定位 |
| `is_fp_instruction` / `dec_is_fp_opcode` | `dec_info` / `dec_is_fp_opcode` | FP opcode/mnemonic 分类 | DPI 间接 | FPU 路径定位 |
| `imm_valid` / `imm_data` | `dec_info` | 由模型规范指令的 I/S/B/U/J/CSR/RVC immediate 规则重构 | DPI 间接 | 立即数语义 |
| `mem_funct3` | `dec_info.mem_funct3` | 普通指令 `funct3`；RVC 访存按模型 memory mapping 重构 | DPI 间接 | 访存宽度和符号属性 |
| `exe_subop` | `dec_info.exe_subop` | 由模型 instruction type、format、opcode/funct3/high-fixed 规则重构；LSU 可由 `get_lsu_issue_metadata()` 直接复核 | DPI 间接 | 执行类别 canonical key |
| `full_decode.illegal` | `dec_info.full_decode.illegal` | decode trap / illegal instruction metadata | DPI 间接 | 非法指令和异常定位 |
| `full_decode.csr_write_intent` | `dec_info.full_decode.csr_write_intent` | Zicsr opcode、funct3 和 rs1/zimm 规则 | DPI 间接 | CSR 写意图 |
| `full_decode.csr_addr` | `dec_info.full_decode.csr_addr` | `inst_bits[31:20]` / 模型 `inst_op.csr()` | DPI 间接 | CSR 地址 |
| `full_decode.rm` / `effective_rm` | decode `rm`、dispatch `effective_rm` | 原始 rm 与 `frm` CSR；`isa_dpi_get_csr()` 取得动态 frm | DPI 间接 | FP 舍入模式 |
| `trap_valid` / `trap_cause` / `trap_tval` | decode exception sideband | `isa_dpi_get_decode_metadata()` | DPI 直接 | decode 阶段异常 |

`self_tag`/`rob_idx` 在本节点作为关联键保留。`rsX_ready`、
`rsX_wait_tag`、`rs_data_sel_t`、`slot_FU_Group` 和 dispatch 的
`select_payload` 属于 DUT 调度实现信息，不作为 ISA/DUT 的规范化 decode
比较字段。

### 3.3 decode 相关 CSR 上下文

下列字段不是 decode payload 的核心语义，但在 CSR、FP 合法性和 system
instruction 诊断中需要与 decode event 一起记录：

| 字段 | DPI 来源 | 处理方式 |
| --- | --- | --- |
| `current_priv` | `isa_dpi_get_priv()` | 与 DUT 当前特权级对齐 |
| `csr_rdata` | `isa_dpi_get_csr(model_core_id, csr_addr)` | 在对应 CSR issue/decode 关联点读取旧值 |
| `frm` | `isa_dpi_get_csr(..., frm)` 的低位 | 与 DUT `frm` 对齐 |
| `fs_enabled` | `mstatus.FS` 由 `isa_dpi_get_csr()` 读出后派生 | 作为 FP/CSR legality 上下文 |
| `mstatus_tvm` / `mstatus_tw` / `mstatus_tsr` | `mstatus` CSR 对应 bit | 作为 SFENCE.VMA/WFI/SRET legality 上下文 |

CSR 指令的规范化 decode/issue 字段也归入本节点；不同 RTL 模块中的
`req_*`、`sb_*` 和 `csr_event_*` 只是同一语义在不同边界的命名：

| 字段/别名 | DUT 来源 | DPI/ISA_model 来源 | 状态 |
| --- | --- | --- | --- |
| `csr_event_addr` / `req_csr_addr` / `csr_addr` / `sb_csr_addr` | CSR decode、CSR FU request、completion sideband | `inst_bits[31:20]` / `inst_op.csr()` 重构 | DPI 间接，可比较 |
| `csr_event_rdata` / `csr_rdata` | CSR read port | `isa_dpi_get_csr(model_core_id, csr_addr)` 在对应 issue 边界读取 | DPI 间接，可比较 |
| `req_is_csr` / `is_csr` / `sb_is_csr` | CSR FU 和 completion sideband | raw instruction/mnemonic 的 CSR 分类 | DPI 间接，可比较 |
| `req_csr_write_enable` / `csr_write_enable` / `sb_csr_write_enable` | CSR FU 和 completion sideband | Zicsr opcode、`funct3` 及 `rs1/zimm` 规则 | DPI 间接，可比较 |
| `csr_event_wdata` / `req_csr_wdata` / `csr_wdata` / `sb_csr_wdata` | CSR FU write-data sideband | immediate 形式可由指令重构；寄存器形式需要 per-ROB 源操作数 | 当前不进入 Level 2 共用 payload；源操作数保留在 FU-before DUT-only |

## 4. 进入 FU 之前

### 4.1 节点边界和策略

本节点是 ISQ Group 0/1/2/3 向具体 FU 或 LSU 交付的 payload。它包含依赖
检查、寄存器文件读取和旁路选择已经产生的实际操作数。

本节点**只从 DUT 提取**，不调用 ISA_model getter 生成对应 payload，也不
参与 COSIM pass/fail。它是 AI debug 的数据通路参考。AI 使用
`inst_type`/`exe_subop` 和实际操作数重建“FU 正常条件下应该产生的结果”，
再与“出 FU 之后”的 DUT payload 对照。

### 4.2 公共和分组 payload

以下字段按实际 issue group 取有效子集：

| 字段 | DUT 来源/说明 | 用途 |
| --- | --- | --- |
| `self_tag` / `entry_self_tag` | ROB/ISQ entry tag | 指令关联 |
| `FU_Group` | ISQ header / issue payload | 具体 FU 路由 |
| `inst_type` | 由 `inst_bits/is_compressed/exe_subop` 生成的 DUT debug 分类 | AI 选择运算规则 |
| `exe_subop` | decode/ISQ issue payload | AI 选择具体操作 |
| `pc` | ALU/BRU issue payload | AUIPC、branch/jump 和定位 |
| `inst_bits` / `is_compressed` | ALU/BRU issue payload | 原始指令和长度 |
| `pred_taken` / `pred_target_pc` | ALU/BRU issue payload | branch mispredict 诊断 |
| `rs1_data` / `rs2_data` / `rs3_data` | FU_input_mux 输出；按 FU group 取 1/2/3 个源操作数 | AI 重建结果 |
| `imm_valid` / `imm_data` | ALU/LSU/CSR issue payload | immediate 操作和地址计算 |
| `full_decode` | ALU/FPU/CSR issue payload | illegal、CSR、rm 等控制解释 |
| `fetch_excp_vld` / `fetch_excp_cause` / `fetch_excp_tval` | ALU/BRU issue payload | fetch exception 传播定位 |
| `mem_funct3` / `rd_is_fp` | ISQ Group 3 issue payload | LSU 访问宽度和结果寄存器类型 |
| `store_data` | ISQ Group 3 issue payload 的 `rs2_data` | store/AMO 写数据 |
| `st_br_resolve` | LSU issue/bridge 授权快照 | plain store 顺序诊断 |
| `rs1_ready` / `rs2_ready` / `rs3_ready` | ISQ entry header | 依赖状态诊断 |
| `rs1_wait_tag` / `rs2_wait_tag` / `rs3_wait_tag` | ISQ entry header | 等待的生产者 tag |
| `FU_ready` / `loser_hold` / `global_flush_late` | FU/arbiter control | 背压、仲裁和取消原因 |
| `bypass_publish_tag` / `bypass_publish_data` | 上游完成旁路输入 | 实际操作数来源诊断 |

按 group 的最小 payload 约定为：

```text
G0 ALU/BRU:
  rs1_data, rs2_data, FU_Group, imm_data, pc, inst_bits,
  is_compressed, pred_taken, pred_target_pc, self_tag, exe_subop,
  full_decode, fetch_excp_*

G0 CSR / G0 DIV:
  rs1_data, rs2_data, imm_valid, imm_data, inst_bits,
  self_tag, exe_subop, full_decode

G1 ALU / MUL:
  rs1_data, rs2_data, imm_data, self_tag, exe_subop
  ALU/BRU 额外保留 pc、inst_bits、prediction 和 exception context

G2 FPU:
  rs1_data, rs2_data, rs3_data, self_tag, exe_subop, full_decode

G3 LSU:
  rs1_data, store_data, imm_valid, imm_data, mem_funct3,
  rd_is_fp, self_tag, exe_subop, st_br_resolve
```

## 5. 出 FU 之后

### 5.1 节点边界

本节点是 FU 或 LSU 产生 completion/writeback，并在
`CompletionScoreboard` 捕获之前的 payload。它与 Level-1 commit result
不同：本节点用于确认计算结果在进入 CompletionScoreboard 之前是否已经
正确；若本节点正确而 commit 结果错误，优先检查 CompletionScoreboard、
Buffer 或控制 sideband。

### 5.2 FU completion payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `tag_out` / `exec_tag` | completion payload | `(model_core_id, rob_idx)` 关联键 | 自动对齐 | 指令身份 |
| `result_data` | writeback payload | `isa_dpi_get_insn_rd_value()`；LSU 在 `proc_mem_load` 后查询 | 自动比较 | FU 计算/读侧结果 |
| `mispredict_flag` | ALU/arbiter payload | `isa_dpi_is_insn_redirect()` 与 DUT prediction context 共同判断 | DPI 间接 | 分支方向/预测失配 |
| `mispredict_target_pc` | ALU/arbiter payload | `isa_dpi_get_next_pc_of_insn()`；redirect 时为模型 next PC | 自动比较 | 正确 redirect target |
| `exception_flag` | completion payload | decode/execute metadata 的 `trap_valid` | DPI 直接/间接 | 异常产生点 |
| `exception_cause` | completion payload | `isa_dpi_get_execute_metadata()` 或 decode metadata | 自动比较 | 异常原因 |
| `exception_tval` | completion payload | `isa_dpi_get_execute_metadata()` 或 decode metadata | 自动比较 | 异常附加值 |
| `is_mret` / `is_sret` | completion payload | mnemonic/subop 分类；由 raw instruction 间接获得 | DPI 间接 | return recovery |

`bypass_tag` / `bypass_data` 不再作为 FU-after 的独立共用比较字段。
它们与 `tag_out` / `result_data` 同源，保留以下 DUT 协议关系即可：

```text
bypass_valid -> exec_valid
bypass_valid -> !exception_flag
bypass_valid -> bypass_tag == exec_tag
bypass_valid -> bypass_data == result_data
```

### 5.3 CSR 和 FP completion sideband

下列字段在 DUT completion payload 中存在，但当前不能全部作为
ISA_model/DUT 的 FU-after 共用自动比较字段；FU-before 仍只保留 DUT
debug record：

| 字段 | 当前处理 |
| --- | --- |
| `is_csr` | 可由 raw instruction/mnemonic 间接得到，可作为比较字段 |
| `csr_write_enable` | 可由 Zicsr opcode、funct3 和 rs1/zimm 规则间接得到，可作为比较字段 |
| `csr_addr` | 可由 `inst_bits[31:20]` / `inst_op.csr()` 间接得到，可作为比较字段 |
| `csr_wdata` | 当前 ORBE DPI 没有 per-ROB CSR write payload getter；不纳入本版 Level 2 共用 payload |
| `csr_rdata` | 由 `isa_dpi_get_csr()` 在对应 issue 前读取，作为 CSR context，不作为 completion result |
| `fpu_fflags` | 当前 ORBE DPI 没有 per-ROB execute fflags getter；不纳入本版 Level 2 共用 payload，架构结果由 Level-1 `commit_fflags` 比较 |

`csr_wdata` 和 `fpu_fflags` 的 DUT 值不能在本版伪装成已经有 DPI 对应值。
如果后续要在 FU-after 做这两个字段的自动比较，需要新增 per-ROB DPI
metadata ABI；在 ABI 增加前，它们不进入 Level 2 共用 comparison packet。

### 5.4 recovery、trap 和 CSR 状态上下文

这些字段来自 FU completion 后的 recovery/CSR 路径，是解释
`exception_flag`、redirect 和 CompletionScoreboard 行为所需的上下文。

最终 redirect target/kind 已由 Level-1 统一观测，本节不重复列出
`redirect_pc` / `redirect_kind` / `recovery_kind`。

| 字段/信息 | DUT 来源 | DPI/ISA_model 来源 | 状态 |
| --- | --- | --- | --- |
| `trap_state_write.kind` | system handler | exception/interrupt/MRET/SRET 分类 | DPI 间接 |
| `trap_state_write.epc` | system handler | entry PC / `mepc`/`sepc` snapshot | DPI 间接 |
| `trap_state_write.cause` | system handler | execute/commit trap metadata 或 `mcause/scause` | DPI 直接/间接 |
| `trap_state_write.tval` | system handler | execute/commit trap metadata 或 `mtval/stval` | DPI 直接/间接 |
| `trap_cause_in` | flush_model / CSR trap-vector input | execute/commit trap metadata 或 `mcause/scause` 的 cause field | DPI 直接/间接 |
| `trap_is_interrupt_in` | flush_model / CSR trap-vector input | interrupt API 结果或 `mcause/scause[63]` | DPI 直接/间接 |
| `trap_vector` | system handler/flush_model | `mtvec/stvec`、delegation、cause 和 interrupt bit 计算 | DPI 间接 |
| `interrupt_pending` | system handler | `isa_dpi_has_pending_interrupt()` | DPI 直接 |
| `interrupt_cause` | system handler | `mip/mie/mideleg/current_priv` 和模型优先级规则派生 | DPI 间接 |
| `current_priv` | system handler | `isa_dpi_get_priv()` | DPI 直接 |
| `mstatus_tvm/tw/tsr` | system handler | `mstatus` CSR bit | DPI 间接 |

可按 snapshot event 读取的 CSR state 使用固定地址表和
`isa_dpi_get_csr()`：

```text
mstatus, sstatus, mie, mip, sie, sip
mtvec, stvec, mepc, sepc, mcause, scause, mtval, stval
mscratch, sscratch, medeleg, mideleg, satp
fflags, frm, fcsr
mcycle, minstret, cycle, instret
```

`csr_state_addr[i]` 来自固定的 `CsrIndex` 地址表，
`csr_state[i]` 来自 `isa_dpi_get_csr(model_core_id, csr_index)`。CSR snapshot
是架构状态观测，不应被误认为每条 FU completion 都有的 payload。

## 6. BE-LSU interface

### 6.1 节点边界

本节点包含：

- BE -> LSU issue transaction；
- LSU -> BE normal completion；
- LSU -> BE exception completion；
- LSU -> BE read-side bypass。

本节点的 payload 包括 `be_lsu_issue_pld`、`lsu_be_done_pld`、
`lsu_be_exception_pld` 和 `lsu_be_bypass_pld`。

其中 `lsu_be_bypass_valid` 仍作为 read-side completion 的资格信号保留；
`lsu_be_bypass_pld` 不再作为独立结果 payload 与 Level-1 重复比较，
只检查它与同拍 `lsu_be_done_pld` 的 tag/data 一致性。

### 6.2 BE -> LSU issue payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `self_tag` / `tag` | `be_lsu_issue_pld.self_tag` | `rob_idx` 关联键 | 自动对齐 | 请求身份 |
| `req_property` | LSU issue payload | `isa_dpi_get_lsu_issue_metadata().req_property` | 自动比较 | load/store/AMO/LR/SC/fence 分类 |
| `exe_subop` | LSU issue payload | `get_lsu_issue_metadata().exe_subop`；模型 `reference_exe_subop()` | 自动比较 | LSU canonical subop |
| `mem_funct3` | LSU issue payload | `get_lsu_issue_metadata().mem_funct3`；模型 RVC mapping | 自动比较 | 访问宽度/符号 |
| `rd_is_fp` | LSU issue payload | `get_lsu_issue_metadata().rd_is_fp` | 自动比较 | load 结果目标寄存器类型 |
| `rs1_data` | LSU issue payload | `get_lsu_issue_metadata().rs1_data`；模型 `operand_before_target()` | 自动比较 | base operand |
| `rs2_data` / `store_data` | LSU issue payload | `get_lsu_issue_metadata().rs2_data` | 自动比较 | store/AMO 数据 |
| `imm_valid` | LSU issue payload | `get_lsu_issue_metadata().imm_valid` | 自动比较 | 地址立即数有效性 |
| `imm_data` | LSU issue payload | `get_lsu_issue_metadata().imm_data`；模型 RVC/普通 immediate 规则 | 自动比较 | 地址 offset |
| `is_store` | LSU issue payload | `get_lsu_issue_metadata().is_store` | 自动比较 | plain store 分类 |
| `vaddr` | LSU AGU 派生 | `rs1_data + imm_data` 按同一 64-bit wrap 规则重构；可交给 `isa_dpi_translate_pte()` 做 translation 校验 | DPI 间接 | fault 地址和地址转换定位 |

`req_property` 必须按 BE-LSU v4 的 bit layout 归一化：

```text
{is_load, is_store, is_amo, is_lr, is_sc, is_fence, is_fence_i}
```

`exe_subop` 的 RVC 与 32-bit format 必须使用同一编码规则。不能因为
`SUBOP_C_*` 和普通指令功能相同，就直接把两个编码当作相等。

### 6.3 LSU -> BE terminal/bypass payload

| 字段 | DUT 来源 | DPI/ISA_model 来源 | 状态 | 用途 |
| --- | --- | --- | --- | --- |
| `lsu_be_done_pld.tag` | LSU done payload | `rob_idx` 关联键 | 自动对齐 | 请求身份 |
| `lsu_be_done_pld.data` | LSU done payload | `isa_dpi_get_insn_rd_value()`；无 rd 的 store/fence 归零 | 自动比较 | load/LR/SC/AMO 读侧结果 |
| `lsu_be_exception_pld.tag` | LSU exception payload | `rob_idx` 关联键 | 自动对齐 | 出错请求身份 |
| `lsu_be_exception_pld.cause` | LSU exception payload | execute/commit trap metadata | 自动比较 | load/store/AMO fault cause |
| `lsu_be_exception_pld.tval` | LSU exception payload | execute/commit trap metadata；地址 fault 时与 `vaddr` 对齐 | 自动比较 | fault virtual address |
| `lsu_be_bypass_valid` | LSU bypass valid | read-side completion qualification | DUT 协议检查 | 区分 read-side result 与 store-only completion |

### 6.4 LSU control context

LSU bridge 的 store wakeup、flush 和 issue-ready 控制属于调度/握手逻辑，
不是 ISA architectural payload，不进入本 Level 2 observation packet。

`st_br_resolve` 同样是 CompletionScoreboard 的 store ordering 快照。当前
ISA_model 的公开 DPI 没有对应的 per-ROB resolve bit，因此保留在
“进入 FU 之前”的 DUT-only payload；在 BE-LSU 共用比较字段中不重复使用。
