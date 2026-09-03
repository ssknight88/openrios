# IB · 8 slot FIFO（指令缓冲）

## ① per-entry state

`IDLE / RESIDENT`

## ② state transition & condition（event 名）

- IDLE → RESIDENT：enqueue
- RESIDENT → IDLE：dequeue
- ANY → IDLE：flush

## ③ condition 细化

- **enqueue**：**采样约定——只使用拍初空位**，不使用当拍 dequeue 释放的 entry

```text
free_slot          = 8 - valid_count
accepted_slot[0] = fe_valid[0] ∧ (free_slot >= 1) ∧ !global_flush_late
accepted_slot[1] = fe_valid[1] ∧ accepted_slot[0] ∧ (free_slot >= 2) ∧ !global_flush_late
enq_count        = accepted_slot[0] + accepted_slot[1]      // wptr += enq_count
```

- `fe_valid` 须满足 `fe_valid[1] ⇒ fe_valid[0]`（两位前缀 valid）
- `accepted_slot` 合法取值 `00 / 01 / 11`——**`10` 非法**
- full 时即使当拍 dequeue，也要到下一拍才接收——这是"只用拍初空位"的直接后果

非 flush 拍，FE 必须保留未接受候选的有序后缀，并在下一拍将其
压缩到候选序列前缀重新提交，payload 与程序顺序保持不变。
例如 `fe_valid=11`、`accepted_slot=01` 时，原 slot1 必须在下一拍
作为新的 slot0 重新提交。

flush 拍 `accepted_slot=00`；redirect 取消上述保持义务，旧路径候选
丢弃，FE 从 `redirect_pc` 重新取指。

- **dequeue[s]** = `inst_valid[s]` ∧ `ib_dequeue[s]`

```text
inst_valid[0] = (valid_count >= 1)
inst_valid[1] = (valid_count >= 2)        // inst_valid[1] ⇒ inst_valid[0]
deq_count     = dequeue[0] + dequeue[1]     // rptr += deq_count
```

- `valid_count = (wptr - rptr) mod 16`，两个指针都是拍初寄存值，
  故其差值就是**拍初**已占用条数；次态 `valid_count = valid_count + enq_count - deq_count`
- `ib_dequeue[1] ⇒ ib_dequeue[0]`，故 dequeue 集合只能是 `00 / 01 / 11`，连续队头不跳过 slot0
- 队头两个 slot 对应 `rptr` 与 `rptr + 1` 的连续 entry

- **flush** = `global_flush_late`：优先级最高，`accepted_slot = 00`、`ib_dequeue = 00`，
  指针复位（含 loopbit）且次态 `valid_count = 0`
- 非 flush 拍按 enqueue / dequeue 的净变化更新 `valid_count`

## ④ data path

端点为**输入端口 / entry / 输出端口**三者。

### 1. `entry.IB_Payload`（in）

```text
enqueue 输入端口 → entry[wptr + n]    整条 IB_Payload
entry            → 队头输出端口        整条 IB_Payload（队头 2 slot 持续输出）
```

- 队头输出是**持续组合候选值**，不由 `dequeue` 选通；`dequeue` 只推进 `rptr`

### 2. `inst_valid[1:0]` / `accepted_slot[1:0]` / `free_slot`(output)

```text
inst_valid[1:0]    ← ③
accepted_slot[1:0] ← ③ 的接受判定
free_slot             ← valid_count 的投影
```

## ⑤ data structure（schema + 字段三角色）

- **state**：`IDLE / RESIDENT`，压缩进 `wptr` / `rptr`
  - 压缩进两个 4-bit 指针 `wptr` / `rptr` = `{loopbit, index[2:0]}`：
  低 3 bit 是 8 个 entry 的地址，高 1 bit 是环绕标志。per-entry valid 是区间**解码投影**
  - 逻辑有效区间 `[rptr, wptr)`；entry 不跳洞、不重排
- **header**：**无**——本模块不对 entry 内容做任何判断
- **payload**：整条 `IB_Payload`，`enqueue` 写入、原样进原样出：

```text
pc、route_class、FU_Group、is_serial、is_fp_instruction、
rs1/2/3_idx、use_rs1/2/3、rs1/2/3_is_fp、
rd_idx、use_rd、rd_is_fp、is_store、store_size、
imm_valid、imm_data、pred_taken、pred_target_pc、
子码 / Full Decode 控制信号（位宽与编码待定）
```

- `route_class` 是**逻辑候选组类别**：ALU 为 `{G0,G1}` 动态二选一，
  `BRU（含 MRET）/CSR/DIV/MUL/FPU/LSU` 分别固定到 `G0/G0/G0/G1/G2/G3`；
  下游把它解析为实际的 group 编号。**MRET 不是独立类**——编码在 ALU/BRU 子码空间、
  同 requester 同 FU_Group，`is_serial` 由译码独立标注
- `FU_Group` 是**组内 FU 索引**（ALU 为 0，CSR/DIV/MUL 分别为 1/2/1，
  BRU（含 MRET）/FPU/LSU 为 0），**不是全局组编号**
- `is_serial` 当前覆盖 **CSR 指令（CSRRW/S/C 及立即数型）与 MRET**
- **待补**：`ECALL` / `EBREAK` / `FENCE` / `WFI` / `FENCE.I` 暂不支持，
  `route_class` 无其归属。补入时归 G0（与 MRET 同 requester 的透传 / NOP 子码），
  `is_serial` 口径同步扩展；FENCE.I 需"提交后重取"，可实现为无条件
  `mispredict_flag = 1`、`target = pc + 4`（压缩指令 `pc + 2`），复用 MISPREDICT flush。
  **缓行期间的兜底**：译码遇到这五条，一律按非法指令 trap。
  系统指令退休效应的宿主见 [[system_instruction_handler微架构文档.md]] ① 的挂点清单

## ⑥ 接口

**in-event** `→ IB`

- enqueue（Transaction，**2 写口**；ready 由本模块回送的
  `accepted_slot[n]` 承担，见 ③）
  - move；`IB_Payload[n]`(整条，n∈{0,1}) —— 存进 `entry[wptr + n]`
    - 触发；`fe_valid[n]`(1，n∈{0,1}) —— 本拍 FE 给几条（两位前缀），决定写几格

- ib_dequeue（Transaction，两位前缀单向选通，per slot；
  ready 已被对端吸收，本模块不重组第二份握手）
  - 触发；`ib_dequeue[s]`(1，s∈{0,1}) —— per slot 使能，推进 `rptr`，无载荷

- flush（announce）
  - 触发；`global_flush_late`(1) —— 单线脉冲，指针复位（含 loopbit），无载荷

**out-event** `IB →`

- 组合读(out)；队头 2 slot 的整条 `IB_Payload`（字段清单见 ⑤）
- 组合读(out)；`inst_valid[1:0]`(2)
- 组合读(out)；`accepted_slot[1:0]`(2) —— 回压回送，见 ③ 的契约

**Static Info：**

- `free_slot`(4) —— 8-`valid_count`，只反映**拍初容量**。③
