# p3_arbiter_G1 · G1 组内仲裁与 bypass 广播 · 2 requester

全库只有 G0、G1 两个组内仲裁器（G0 见 [[p3_arbiter_G0微架构文档.md]]）。
**G2/G3 无仲裁器**：FPU / LSU 单 requester，completion 直连 lane 2/3，连线归集成层登记。


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
ALU1 (requester 0)  >  MUL (1)
```

- **winner_select**：

```text
winner_valid    = OR over k∈{0,1} (request_valid[k])
winner_idx      = winner_valid ? 最高优先级的 valid requester : 0
winner_grant[k] = winner_valid ∧ (winner_idx == k)
```

- `winner_valid = 0` 时 `winner` 及其全部结果字段为无效占位（实现可置 0），
  只有为 1 时它们才进入接口语义
- **静态优先级无 anti-starvation**：loser 堵住按序退休 → 退休窗口满（`occupancy == 16`）→
  高优先级 FU 无新有效指令 → loser 必然获胜。**此保证仅在按序退休下成立**

- **bypass_publish** = `winner_valid` ∧ `!exception_flag`
    - **`!exception_flag` 不可省**：出错指令的 `result_data` 是垃圾但 `tag` 是真的，
      若它 `use_rd = 1` 就确实有 ISQ entry 在等 ⇒ 会捕获垃圾并置 `ready`。
      本组（ALU1/MUL）产生不了异常、该位恒 0，但**契约是四条 lane 同一份**，
      写在这里是为了让 G2/G3 直连时照同一条驱动。`exception_flag` 在 request 里，无新增边
- **loser_hold[k]** = `request_valid[k]` ∧ `!winner_grant[k]`
    - `loser_hold` 是组合电平反馈，不是单拍脉冲；只要请求仍未获胜就可连续多个周期为 1
    - loser 必须**冻结整条 completion request**，下拍重试；
      MUL 是流水 FU，须由 output hold 反压影响输入接受能力，**不能覆盖或丢失 result**
    - 这条义务落在各 FU 身上，本模块只给出指示

**flush 策略**——`Result_valid` 与 `bypass_valid` **都不含 flush guard**，
由各消费者自己挂。本模块无状态，既不接收也不转发 flush；flush 拍的持久化由各消费者自行门控。
各 FU 以直达的 flush 脉冲门控本地
`winner_ack[k] = winner_grant[k] ∧ !global_flush_late`，故 ack 在 flush 拍无语义。
**FU 自身的行为契约不在本模块描述**：flush 拍作废在飞指令与被 hold 的 completion request、
此后不得对旧 tag 再发 `Result_valid`、completion request 相对 issue 至少寄存一拍——
这三条都是 FU 的内部时序，归 **FU 微架构文档**。本模块只做组内仲裁与转发。

#### 2. `tag_out` / `bypass_tag` / `bypass_data` / completion 事件字段(output)

```text
tag_out      = winner_valid ? request[winner_idx].tag         : 0
result_data  = winner_valid ? request[winner_idx].result_data : 0
Result_valid = winner_valid

exception_flag       = winner_valid ? request[winner_idx].exception_flag       : 0
exception_cause      = winner_valid ? request[winner_idx].exception_cause      : 0
exception_tval       = winner_valid ? request[winner_idx].exception_tval       : 0
mispredict_flag      = winner_valid ? request[winner_idx].mispredict_flag      : 0
mispredict_target_pc = winner_valid ? request[winner_idx].mispredict_target_pc : 0
is_mret              = winner_valid ? request[winner_idx].is_mret              : 0
fpu_fflags           = winner_valid ? request[winner_idx].fpu_fflags           : 0

bypass_valid = winner_valid ∧ !request[winner_idx].exception_flag
bypass_tag   = winner_valid ? request[winner_idx].tag         : 0
bypass_data  = winner_valid ? request[winner_idx].result_data : 0
```

- 上述恒零字段由 G1 FU 的 `completion_common` 输入契约保证；`winner_valid = 0` 时输出仅为无效占位。
  仲裁器不为 G1 重新生成这些字段。

- loser 不入 winner data path；loser result 留在 FU-local hold state
- 总线名与信号名的约定同 [[p3_arbiter_G0微架构文档.md]] ④

**本模块只驱动 `completion_common`，不带 `csr_sideband`**：

```text
completion_common   Result_valid、tag_out、result_data、
                    exception_flag、exception_cause、exception_tval、
                    mispredict_flag、mispredict_target_pc、is_mret、fpu_fflags
```

这是四条 lane 的公共契约。CSR 固定路由 G0，故 `is_csr` / `csr_write_enable` /
`csr_addr` / `csr_wdata` 这组旁带字段本组**不携带、也不必伪造**。
本组不产生异常、跳转、MRET，也不产生 FP flags，对应 `exception` / `mispredict` /
`is_mret` / `fpu_fflags` 字段恒 0（见上）。

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ p3_arbiter_G1`

- completion request（Transaction，多对一 mux；ready = `winner_grant[k]`，loser 须 hold 重试）
    - broadcast；`request[k]` 的完整 `completion_common` 输入字段：
      `tag`(4)、`result_data`(64)、`exception_flag`(1)、`exception_cause`(63)、
      `exception_tval`(64)、`mispredict_flag`(1)、`mispredict_target_pc`(64)、
      `is_mret`(1)、`fpu_fflags`(5)。G1 的 ALU/MUL FU 对本组不产生的字段驱动恒 0；
      本模块纯组合，只选一路转发，不留存，也不补造这些字段
    - 触发；`request_valid[k]`(1，k∈{0,1}) —— 这个 requester 本拍要不要竞争

**out-event** `p3_arbiter_G1 →`

- writeback；`completion_common`（本组不带 `csr_sideband`，见 ④）
    - `Result_valid`(1)、`tag_out`(4)、`result_data`(64)、`exception_flag`(1)、
      `exception_cause`(63)、`exception_tval`(64)、`mispredict_flag`(1)、
      `mispredict_target_pc`(64)、`is_mret`(1)、`fpu_fflags`(5)
      —— `exception_cause` 是不带中断标志位的 cause 编号，故 63 位。本组这些字段恒 0
- exec_done；`tag_out`(4)、`Result_valid`(1)
- `bypass_publish`；`bypass_valid`(1)、`bypass_tag`(4)、`bypass_data`(64)
- `winner_select`；`winner_grant[k]`(1)
- 组合读(out)；`loser_hold[k]`(1)

**Static Info**

无。
