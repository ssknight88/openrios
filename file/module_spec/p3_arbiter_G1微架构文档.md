# p3_arbiter_G1 · G1 组内仲裁与 bypass 广播 · 2 requester

全库只有 G0、G1 两个组内仲裁器（G0 见 [[p3_arbiter_G0微架构文档.md]]）。
**G2/G3 无仲裁器**：FPU / LSU 单 requester，completion 直连 lane 2/3，连线归集成层登记。

## ① per-entry state

**无。**

多个 FU 同拍完成时，loser 的结果保持在 **FU-local hold/skid buffer** 中；
该 hold state 属对应 FU，不属本模块。

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `winner_grant[k]` / `loser_hold[k]` / `Result_valid` / `bypass_valid`(output)

**组内静态优先级**（也定义了 `FU_Group` 在本组内的取值空间）：

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
- **静态优先级无 anti-starvation**：loser 堵住按序退休 → Buffer 填满 →
  高优先级 FU 无新有效指令 → loser 必然获胜。**此保证仅在按序退休下成立**

- **bypass_publish** = `winner_valid`
- **loser_hold[k]** = `request_valid[k]` ∧ `!winner_grant[k]`
  - loser 必须**冻结整条 completion request**，下拍重试；
      MUL 是流水 FU，须由 output hold 反压影响输入接受能力，**不能覆盖或丢失 result**
    - 这条义务落在各 FU 身上，本模块只给出指示

**flush 策略**——`Result_valid` 与 `bypass_valid` **都不含 flush guard**，
由各消费者自己挂。flush 拍 winner payload 可以存在于组合线上，但**不得更新任何持久状态**。
本模块**无状态，既不接收也不转发 flush**；各 FU 以直达的 flush 脉冲门控本地
`winner_ack[k] = winner_grant[k] ∧ !global_flush_late`，故 ack 在 flush 拍无语义。

#### 2. `tag_out` / `bypass_tag` / `bypass_data` / `Result_Payload` 其余字段(output)

```text
tag_out      = winner_valid ? request[winner_idx].tag         : 0
Result_valid = winner_valid
其余 Result_Payload 字段 = winner_valid ? request[winner_idx] 的对应字段 : 0

bypass_valid = winner_valid
bypass_tag   = winner_valid ? request[winner_idx].tag         : 0
bypass_data  = winner_valid ? request[winner_idx].result_data : 0
```

- loser 不入 winner data path；loser result 留在 FU-local hold state
- 总线名与信号名的约定同 [[p3_arbiter_G0微架构文档.md]] ④

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。** FU-local hold/skid 不归本模块。

`Result_Payload` schema：四 lane 统一 > 依据：[[p3_arbiter_G0微架构文档.md]] ⑤

### ⑥ 接口

**in-event** `→ p3_arbiter_G1`

- completion request（Transaction，多对一 mux；ready = `winner_grant[k]`，loser 须 hold 重试）
  - broadcast；`request[k]` 的 `tag`(4)、`result_data`(64) 与 `Result_Payload` 的其余字段
      —— 本模块纯组合，只选一路转发，不留存
    - 触发；`request_valid[k]`(1，k∈{0,1}) —— 这个 requester 本拍要不要竞争

本模块**无 flush 端口**：不保存状态、不接收也不转发 flush 脉冲。

**out-event** `p3_arbiter_G1 →`

- writeback；`Result_Payload` 除 `Result_valid` / `tag_out` 外的全部字段、
  `tag_out`(4)、`Result_valid`(1)
- exec_done；`tag_out`(4)、`Result_valid`(1)
- `bypass_publish`；`bypass_valid`(1)、`bypass_tag`(4)、`bypass_data`(64)
- `winner_select`；`winner_grant[k]`(1)
- 组合读(out)；`loser_hold[k]`(1)

**Static Info：**

无。
