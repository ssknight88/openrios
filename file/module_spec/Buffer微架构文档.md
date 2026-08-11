# Buffer · 16 格环 · 按 tag 索引，存结果与事件元数据

### ① per-entry state

`IDLE / RESIDENT`

- 压缩进 `head` / `tail` 两个指针；per-entry valid 是区间**解码投影**，不逐格存


### ② state transition & condition（event 名）

- IDLE → RESIDENT：alloc
- RESIDENT → IDLE：commit
- RESIDENT → RESIDENT：writeback
- ANY → IDLE：flush

### ③ condition 细化

- **alloc[s]** = `accept[s]` → `entry[tail + s]` 初始化，`tail += 1/2`
    - `head` / `tail` = **5-bit** `{loopbit, index[3:0]}`：低 4 bit 是格地址（= tag），
      高 1 bit 是环绕位，与 [[IB微架构文档.md]] 的 `wptr` / `rptr` 同款；
      指针加法按 mod32 自然回绕，**寻址与对外 tag 一律取 `index[3:0]`**，
      三个 16 格阵列共用这套 4-bit 地址算术，下游不再各自声明
    - **采样约定**：余量由 `occupancy` ，是**拍初值**——`free ≥ 1` → `can_alloc_1`，
      `free ≥ 2` → `can_alloc_2`。
    - `occupancy = tail - head`（0..16）、`full_flag = (occupancy == 16)`、
      `buffer_empty = (occupancy == 0))、`alloc_1/2 = (16 - occupancy ≥ 1/2)`——
    - alloc 拍把全部 writeback 批字段置 0
- **writeback** = `Result_valid[g]` ∧ `!global_flush_late` → 写 `entry[tag_out[g]]`
    - **4 写口、随机寻址**；四个 `tag_out` 对应写入Buffer_Entry
- **commit** = `commit_count` → `head += commit_count`
    - `commit_count ∈ 0..2`；为 0 时不移动 `head`
    - 本模块只按给定的条数前移指针
- **flush** = `global_flush_late` → 指针落位，**严格按此次序**：

```text
head_new = head + commit_count
tail_new = head_new
// occupancy 是投影，随指针落位自动归 0
```

### ④ data path

#### 1. `entry` payload

```text
alloc 输入端口     → entry[tail + s]     
rd_idx、rd_is_fp、rd_write_enable、is_store、is_serial

writeback 输入端口 → entry[tag_out[g]]   
result_data、mispredict_flag、
mispredict_target_pc、
exception_flag、exception_cause、exception_tval、
is_csr、csr_write_enable、csr_addr、csr_wdata、is_mret
entry[head0_tag] / entry[head1_tag] → head 读出端口   整条 entry（2 读口）
entry[flush_tag]                    → 恢复读出端口     mispredict_target_pc、exception_cause、
                                                     exception_tval
```
### ⑤ data structure（schema + 字段三角色）

- **state**：`IDLE / RESIDENT`
- **header**：**无**
- **payload**:

```text
alloc:     rd_idx、rd_is_fp、use_rd
writeback: result_data、mispredict_flag、mispredict_target_pc(单独放一个)、
           exception_flag、exception_cause、exception_tval、
           is_csr、csr_write_enable、csr_addr、csr_wdata、is_mret（全部挪到SCB）
```
### ⑥ 接口

**in-event** `→ Buffer`

- alloc:（Transaction，**2 写口**，per slot；ready = `can_alloc_1` / `can_alloc_2`，已被上游吸收）
    - move；`rd_idx[s]`(5)、`rd_is_fp[s]`(1)、`is_store[s]`(1)、`is_serial[s]`(1)、
      `rd_write_enable[s]`(1) —— 整批存进 `entry[tail + s]`，写入即定

- writeback:（announce ×4，**4 写口、随机寻址**）
    - move；`result_data`(64)、`mispredict_flag`(1)、`mispredict_target_pc`(64)、
      `exception_flag`(1)、`exception_cause`、`exception_tval`、
      `is_csr`(1)、`csr_write_enable`(1)、`csr_addr`(12)、`csr_wdata`(64)、`is_mret`(1)
      —— 覆盖进 `entry[tag_out[g]]` 的 writeback 批
    - 触发；`Result_valid[g]`(1) —— 本拍这条 lane 要不要写回
    - 地址；`tag_out[g]`(4) —— 写第几格 entry

- commit（announce，**无独立 valid**——`commit_count != 0` 即 fire）
    - broadcast；`commit_count`(2) —— 推 `head`，不落进任何 entry

- flush（announce）
    - 触发；`global_flush_late`(1) —— 单线脉冲，指针复位，无载荷

- 组合读(in):
    - 地址；`head0_tag`、`head1_tag`(4×2) —— 两个队头读口的下标
    - 地址；`flush_tag`(4) —— 恢复读口的下标

**out-event** `Buffer →`

- 组合读(out)；整条 entry payload（字段清单见 ⑤）
- 组合读(out)；mispredict_target_pc(64)、exception_cause、exception_tval

**Static Info**
- `Buffer_head`(4) —— `head` 的 `index[3:0]` 投影
- `Buffer_tail`(4) —— `tail` 的 `index[3:0]` 投影
- `occupancy`(5) —— `tail - head`
- `can_alloc_1` / `can_alloc_2`(1×2) —— `occupancy` 的投影，**拍初值**
- `rob_empty`(1) —— `(occupancy == 0)`，**拍初值**
