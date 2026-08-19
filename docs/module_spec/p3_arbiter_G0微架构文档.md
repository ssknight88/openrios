# p3_arbiter_G0 · G0 组内仲裁与 bypass 广播 · 3 requester

全库只有 G0、G1 两个组内仲裁器（G1 见 [[p3_arbiter_G1微架构文档.md]]）。
**G2/G3 无仲裁器**：FPU / LSU 单 requester，completion 直连 lane 2/3。

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `winner_grant[k]` / `loser_hold[k]` / `Result_valid` / `bypass_valid`(output)

**组内静态优先级**：

```text
ALU0/BRU (requester 0)  >  CSR (1)  >  DIV (2)
```

`ALU0/BRU` **共用一个 requester 接口**

- **winner_select**：

```text
winner_valid    = k∈{0,1,2} (request_valid[k])
winner_idx      = winner_valid ? 最高优先级的 valid requester : 0
winner_grant[k] = winner_valid ∧ (winner_idx == k)
```

- `winner_valid = 0` 时 `winner` 及其全部结果字段为无效占位（实现可置 0），
  只有为 1 时它们才进入接口语义
- **静态优先级无 anti-starvation**：loser 堵住按序退休 → 退休窗口满（`occupancy == 16`）→
  高优先级 FU 无新有效指令 → loser 必然获胜。

- **bypass_publish** = `winner_valid` ∧ `!exception_flag`

**`!exception_flag` 这道门不可省**（`bypass_valid` 是四条 lane 同一份契约，
G2/G3 直连也照此驱动）：出错指令的 `result_data` 是垃圾，但它的 `tag` 是真的——
而出错的 load / LR / SC / AMO 都是 `use_rd = 1`，**确实有 ISQ entry 在等这个 tag**，
不门掉就会捕获垃圾并置 `ready`。`exception_flag` 本来就在 request 里，不需要新增边。

**不加 `rd_write_enable` 限定是刻意的**：`use_rd = 0` 的指令（store、ILLEGAL、SYS、
FENCE）从未在任何 tag_mapping 留下映射 ⇒ 没有任何 ISQ entry 能持有它的 `wait_tag`
⇒ 广播**无消费者、无害**。`rd = x0` 同理（`INT_tag_mapping` 第 0 格硬连 `{0,0}`，
解析恒走 ARF，永不产生 `WAIT_PRODUCER`）。加这道门要给本模块开一个按 `tag_out`
索引 SCB alloc 批的只读口 ×4 lane，代价不小而收益只是省几次无消费者的比较。

**同样不加 `!global_flush_late`**：本模块无状态、**不接收 flush**（集成层明写
`p3_arbiter` 不在 `global_flush_late` 的扇出名单里），flush 拍的门控由各消费者自己挂
——ISQ 的 flush 优先级最高、dispatch 的 `accept` 被同一根线屏蔽。
两条理由链见 `../../walkthrough.md` §1.24。
- **loser_hold[k]** = `request_valid[k]` ∧ `!winner_grant[k]`
    - `loser_hold` 是组合电平反馈，不是单拍脉冲；只要请求仍未获胜就可连续多个周期为 1
    - loser 必须**冻结整条 completion request**，下拍重试；FU（CSR / DIV）保持 busy；FU 需由 output hold 反压影响输入接受能力，**不能覆盖或丢失 result**

**FU 自身的行为契约不在本模块描述**：flush 拍作废在飞指令与被 hold 的 completion request、
此后不得对旧 tag 再发 `Result_valid`、completion request 相对 issue 至少寄存一拍——
这三条都是 FU 的内部时序，归 **FU 微架构文档**。
本模块只做组内仲裁与转发，不规定任何 FU 的内部行为；
G2/G3 直连 lane 2/3、根本不经过仲裁器，其行为更不该由本文档管辖。

#### 2. `tag_out` / `bypass_tag` / `bypass_data` / writeback 其余字段(output)

```text
tag_out      = winner_valid ? request[winner_idx].tag         : 0
Result_valid = winner_valid
其余 writeback 字段 = winner_valid ? request[winner_idx] 的对应字段 : 0

bypass_valid = winner_valid ∧ !request[winner_idx].exception_flag
bypass_tag   = winner_valid ? request[winner_idx].tag         : 0
bypass_data  = winner_valid ? request[winner_idx].result_data : 0
```

**completion 分两层**——第一层四条 lane 共用，第二层只有 lane 0 有：

```text
completion_common   Result_valid、tag_out、result_data、
                    exception_flag、exception_cause、exception_tval、
                    mispredict_flag、mispredict_target_pc、is_mret、fpu_fflags

csr_sideband        is_csr、csr_write_enable、csr_addr、csr_wdata
```

`completion_common` 是四条 lane 的公共契约：G2/G3 虽然直连 lane 2/3、不经任何仲裁器，
也必须按它驱动，无法产生的事件字段恒 0。本模块（lane 0）两层都驱动，但 `fpu_fflags` 恒 0——它是 FP 的 IEEE 异常标志，
只有 G2（FPU）驱动非零；`fpu_fflags` **不属"事件字段"**（不是判定链谓词），
与 exception/mispredict/is_mret 分开。
`csr_sideband` **只在 lane 0 存在**——CSR 固定路由 G0，其余 lane 不携带这组字段、
也不必伪造。它是 CSR 写意图的专用旁带，与退休侧的 `completion_common` 走不同消费者。

- **`bypass_*` 名义上叫 CDB，物理上是组合广播**——不是寄存器化的公共数据总线，也不是 CAM。
  消费者侧的 tag 比较是分布式的等值比较器，不在本模块
- **lane 与 group 一一对应**，全库共 4 lane，编号 `b = g`；lane 2/3 由 FPU / LSU
  直接驱动（无仲裁器），四处消费者不重排、不压缩
- loser 不入 winner data path；loser result 留在 FU-local hold state

**总线名与信号名**——`p3_bypass_CDB` 是**总线名**，只用于描述这组线整体；
公式与接口一律用信号名 `bypass_valid[g]` / `bypass_tag[g]` / `bypass_data[g]`。

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**
### ⑥ 接口

**in-event** `→ p3_arbiter_G0`

- completion request（Transaction，多对一 mux；ready = `winner_grant[k]`，loser 须 hold 重试）
    - broadcast；`request[k]` 的 `tag`(4)、`result_data`(64)、`mispredict_flag`(1)、
      `mispredict_target_pc`(64)、`exception_flag`(1)、`exception_cause`(63)、`exception_tval`(64)、
      `is_csr`(1)、`csr_write_enable`(1)、`csr_addr`(12)、`csr_wdata`(64)、`is_mret`(1)
    - 触发；`request_valid[k]`(1，k∈{0,1,2}) —— 这个 requester 本拍要不要竞争

**out-event** `p3_arbiter_G0 →`

- writeback；两层一并驱动（字段分层见 ④）
    - `completion_common`；`Result_valid`(1)、`tag_out`(4)、`result_data`(64)、
      `exception_flag`(1)、`exception_cause`(63)、`exception_tval`(64)、`mispredict_flag`(1)、
      `mispredict_target_pc`(64)、`is_mret`(1)、`fpu_fflags`(5)
      —— `exception_cause` 是**不带中断标志位的 cause 编号**，故 63 位；
      那一位只在写入架构 `mcause` 时由中断类型置起，不在本通路上传输。
      `fpu_fflags` 本组恒 0（非 FPU）
    - `csr_sideband`；`is_csr`(1)、`csr_write_enable`(1)、`csr_addr`(12)、`csr_wdata`(64)
      —— lane 0 专有
- exec_done；`tag_out`(4)、`Result_valid`(1)
- `bypass_publish`；`bypass_valid`(1)、`bypass_tag`(4)、`bypass_data`(64)
- `winner_select`；`winner_grant[k]`(1)
- 组合读(out)；`loser_hold[k]`(1)

**Static Info**

无。
