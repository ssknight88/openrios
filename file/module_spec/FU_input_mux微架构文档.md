# FU_input_mux · 纯组合 · issue 侧源数据二选一 · 按 rs 实例化 ×9

**按源操作数实例化，共 9 份**——G0/G1/G3 各 rs1/rs2，G2 加 rs3（2+2+3+2 = 9）。
实例内部**无跨源逻辑、无参数化差异**：一份实例 = 一个源的二选一。
哪份接哪个 ISQ 的哪个源、输出接哪个 FU 操作数口，归集成层，本文只描述一份。

ISQ issue 时每个源的数据有两个可能出处：entry 里存的 `rsX_data`（该源早已 ready），
或本拍 lane 上的 `bypass_data[b]`（`fast_ready_rsX` 命中，绕过 entry 直接前递）。
本模块做这个二选一，输出接 FU 的操作数输入；

## ① per-entry state

**无。**

## ② state transition & condition（event 名）

**无。**

## ③ condition 细化

**无。**

## ④ data path

### 1. `fu_rsX_data`(output)

```text
hit[b] = bypass_valid[b] ∧ (rsX_wait_tag == bypass_tag[b])           b ∈ {0..3}

fu_rsX_data =
    rsX_ready : entry.rsX_data       // ready 优先
    hit[0]    : bypass_data[0]
    hit[1]    : bypass_data[1]       // hit 至多一位为 1，四行之间无先后
    hit[2]    : bypass_data[2]
    hit[3]    : bypass_data[3]
    其余      : don't-care            // 该源未就绪 ⇒ 本拍不发射 ⇒ 无人采样
```

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

- 组合读(out)；`fu_rsX_data`(64) —— 接对应 FU 的一个操作数输入

**Static Info：**

无。
