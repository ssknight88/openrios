# FU_input_mux · 纯组合 · issue 侧源数据二选一 · 按 rs 实例化 ×9

**本模块是 `ISQ_Group` 的 issue 端口子块，不是独立于 ISQ 的模块。**
9 份实例分属四组——G0/G1/G3 各 rs1/rs2，G2 加 rs3（2+2+3+2 = 9）——
每份住在自己所属的那个 `ISQ_Group` 内部。输入 `entry.rsX_data` / `rsX_ready` /
`rsX_wait_tag` 都是所属 ISQ 的内部信号，**不是跨模块边**；输出就是该 ISQ
issue 端口上的那个源数据。故集成层不登记本模块，只登记 `ISQ_Group → FU` 的 issue 交付。

选择判据本就归 ISQ：它为出 `issue_valid` 必须自己算 `fast_ready_rsX`，
本模块只是拿这个已有结果去选数据，比较不另算一份。

实例内部**无跨源逻辑、无参数化差异**：一份实例 = 一个源的二选一。本文只描述一份。

ISQ issue 时每个源的数据有两个可能出处：entry 里存的 `rsX_data`（该源早已 ready），
或本拍 lane 上的 `bypass_data[b]`（`fast_ready_rsX` 命中，绕过 entry 直接前递）。
本模块做这个二选一，输出接 FU 的操作数输入；

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `fu_rsX_data`(output)

```text
hit[b] = bypass_valid[b] ∧ (rsX_wait_tag == bypass_tag[b])           b ∈ {0..3}

fu_rsX_data =
    rsX_ready : entry.rsX_data       // ready 优先
    hit[0]    : bypass_data[0]
    hit[1]    : bypass_data[1]
    hit[2]    : bypass_data[2]
    hit[3]    : bypass_data[3]
    其余      : don't-care            // 该源未就绪 ⇒ 本拍不发射 ⇒ 无人采样
```

`hit[b]` 至多一位为 1 的依据是 [[CompletionScoreboard微架构文档.md]] ⑥ 的 writeback
约束：四条有效 `tag_out` 属不同在飞 tag；集成层将 `bypass_tag[b]` 直连为对应
`tag_out[b]`。本模块只消费该既有约束，不另造不变量。

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ FU_input_mux`（×9）

- 组合读(in)
    - broadcast；`entry.rsX_data`(64) —— entry 里存的源数据，二选一的一路
    - broadcast；`bypass_data[b]`(64×4) —— 二选一的另一路
    - broadcast；`bypass_valid[b]`(1×4)、`bypass_tag[b]`(4×4)、`rsX_wait_tag`(4)
      —— 进 `hit[b]` 比较，不留存
    - 选通；`rsX_ready`(1) —— 选 entry 还是 bypass_lane

**out-event** `FU_input_mux →`

- 组合读(out)；`fu_rsX_data`(64) —— 所属 `ISQ_Group` issue 端口上的该源数据，
  由 ISQ 交付给对应 FU 的一个操作数输入；集成层显式映射为
  `ISQ_Group.issue.rsX_data ↔ fu_rsX_data`，二者均为 64 bit，不是两条独立数据通路

**Static Info**

无。
