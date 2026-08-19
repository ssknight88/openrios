# FU_input_mux · 纯组合 · issue 侧源数据二选一

**按 group 实例化 4 份**，每份服务一个 `ISQ_Group` 的 issue 输出——差别只在源的数目与连接：
G0/G1/G3 两源，G2 三源（含 `rs3`）。实例与连接归集成层，本文只描述一份实例。

ISQ issue 时每个源的数据有两个可能出处：entry 里存的 `rsX_data`（该源早已 ready），
或本拍 lane 上的 `bypass_data[b]`（`fast_ready_rsX` 命中，绕过 entry 直接前递）。
本模块做这个二选一，输出接 FU 的操作数输入；除源数据外的 issue payload 字段不经过本模块。

### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `fu_rsX_data`(output)

```text
hit[b]      = bypass_valid[b] ∧ (rsX_wait_tag == bypass_tag[b])      b ∈ {0..3}
fu_rsX_data = rsX_ready ? entry.rsX_data
            : OR-select over b (hit[b] ? bypass_data[b])
```

- 两路对同一个 `rsX` 互斥：`fast_ready_rsX` 含 `!rsX_ready`，两路不会同时成立；各源并行，互不牵扯
- 四条 lane 同拍写四个不同 tag（tag 正交性由 Buffer 的分配保证），`hit[b]` 至多一位为 1
- 前递值**不落 entry**——落 entry 的那份是 `bypass_capture` 的事，
  归 `ISQ_Group`


### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ FU_input_mux`

- 组合读(in)
    - broadcast；`entry.rsX_data`(64×源数) —— entry 里存的源数据，二选一的一路
    - broadcast；`bypass_data[b]`(64×4) —— 二选一的另一路
    - broadcast；`bypass_valid[b]`(1×4)、`bypass_tag[b]`(4×4)、`rsX_wait_tag`(4×源数)
      —— 进 `hit[b]` 比较，不留存
    - 选通；`rsX_ready`(1×源数) —— 选 entry 还是 lane

**out-event** `FU_input_mux →`

- 组合读(out)；`fu_rsX_data`(64×源数) —— 接对应 FU 的操作数输入

**Static Info**

无。
