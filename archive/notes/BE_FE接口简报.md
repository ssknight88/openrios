# FE Agent - BE 前端接口驱动与采样
---

## 1. 接口全貌

```text
FE  → BE     FE_BE_Payload[n](302 bit) / fe_valid[1:0]        指令交付
BE  → FE     BE_accepted_slot[1:0]                            回压（本拍收了哪几条）
BE  → FE     BE_redirect_valid / BE_redirect_pc / BE_redirect_kind
             / frontend_icache_invalidate                  控制流重定向
BE  → FE     predictor_update{...}                         分支预测器训练
```

后端**没有**别的信号送 FE。特别注意：**`global_flush_late` 不送 FE**——
FE 不是投机状态的持有者，它要的是"从哪重新取指"，不是"清掉什么"。
接线时最容易犯的错就是把 FE 并进 `global_flush_late` 的扇出名单。

---

## 2. 周期边界与采样口径

本规格**不规定时钟沿约定**（posedge / negedge 由 RTL 与验证环境商定），
但**规定采样口径**——即一个值反映的是拍初状态还是含本拍事件。这一层不可自由选择：

| 信号 | 采样口径 | 后果 |
| --- | --- | --- |
| `accepted_slot` | 本拍组合结果，与 `fe_valid` 同拍 | FE 在同一拍内即可知道哪几条被收下 |
| `redirect_*` | 本拍组合结果 | 与本拍的 dispatch 互斥，见 §6 |

**后端不导出剩余容量。** FE 不需要、也不应当知道后端缓冲还剩几格：
**盲发、读回实收、滑窗**，见 §5。

**后端的接受判据含本拍出队。** 即使上一拍缓冲是满的，只要本拍后端消费掉了 2 条，
同一拍就能回 `accepted_slot = 11`。**这正是不该给 FE 容量提示的原因**——
任何容量值到 FE 手里都已经滞后，照它限流会白丢周期。

---

## 3. FE → BE 驱动规则

| 信号 | 位宽 | 目的 | 驱动规则 |
| --- | --- | --- | --- |
| `fe_valid[1:0]` | 2 | 本拍交付几条指令 | **两位前缀 valid**：只允许 `00` / `10` / `11`，即 `fe_valid[1] ⇒ fe_valid[0]`。`01` 非法——slot0 无效时 slot1 必须也无效 |
| `IB_Payload[0]` | 302 | 第一条指令的完整译码结果 | 与 `fe_valid[0]` 同拍驱动；字段见 §8.1 |
| `IB_Payload[1]` | 302 | 第二条指令 | 与 `fe_valid[1]` 同拍驱动；**必须是程序序上紧接 slot0 的下一条** |

**为什么是前缀而不是任意 mask**：IB 是 FIFO，按 `wptr` 连续写入、entry 不跳洞、不重排。
允许 `01` 就要求 IB 支持空洞，那会让 `valid_count` 不再等于指针差值。

---

## 4. BE → FE 采样规则

| 信号 | 位宽 | 目的 | 采样/处理规则 |
| --- | --- | --- | --- |
| `accepted_slot[1:0]` | 2 | 告诉 FE 本拍收了哪几条 | 合法取值 `00` / `01` / `11`，**`10` 非法**（不可能只收 slot1）。未被接受的候选**由 FE 保留**，下一拍重发。**这是唯一的许可**——没有第二个容量信号 |
| `redirect_valid` | 1 | 本拍是否发生控制流重定向 | 为 1 时**优先于普通 dispatch**，当前候选组整体作废 |
| `redirect_pc` | 64 | 重定向目标 | 与 `redirect_valid` 同拍有效；下一拍从该 PC 重新取指 |
| `redirect_kind` | 3 | 重定向的**性质** | `0` MISPREDICT / `1` EXCEPTION / `2` MRET / `3` INTERRUPT / `4` FENCE_I；`5..7` 保留 |
| `frontend_icache_invalidate` | 1 | 要求 FE 清取指侧缓存状态 | 与 redirect 同拍；为 1 时清 fetch queue、预取、以及 I-cache 中需失效的状态 |
| `predictor_update` | 见 §8.3 | 分支预测器训练 | **执行拍直发，不等提交**；与 redirect 无关，两者可同拍也可各自单独出现 |

**`frontend_icache_invalidate` 由后端产生，FE 不自己译 `redirect_kind`。**
重定向的性质归后端解释，FE 只按线动作。这样将来新增 recovery 类别时 FE 不必跟着改。

**`redirect_kind` 当前只有 `FENCE_I` 会触发缓存失效**，但该字段仍应完整接出——
它同时是调试与性能计数的分类依据。

---

## 5. 正常 dispatch 时序

协议是 **盲发 → 读回实收 → 滑窗**，三步：

**1. 盲发。** FE 本地有几条就摆几条（1 条或 2 条），驱动 `fe_valid` 与 payload。
**不做任何容量判断**——后端没给它容量信息，也不需要。

**2. 后端同拍回实收。** 后端结合自己的余量与**本拍出队情况**，同一周期回 `accepted_slot`。

**3. FE 下一拍按实收滑窗：**

```text
accepted_slot = 11    两条全收    发送指针推进 2，下拍摆全新的 2 条
accepted_slot = 01    只收 slot0  原 slot1 挪到 slot0，slot1 补一条新的，重发
accepted_slot = 00    一条没收    整组保持不变，下拍原样重试
```

**未被接受的候选必须保留**，并在下一拍**压缩到候选序列前缀**重新提交，
payload 与程序顺序保持不变；新指令只能补到队尾，不得插到未接受候选之前。

**这条保持义务是后端设计的前提**：后端不缓存被拒的候选，也不记录"上次拒了谁"。

**为什么不给 FE 容量信息**：后端的接受判据含本拍出队，所以任何容量值送到 FE 手里
**都已经滞后一拍**。上一拍满、本拍出队 2 条时，盲发 2 条能全收；
若 FE 照着"上一拍还剩 0 格"限流，就白丢一个周期。

---

## 6. Redirect 时序

1. 本拍采到 `redirect_valid = 1` 时，**当拍不执行普通 dispatch 的压缩与补充**。
2. 当前所有候选（含未被接受的）**全部作废**，§5 第 4 条的保持义务同时解除。
3. 保存 `redirect_pc`（以及 `frontend_icache_invalidate`），下一拍从该目标重新取指。
4. `frontend_icache_invalidate = 1` 时，在重新取指**之前**完成缓存状态清理。
5. 连续 redirect 时，**最新的目标覆盖尚未生效的旧目标**。

**redirect 拍后端侧同时发生的事**（FE 不必关心，列出以便对时序）：
后端内部的 `global_flush_late` 与 redirect 同拍生成，`accepted_slot` 被强制为 `00`。

---

## 7. Reset 与停止规则

| 条件 | FE 输出规则 | BE 输出规则 |
| --- | --- | --- |
| reset active | `fe_valid` 与全部 `IB_Payload` 驱动为 0 | `accepted_slot = 00`，`redirect_valid = 0` |
| 指令流结束 | 不再产生新的 valid；已发出的候选仍按正常 `accepted_slot` 规则完成 | 无特殊行为，按空闲处理 |
| 外部停止 | 下一驱动沿清零 FE 输出 | 无特殊行为 |

**复位 PC 不由本接口定义**——它属系统边界，由顶层/验证环境给定。

---

## 8. Payload 字段

### 8.1 `IB_Payload`（302 bit，FE → BE）

**总宽度与各字段宽度是冻结的；packed 字段顺序刻意不冻结**，属实现自由。

**注意本接口交付的是"已译码结果"，不是原始指令流。** 译码在前端完成。

| 字段 | 宽度 | 接口用途 |
| --- | --- | --- |
| `pc` | 64 | 本条指令的地址。trap 的 `epc`、`AUIPC` 的基址、BRU 的 fall-through 基址都取它 |
| `inst_bits` | 32 | 本条指令的**原始编码**。非法指令的 `tval` 只能从这里取。压缩指令只用低 16 位、高位置零 |
| `is_compressed` | 1 | 是否 16 位指令。**唯一消费者是 BRU**——链接地址与 fall-through 要按指令长度算 |
| `is_serial` | 1 | 该指令是否要求"派遣时退休窗口为空、且挡死更年轻的派遣"。覆盖四类：CSR 指令、MRET、`FENCE`/`FENCE.I`、22 条原子指令 |
| `is_fp_instruction` | 1 | 是否触碰 FP 寄存器堆。**必须覆盖 FP load/store**（它们落 LSU 组，但仍是 FP 指令） |
| `rs1_idx` / `rs2_idx` / `rs3_idx` | 5×3 | 源寄存器号 |
| `use_rs1` / `use_rs2` / `use_rs3` | 1×3 | 该源是否被使用 |
| `rs1_is_fp` / `rs2_is_fp` / `rs3_is_fp` | 1×3 | 该源取自整数还是 FP 寄存器堆。**`rs3_is_fp` 恒为 1** |
| `rd_idx` | 5 | 目的寄存器号 |
| `use_rd` | 1 | 是否写目的寄存器。x0 的抑制由后端承担，FE 照实填 |
| `rd_is_fp` | 1 | 目的寄存器属哪个寄存器堆 |
| `is_store` | 1 | **专指"走后端 drain 子流程的普通缓冲 store"**。原子指令会写内存但此位为 0 |
| `mem_funct3` | 3 | 访存类型：同时承载宽度、符号扩展、FP 三件事。load 侧七种取值装不进 2 bit |
| `imm_valid` | 1 | 是否有立即数 |
| `imm_data` | 64 | **已译码的立即数**，不是原始编码。CSR 立即数型的 `uimm` 也走这条通道 |
| `pred_taken` | 1 | 分支预测结果：是否 taken |
| `pred_target_pc` | 64 | 分支预测结果：目标 PC |
| `exe_subop` | 24 | 译码后的具体指令 ID，见 §8.2 |
| `full_decode` | 17 | Full Decode 控制字段，见 §8.3 |

### 8.2 `exe_subop`（24 bit）

```text
exe_subop[23:22] = format        01 = 普通 32-bit 编码；10 = RVC
exe_subop[21:15] = opcode_or_op
exe_subop[14:12] = funct3
exe_subop[11:0]  = high_fixed    固定高位段，FP 的 .S/.D 精度由它区分
```

**目的**：后端的分组、FU 选择、以及各 FU 的操作译码**全部只看这一个字段**，
不再解析原始编码。子码全集见 `module_spec_v2/subop/exe_subop_pkg.sv`。

### 8.3 `full_decode`（17 bit）

```text
full_decode[16]    = csr_write_intent
full_decode[15]    = illegal
full_decode[14:12] = rm[2:0]
full_decode[11:0]  = csr_addr[11:0]
```

| 字段 | 接口用途 |
| --- | --- |
| `csr_write_intent` | 该 CSR 指令**是否真的会写 CSR**。`CSRRS`/`CSRRC` 取决于 **`rs1_idx == x0` 这个寄存器号，不是 `rs1_data == 0` 这个值**；立即数型看 `uimm == 0`。**后端推导不出来**（payload 只带 `rs1_data`），必须由前端给 |
| `illegal` | 该指令非法。为 1 时 `exe_subop` 取兜底值，后端固定送异常完成路径、报 cause 2 |
| `rm[2:0]` | FP 舍入模式。`000..100` = RNE/RTZ/RDN/RUP/RMM，`111` = DYN，`101`/`110` 保留 |
| `csr_addr[11:0]` | CSR 指令访问的寄存器地址。立即数型的 `uimm` 占着 `imm` 通道，两者同拍在场，故不能合用 |

### 8.4 `predictor_update`（BE → FE）

| 字段 | 宽度 | 接口用途 |
| --- | --- | --- |
| `valid` | 1 | 本拍有一条分支解析完毕 |
| `branch_pc` | 64 | **哪一条分支**。`redirect_pc` 是目标 PC 不是分支 PC，训练必须靠这个字段 |
| `actual_taken` | 1 | 实际是否 taken |
| `actual_target` | 64 | **taken 时的控制流目标**。not-taken 时无意义，FE 不应采样 |
| `cf_class` | 2 | 控制转移类别，供 FE 选择**更新哪个预测结构**，见下 |

```text
cf_class：
  00  COND_BRANCH      BEQ/BNE/BLT/BGE/BLTU/BGEU、C.BEQZ、C.BNEZ
  01  DIRECT_JUMP      JAL、C.J
  10  INDIRECT_JUMP    JALR、C.JR、C.JALR
  11  保留
```

**`cf_class` 由 BRU 从 `exe_subop` 直接产生**，不需要后端把 `exe_subop` 送回 FE。

**为什么这两位省不掉**：`actual_taken` 对无条件跳转**恒为 1**，
把它喂进方向预测器是污染而不是训练。FE 必须知道该更新哪个结构：

```text
COND_BRANCH      更新方向预测；taken 时另更新目标预测
DIRECT_JUMP      只更新目标预测
INDIRECT_JUMP    更新间接目标结构
```

FE 光靠 `branch_pc` 分不出类别——除非回去重新取指译码，那比传 2 bit 贵得多。

**`cf_class` 明确不含 call / return 分类。** RISC-V 里那要看 `rd` 或 `rs1` 是不是
`x1`/`x5`，而**后端的发射 payload 里没有 `rd_idx` / `rs1_idx`**（源已解析成数据，
目的寄存器信息在分配拍就进了后端），BRU 算不出来。
**因此本后端也不提供 RAS 所需的信息**——将来要做 RAS，
必须在派遣侧预先算好一个 `ras_action` 送下来，或把两个寄存器号补进发射 payload；
**不能让 FE 从 `branch_pc` 重新猜**。

**不需要送分支长度**：BTB 更新要的长度 FE 自己就知道（`is_compressed` 是它产生的）。
后端内部算 `mispredict_target_pc` 时确实要用长度，但那是后端自己的事。

**目的与时机**：这条通路的存在理由是——没有它，`pred_taken` / `pred_target_pc`
就是只读不写的死字段，预测器**既学不到"哪条分支错了"，预测对时也收不到确认**。

**执行拍直发、不等提交。** 这意味着训练是**投机**的：被 flush 掉的分支也会训练进去。
这是刻意的取舍——本后端退休窗口只有 16 项，执行到退休最多隔十几条指令，
投机污染窗口极小；而等提交要求后端逐格新增存储，代价不对称。

**本接口不提供提交侧（非投机）的训练通路。**

**`actual_target` 与 `redirect_pc` 是两回事，不可混用**——这一条最容易搞错：

```text
actual_target      = 该分支 taken 时的控制流目标        用途：训练目标预测
mispredict_target  = actual_taken ? actual_target
                                  : branch_pc + 指令长度   （后端内部量）
redirect_pc        = mispredict_target                  用途：重新取指
```

一条"预测 taken、实际 not-taken"的分支，`redirect_pc` 是 **fall-through**，
而 `actual_target` 是那个**没走成的**目标。FE 若拿 `redirect_pc` 去训练目标预测，
学到的就是错的。

---

## 9. 上游不变式

后端**把下面三条当前提用，不做检查、不做兜底**。前端违反即是错，
而且是那种下游看不出来、只表现为偶发错误结果的错。

```text
① use_rs3 ⇒ rs3_is_fp
   第三源只可能是 FP。后端据此只为 rs1/rs2 开整数寄存器读口

② 触碰 FP 寄存器堆 ⇒ is_fp_instruction 为真（含 FP load/store）
   后端据此做"同拍双 FP 指令阻塞"，而那一条又是 FP 寄存器堆单写口的依据

③ fe_valid 是两位有序前缀，accepted_slot 未接受的候选须保持有序后缀
   后端不缓存被拒候选，也不记录上次拒了谁
```
