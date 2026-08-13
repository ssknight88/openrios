# p3_arbiter_G0 · G0 组内仲裁与 bypass 广播 · 3 requester

全库只有 G0、G1 两个组内仲裁器（G1 见 [[p3_arbiter_G1微架构文档.md]]）。
**G2/G3 无仲裁器**：FPU / LSU 单 requester，completion 直连 lane 2/3。

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `winner_grant[k]` / `loser_hold[k]` / `Result_valid` / `bypass_valid`(output)

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

- **bypass_publish** = `winner_valid`
- **loser_hold[k]** = `request_valid[k]` ∧ `!winner_grant[k]`
  - loser 必须**冻结整条 completion request**，下拍重试；FU（CSR / DIV）保持 busy；FU 需由 output hold 反压影响输入接受能力，**不能覆盖或丢失 result**

**FU flush 契约**：
`global_flush_late` 拍，各 FU 必须**作废全部在Inflight指令与被 hold 的 completion request**，
此后**不得对旧 tag 再发 `Result_valid`**。

### 2. `tag_out` / `bypass_tag` / `bypass_data` / writeback 其余字段(output)

```text
tag_out      = winner_valid ? request[winner_idx].tag         : 0
Result_valid = winner_valid
其余 writeback 字段 = winner_valid ? request[winner_idx] 的对应字段 : 0

bypass_valid = winner_valid
bypass_tag   = winner_valid ? request[winner_idx].tag         : 0
bypass_data  = winner_valid ? request[winner_idx].result_data : 0
```

- **`bypass_*` 名义上叫 CDB，物理上是组合广播**——不是寄存器化的公共数据总线，也不是 CAM。
  消费者侧的 tag 比较是分布式的等值比较器，不在本模块
- **lane 与 group 一一对应**，全库共 4 lane，编号 `b = g`；lane 2/3 由 FPU / LSU
  直接驱动（无仲裁器），四处消费者不重排、不压缩
- loser 不入 winner data path；loser result 留在 FU-local hold state

**总线名与信号名**——`p3_bypass_CDB` 是**总线名**，只用于描述这组线整体；
公式与接口一律用信号名 `bypass_valid[g]` / `bypass_tag[g]` / `bypass_data[g]`。

## ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

## ⑥ 接口

**in-event** `→ p3_arbiter_G0`

- completion request（Transaction，多对一 mux；ready = `winner_grant[k]`，loser 须 hold 重试）
  - broadcast；`request[k]` 的 `tag`(4)、`result_data`(64)、`mispredict_flag`(1)、
      `mispredict_target_pc`(64)、`exception_flag`(1)、`exception_cause`、`exception_tval`、
      `is_csr`(1)、`csr_write_enable`(1)、`csr_addr`(12)、`csr_wdata`(64)、`is_mret`(1)
    - 触发；`request_valid[k]`(1，k∈{0,1,2}) —— 这个 requester 本拍要不要竞争

**out-event** `p3_arbiter_G0 →`

- writeback；`result_data`(64)、`mispredict_flag`(1)、`mispredict_target_pc`(64)、
  `exception_flag`(1)、`exception_cause`、`exception_tval`、`is_csr`(1)、
  `csr_write_enable`(1)、`csr_addr`(12)、`csr_wdata`(64)、`is_mret`(1)、
  `tag_out`(4)、`Result_valid`(1)
- exec_done；`tag_out`(4)、`Result_valid`(1)
- `bypass_publish`；`bypass_valid`(1)、`bypass_tag`(4)、`bypass_data`(64)
- `winner_select`；`winner_grant[k]`(1)
- 组合读(out)；`loser_hold[k]`(1)

**Static Info：**

无。
