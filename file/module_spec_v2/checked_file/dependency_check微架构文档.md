# dependency_check
### ① per-entry state

**无。**

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。**

### ④ data path

#### 1. `self_tag[s]` / `rd_write_enable[s]`(output)
推导：

```text
self_tag[0] = Buffer_tail
self_tag[1] = Buffer_tail + 1

rd_write_enable[s] =
      use_rd[s]
    ∧ !(rd_idx[s] == 0 ∧ !rd_is_fp[s])
```

- `rd_write_enable[s]` 只抑制 INT `rd_idx == 0`；FP侧 的 `f0` 不抑制

#### 2. `slot0_present` / `slot1_present` / `serial0` / `serial_inst` / `fp0` / `fp1`(output)
推导：

```text
slot0_present = inst_valid[0]
slot1_present = inst_valid[1]

serial0     = is_serial[0]
serial_inst = is_serial[0] ∨ is_serial[1]

fp0 = is_fp_instruction[0]
fp1 = is_fp_instruction[1]
```
- `fp0` / `fp1` 供下游判双FP指令阻塞 > 依据：[[dispatch_logic微架构文档.md]] ④

#### 3. `slot_missed_wakeup` / `rsX_ready` / `rsX_wait_tag` / `rs_data_sel_t`(output)
推导：
**第一步 · 同拍 RAW 命中**（slot0 的目的寄存器 → slot1 的源）

```text
slot1_dep_hit[x] =                      //x ∈ {1,2,3}，只对 slot1 求值
    slot0_present ∧ rd_write_enable[0]  // slot0 确实要写目的寄存器
    ∧ use_rsX[1]
    ∧ (rsX_idx[1]   == rd_idx[0])
    ∧ (rsX_is_fp[1] == rd_is_fp[0])
```

- **只覆盖 RAW**；WAR / WAW 不进入这一步，目的寄存器既有写口覆盖规则不变

**第二步 · 源查询**

```text
producer_tag[s][x] = rsX_is_fp[s] ?  FP_tag_mapping[fp_read_idx[x]].tag
                                  : INT_tag_mapping[rsX_idx[s]].tag
arf_ready[s][x]    = rsX_is_fp[s] ? !FP_tag_mapping[fp_read_idx[x]].busy
                                  : !INT_tag_mapping[rsX_idx[s]].busy

commit_match(t) / commit_lane(t) = 在 2 条 Commit lane 上找 valid ∧ tag == t
bypass_match(t) / bypass_lane(t) = 在 4 条 bypass lane 上找 valid ∧ tag == t
```

- FP 侧 3 个读口服务 2 个 slot：`fp_read_idx[x]` 取自被 `fp0` 选中的那个 slot。
  被接受的 FP slot 必然就是被选中的那个（有效消费者唯一，见
  [[FP_read_address_mux微架构文档.md]] ④），故 `rsX_is_fp[s]` 为真时该读口给出的就是 slot `s` 的值
- INT 侧 4 个读口按 `(s,x) ∈ {0,1}×{1,2}` 一一对应；`rs3` 永不走 INT
  （上游契约 `use_rs3[s] ⇒ rs3_is_fp[s]`）

**第三步 · 根据条件选择data来源**

对每个 `s ∈ {0,1}`、`x ∈ {1,2,3}`，自上而下**首个命中者胜**：

```text
   source_kind    命中条件                          rsX_ready  rsX_wait_tag    rs_data_sel_t
1  WAIT_OVERLAY   s==1 ∧ slot1_dep_hit[x]               0      self_tag[0]     全零
2  NONE           !use_rsX[s]                           1      0               全零
3  ARF            arf_ready[s][x]                       1      producer_tag    sel_arf
4  COMMIT         commit_match(producer_tag)            1      producer_tag    sel_commit[commit_lane]
5  BYPASS         bypass_match(producer_tag)            1      producer_tag    sel_bypass[bypass_lane]
6  WAIT_PRODUCER  其余                                   0     producer_tag    全零

slot_missed_wakeup[s] = OR over x∈{1,2,3} (
      source_kind[s][x] == WAIT_PRODUCER
    ∧ scoreboard_valid_bits[rsX_wait_tag[s][x]]
    ∧ scoreboard_exec_done_bits[rsX_wait_tag[s][x]] )
```

- `rs_data_sel_t = { sel_arf, sel_commit[2], sel_bypass[4] }`，7 bit、onehot0。
  全零只表示本拍不采样源数据，**不替代 `rsX_ready` 的状态含义**
- **本模块不取任何源数据**：只比 tag。按选择码从 ARF / Commit CDB / bypass lane 取数
  装配 `rsX_data` 的逻辑**归集成层**（与 FU 连线同级；
  [[p1_ISQ_input_mux微架构文档.md]] 只做 slot 二选一，不做字段装配）
- missed-wakeup 只查第 6 行：第 1 行等的是本拍才分配的 slot0 tag，Scoreboard 里还没有它；
  第 3–5 行已经 READY

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**
### ⑥ 接口

**in-event** `→ dependency_check`

- 组合读(in):

    - broadcast；`inst_valid`(1)、`rd_idx`(5)、`rd_is_fp`(1)、`use_rd`(1)、`is_serial`(1)、`is_fp_instruction`(1)、`use_rs1/2/3`(1 各)、`rs1/2/3_idx`(5 各)、`rs1/2/3_is_fp`(1 各)—— 每 slot 一份，s∈{0,1}＝队头 2 slot

    - broadcast；`Buffer_tail`(4) —— 算 `self_tag[s]` 的基址（由 CompletionScoreboard 导出，信号名沿用）

    - broadcast；`INT_tag_mapping[rsX_idx[s]].tag`(4)、`INT_tag_mapping[rsX_idx[s]].busy`(1) —— **4 读口**，(s,x) ∈ {0,1}×{1,2}

    - broadcast；`FP_tag_mapping[fp_read_idx[x]].tag`(4)、`FP_tag_mapping[fp_read_idx[x]].busy`(1)—— **3 读口**，x ∈ {1,2,3}

    - broadcast；`scoreboard_valid_bits[16]`、`scoreboard_exec_done_bits[16]`
      —— 判 producer 是否已完成

- commit（announce，**2 lane**）
    - broadcast；`commit_valid[k]`(1，k∈{0,1})、`commit_tag[k]`(4，k∈{0,1}) —— 与 producer tag 比对；
      **不取 `data`**（P1 只需知道"这个 tag 的值现在可取"）

- `bypass_publish`（announce，**4 lane**）
    - broadcast；`bypass_valid[b]`(1，b∈{0..3})、`bypass_tag[b]`(4，b∈{0..3}) —— 同上；**不取 `data`**

**out-event** `dependency_check →`

- alloc；`self_tag[s]`(4)、`rd_write_enable[s]`(1)
- serial_set；`self_tag[0]`(4)
- write；`self_tag[s]`(4)
- 组合读(out)；`slot0_present`(1)、`slot1_present`(1)、`serial0`(1)、`serial_inst`(1)、
  `fp0`(1)、`fp1`(1)、`slot_missed_wakeup[0/1]`(1×2)、`rsX_ready[s][x]`(1×6)、`rsX_wait_tag[s][x]`(4×6)、`rs_data_sel_t[s][x]`(7×6)

**Static Info**
无。
