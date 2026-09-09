# LEVEL-2 观测点

本页分两部分：一部分是你确认过、`ISA_model` 可读的核心白名单；另一部分是需要保留的 `CSR`、`FE-BE`、`BE-LSU` 接口节点。前者用于裁剪杂项 level-2 信号，后者不按这份白名单删除。

## 1. ISA_model 白名单

### 1.1 指令像

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `inst_bits` | 32 bit | 原始指令编码 |
| `is_compressed` | 1 bit | 是否为 16-bit compressed instruction |

### 1.2 寄存器像

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `rd_idx` | `REG_ADDR_W` | 目的寄存器编号 |
| `rd_is_fp` | 1 bit | 目的寄存器是否为 FPR |
| `rs1_idx` | `REG_ADDR_W` | rs1 编号 |
| `rs2_idx` | `REG_ADDR_W` | rs2 编号 |
| `rs3_idx` | `REG_ADDR_W` | rs3 编号 |
| `rs1_is_fp` | 1 bit | rs1 是否为 FPR 源 |
| `rs2_is_fp` | 1 bit | rs2 是否为 FPR 源 |
| `rs3_is_fp` | 1 bit | rs3 是否为 FPR 源 |

### 1.3 执行/分类像

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `imm_data` | 64 bit signed | 已符号扩展的立即数 |
| `exe_subop` | 24 bit | 执行子操作编码 |
| `is_store` | 1 bit | 是否为 store 类指令 |
| `is_atomic` | 1 bit | 是否为 atomic 类指令 |
| `is_serial` | 1 bit | 是否为 serial/system 类指令 |
| `is_fp_instruction` | 1 bit | 是否为 FP 指令 |
| `effective_rm` | `rm_e` | 实际采用的 rounding mode |

### 1.4 模型上下文

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `csr_rdata` | 64 bit | 读到的 CSR 旧值 |
| `current_priv` | `byte unsigned` | 当前特权级 |

## 2. CSR 节点

| 信号/信息 | 位宽/形态 | 来源 | 用途 | ISA_model 可取得性 | 当前核心必抓 |
| --- | --- | --- | --- | --- | --- |
| `csr_state_addr[i]` | 12 bit | CSR snapshot 表 | 第 `i` 个 CSR 表项的 CSR 地址 | 间接取得；由固定 CSR list / `CsrIndex` 地址表生成 | 待定 |
| `csr_state[i]` | 64 bit | CSR 文件 / snapshot 绑定 | 第 `i` 个 CSR 表项的值，与 reference CSR 状态比较 | 直接取得；`isa_dpi_get_csr(model_core_id, csr_index)` | 待定 |
| `csr_event_valid` | 1 bit | CSR 指令执行/提交事件 | 辅助定位 CSR 指令行为；不能替代完整 snapshot | 间接取得；可由 instruction decode + commit 事件重构，精确 pulse 仍来自 RTL | 否 |
| `csr_event_addr` | `CSR_ADDR_W` | CSR 指令事件 | 记录被访问的 CSR 编号 | 间接取得；CSR 指令编码 `inst_bits[31:20]` / `inst_op.csr()` | 否 |
| `csr_event_wdata` | 64 bit | CSR 指令事件 | 记录 CSR 写入值 | 间接但不完整；模型内部有 CSR write data，当前 DPI 未导出 per-ROB wdata | 否 |
| `csr_event_rdata` | 64 bit | CSR 指令事件 | 记录 CSR 读出值 | 间接取得；可在正确 issue 边界用 `isa_dpi_get_csr(csr_addr)` 取旧值，无 per-ROB rdata getter | 否 |
| `req_is_csr` / `is_csr` / `sb_is_csr` | 1 bit | CSR FU / G0 CSR sideband | 标记本 completion 是否为 CSR 指令 | 间接取得；由 `inst_bits` decode / `isa_dpi_decode_mnemonic` 判定 | 是 |
| `req_csr_write_enable` / `csr_write_enable` / `sb_csr_write_enable` | 1 bit | CSR FU / G0 CSR sideband | 是否产生架构 CSR 写 | 间接取得；按 Zicsr opcode 与 `rs1/zimm!=0` 规则推导，无独立 getter | 是 |
| `req_csr_addr` / `csr_addr` / `sb_csr_addr` | `CSR_ADDR_W` | CSR FU / G0 CSR sideband / CSR FU software read port | CSR 写地址或读地址 | 间接取得；CSR 指令编码 `inst_bits[31:20]` / `inst_op.csr()` | 是 |
| `req_csr_wdata` / `csr_wdata` / `sb_csr_wdata` | 64 bit | CSR FU / G0 CSR sideband | CSR 写入值 | 间接但不完整；立即数字段可推导，寄存器形式需要 rs1 值，当前 DPI 未导出 CSR write payload | 是 |
| `csr_rdata` | 64 bit | `system_instruction_handler` CSR 读口 | issue/执行侧读到的 CSR 旧值 | 间接取得；在 CSR issue 前用 `isa_dpi_get_csr(csr_addr)` 对齐，无 per-ROB read payload | 是 |
| `current_priv` | `PRIV_W` / `byte unsigned` | `system_instruction_handler` | 当前特权级；CSR legality、trap 入口和 reference 对齐上下文 | 直接取得；`isa_dpi_get_priv()` | 是 |
| `frm` | `rm_e` | `system_instruction_handler` / `frm` CSR | FP rounding mode 上下文 | 直接取得；读 `frm` CSR，或由 `fcsr[7:5]` 取得 | 是 |
| `fs_enabled` | 1 bit | `mstatus.FS` 派生 | FP/CSR 合法性上下文 | 间接取得；由 `mstatus[14:13] != 0` 推导 | 是 |
| `mstatus` / `sstatus` | 64 bit view | CSR snapshot | 特权、interrupt enable、FS、SUM/MXR/TVM/TW/TSR 等状态比较 | 直接取得；`isa_dpi_get_csr()` 读对应 CSR/view | 待定 |
| `mstatus_tvm` / `mstatus_tw` / `mstatus_tsr` | 1 bit each | `mstatus` 派生输出 | CSR/system 合法性控制 | 间接取得；由 `mstatus[20]`、`mstatus[21]`、`mstatus[22]` 推导 | 是 |
| `mie` / `mip` / `sie` / `sip` | 64 bit view | CSR snapshot / interrupt level | interrupt enable/pending 状态比较和诊断 | 直接取得；`sie/sip` 由模型 CSR read 返回视图语义 | 待定 |
| `mtvec` / `stvec` | 64 bit | CSR snapshot | trap handler 入口基址/模式 | 直接取得；`isa_dpi_get_csr()` | 待定 |
| `mepc` / `sepc` | 64 bit | CSR snapshot / `trap_state_write.epc` 落地 | trap EPC / return PC 比较 | 直接取得；trap apply 后读 CSR snapshot | 待定 |
| `mcause` / `scause` | 64 bit | CSR snapshot / `trap_state_write.cause` 落地 | trap cause 比较和异常诊断 | 直接取得；CSR snapshot，per-ROB trap cause 也可由 metadata API 取得 | 待定 |
| `mtval` / `stval` / `tval` | 64 bit | CSR snapshot / `trap_state_write.tval` | trap 附加值；地址类异常时通常为 fault virtual address | 直接取得；`mtval/stval` 读 CSR，模型 trap 的 `tval` 可由 metadata API 取得 | 待定 |
| `vaddr` | 64 bit | fetch/LSU/translation exception producer；也可能经 `*tval` 承载 | 记录导致异常的 virtual address，便于和 `tval` 对齐 | 间接取得；LSU 可由 `rs1_data + imm_data` 推导，fetch/translation fault 需结合 PC、`tval` 或 RTL fault 输入 | 待定 |
| `trap_state_write.valid` | 1 bit | `flush_model` -> `system_instruction_handler` | 是否有 trap/return 状态写入 | 间接取得；exception/interrupt 可由 trap metadata/pending interrupt 推导，精确 RTL pulse 不可取 | 能取则取 |
| `trap_state_write.kind` | `RECOVERY_KIND_W` | `flush_model` | 区分 exception/interrupt/MRET/SRET 等 | 间接但不完整；exception/interrupt/MRET/SRET 可从 trap type 或 mnemonic 推导，RTL recovery enum 不可直接取 | 能取则取 |
| `trap_state_write.epc` | 64 bit | `flush_model` | 写入 `mepc/sepc` 的 EPC | 间接取得；trap 前用 instruction PC，trap apply 后读 `mepc/sepc` | 能取则取 |
| `trap_state_write.cause` | `EXCP_CAUSE_W` | `flush_model` | 写入 `mcause/scause` 的 cause，未包含 interrupt bit | 直接取得语义值；trap metadata API 或 trap apply 后读 `mcause/scause` | 能取则取 |
| `trap_state_write.tval` | 64 bit | `flush_model` | 写入 `mtval/stval` 的 tval | 直接取得语义值；模型 trap metadata API 或 trap apply 后读 `mtval/stval`，外部 fault 的 tval 仍由 RTL 注入 | 能取则取 |
| `trap_cause_in` | `EXCP_CAUSE_W` | `flush_model` / CSR trap vector 输入 | 计算 trap vector 和日志定位 | 间接取得；由 trap metadata 或 `mcause/scause` cause field 对齐 | 能取则取 |
| `trap_is_interrupt_in` | 1 bit | `flush_model` / CSR trap vector 输入 | 区分 interrupt/vector 计算 | 间接取得；由 trap type 高位或 `mcause/scause[63]` 推导 | 能取则取 |
| `trap_vector` | 64 bit | `system_instruction_handler` | trap redirect target 诊断 | 间接取得；由 `mtvec/stvec`、cause 和 interrupt/vector 规则计算，或 interrupt 路径读 `take_interrupt` redirect | 能取则取 |
| `interrupt_pending` | 1 bit | `system_instruction_handler` | 是否存在可响应 interrupt | 直接取得；`isa_dpi_check_interrupt()` / `isa_dpi_has_pending_interrupt()` | 待定 |
| `interrupt_cause` | `EXCP_CAUSE_W` | `system_instruction_handler` | pending interrupt cause | 间接但不完整；可由 `mip/mie/mideleg/current_priv` 近似推导，当前 DPI 无 pending cause getter | 待定 |
| `fflags` / `frm` / `fcsr` | `FFLAGS_W` / `rm_e` / 64 bit view | CSR snapshot | FP exception flags、rounding mode 和 FCSR 状态比较 | 直接取得；`isa_dpi_get_csr()` 读 `fflags/frm/fcsr` | 待定 |
| `mscratch` / `sscratch` | 64 bit | CSR snapshot | trap handler scratch CSR 状态 | 直接取得；`isa_dpi_get_csr()` | 待定 |
| `satp` | 64 bit | CSR snapshot | 地址转换配置状态；影响 vaddr translation 诊断 | 直接取得；`isa_dpi_get_csr()`，虚拟化场景需另补虚拟态上下文 | 待定 |
| `mcycle` / `minstret` / `cycle` / `instret` | 64 bit | CSR snapshot / perf counter alias | 性能计数 CSR 状态 | 直接取得；`isa_dpi_get_csr()`，但采样边界敏感 | 否 |

### 2.1 ISA_model 定位确认

本节保留的是 ISA_model 内部已有或可以计算、但当前可调用的 C API / ORBE DPI
尚未完整导出的信息。主要包括 CSR read/write event payload 和 pending
interrupt cause；这些信息存在于模型执行路径或可由模型状态计算，后续可通过
新增 ABI/DPI getter 导出。

CSR 指令本体可以被 ISA model 定位：`src/isa_riscv/RvDefines.hpp` 中有
`CSRRW`、`CSRRS`、`CSRRC`、`CSRRWI`、`CSRRSI`、`CSRRCI` 的
`Mnemonics` 枚举；`src/isa_riscv/instructions/I/zicsr.hpp` 的六个
`InsnImpl` 都通过 `inst_op.csr()` 取得 12-bit CSR 地址，并通过
`input.csr.readCSR(...)` / `output.csr.writeCSR(...)` 记录 CSR 读写请求。

表中的 CSR 架构状态值可以由
`isa_dpi_get_csr(model_core_id, csr_index)` 按 `CsrIndex` 地址读取；
`CsrModule` 已建模这些地址：`mstatus/sstatus`、`mie/mip/sie/sip`、
`mtvec/stvec`、`mepc/sepc`、`mcause/scause`、`mtval/stval`、`satp`、
`fflags/frm/fcsr`、`mscratch/sscratch`、`mcycle/minstret/cycle/instret`。
`current_priv` 可由 `isa_dpi_get_priv()` 读取；`csr_state_addr[i]` 可由
固定 CSR list / `CsrIndex` 地址表生成。

表中的 trap 状态可以由 ISA model 定位到对应 ROB entry：
`isa_dpi_get_decode_metadata()`、`isa_dpi_get_execute_metadata()` 和
`isa_dpi_get_commit_auto_trap_info()` 均返回 `trap_valid` / `trap_cause` /
`trap_tval`；trap 落地后也可以再从 `mepc/sepc`、`mcause/scause`、
`mtval/stval` 这些 CSR snapshot 中读取。第 81-83 行的 trap vector
输入/结果可由 `trap_cause`、interrupt bit 和 `mtvec/stvec` 等 CSR 状态
重构，但当前 ORBE DPI 没有单独的 `trap_vector` getter。第 84-85 行的
interrupt pending 可由 `isa_dpi_check_interrupt()` +
`isa_dpi_has_pending_interrupt()` 判断，`isa_dpi_take_interrupt()` 可返回
interrupt redirect PC；当前 DPI 没有单独导出 `interrupt_cause`，需要从
`mip/mie/mideleg` 等 CSR 状态或后续新增 getter 交叉定位。

第 75 行的 `vaddr` 不是 CSR 本体。ISA model 可以通过
`isa_dpi_translate_pte(vaddr, priv, mem_op_type, length, ...)` 定位地址转换
异常，并返回 `trap_tval`；fetch/LSU 实际产生的 `vaddr` 仍应从 FE/LSU
observation 侧记录，再与 ISA model 的 `trap_tval` 对齐。

表中的 `csr_event_*`、`req_*` / `sb_*` 在 ISA model 执行/解码路径中有对应
语义，但当前 ORBE DPI
没有直接导出 per-ROB 的 `is_csr`、`csr_addr`、`csr_wdata`、`csr_rdata`
专用 getter；若后续要求这些 event 字段由 ISA model 侧直接比对，需要新增
对应 ABI/DPI。现阶段这些字段应由 RTL probe 抓取，ISA model 用
`decode_mnemonic`、CSR snapshot 和 trap metadata 做交叉定位。

## 3. FE-BE 接口节点

### 3.1 FE -> BE raw instruction payload

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `pc` | 64 bit | 原始指令地址 |
| `inst_bits` | 32 bit | 原始指令编码 |
| `is_compressed` | 1 bit | 是否为 compressed instruction |
| `pred_taken` | 1 bit | 分支预测方向 |
| `pred_target_pc` | 64 bit | 分支预测目标 PC |
| `fetch_excp_vld` | 1 bit | 取指异常标记 |
| `exception_cause` | 5 bit | 取指异常 cause |
| `exception_tval` | 64 bit | 取指异常 tval |

### 3.2 BE -> FE redirect payload

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `redirect_pc` | 64 bit | 下一次取指目标 PC |
| `interrupt_valid` | 1 bit | redirect 是否由 interrupt 引起 |
| `trap_valid` | 1 bit | redirect 是否由同步 trap 引起 |

## 4. BE-LSU 接口节点

### 4.1 BE -> LSU issue payload

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `self_tag` / `tag` | `TAG_W` | LSU 请求 tag |
| `req_property` | packed onehot class | load/store/amo/lr/sc/fence 分类 |
| `exe_subop` | `EXE_SUBOP_W` | 访存 / 原子 / fence 子操作编码 |
| `mem_funct3` | 3 bit | 访问宽度和符号属性 |
| `rd_is_fp` | 1 bit | load 结果是否写入 FPR |
| `rs1_data` | 64 bit | base operand |
| `rs2_data` / `store_data` | 64 bit | store / AMO 写数据 |
| `imm_valid` | 1 bit | immediate 是否有效 |
| `imm_data` | 64 bit signed | 已符号扩展的 offset |
| `is_store` | 1 bit | plain store 兼容分类位 |
| `st_br_resolve` | 1 bit | plain store 授权快照 |

### 4.2 LSU -> BE terminal / bypass payload

| 信号 | 位宽/形态 | 说明 |
| --- | --- | --- |
| `lsu_be_done_pld.tag` | `TAG_W` | 对应请求 tag |
| `lsu_be_done_pld.data` | 64 bit | read-side 返回数据 |
| `lsu_be_exception_pld.tag` | `TAG_W` | 出错请求 tag |
| `lsu_be_exception_pld.cause` | 5 bit | 同步异常号 |
| `lsu_be_exception_pld.tval` | 64 bit | 出错虚地址 / tval |
| `lsu_be_bypass_pld.tag` | `TAG_W` | read-side 结果 tag |
| `lsu_be_bypass_pld.data` | 64 bit | read-side bypass 数据 |

## 5. 约束

1. 本页的裁剪原则只约束除 CSR / FE-BE / BE-LSU 之外的 level-2 信号。
2. 白名单字段以你确认的 `ISA_model` 可读项为准。
3. 后续若要新增非接口节点字段，必须先确认 `ISA_model` 侧可读，再加入本页白名单。
