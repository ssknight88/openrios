# Module `IB`

`IB`：8-entry、2-lane 的前端指令 FIFO（`IB_DEPTH=8`、`ISSUE_WIDTH=2`、`IB_PTR_W=4`）。

## Submodule

无。

## FSM

### State

#### Per-entry State

1. `IDLE`：entry 为空。
2. `RESIDENT`：entry 保存一条指令，等待出队。

### State Transition & Condition Name

1. `ANY -> IDLE`：`reset`
2. `RESIDENT -> IDLE`：`flush`
3. `IDLE -> RESIDENT`：`enqueue`
4. `RESIDENT -> IDLE`：`dequeue`

没有 Event fire 时状态保持。

### Detailed Condition Description

1. `reset`：清空 FIFO。
   - Fire来源：
     - `reset.fire = ¬rst_n`
   - State update：`wptr_q=0`、`rptr_q=0`、`entry.payload[0:7]=0`。

2. `flush`：清空 FIFO 的逻辑有效区间。
   - Fire来源：
     - `flush.fire = global_flush_late`
   - State update：`wptr_q=0`、`rptr_q=0`；`entry.payload` 不清零。
   - Priority：高于 `enqueue` 和 `dequeue`。

3. `enqueue`：接收 FE 当前拍提交的 payload。
   - Fire来源：
     - `enqueue[s].fire = accepted_slot[s]`
     - `accepted_slot[s]`：当前拍 FE payload 是否被 IB 接收。
       - `accepted_slot[0] = enqueue_valid[0] ∧ IB_ready[0]`
       - `accepted_slot[1] = enqueue_valid[1] ∧ IB_ready[1]`
     - `free_slot`：拍初 FIFO 可用的空位数量。
       - `free_slot = IB_DEPTH - valid_count`
     - `enqueue_valid[0]`、`enqueue_valid[1]`：上游当前拍提供的两个 payload 是否有效。
     - `IB_ready[0]`：IB 当前拍是否能接收 slot0。
       - `IB_ready[0] = (free_slot >= 1) ∧ ¬flush.fire`
     - `IB_ready[1]`：IB 当前拍是否能接收 slot1。
       - `IB_ready[1] = enqueue_valid[0] ∧ (free_slot >= 2) ∧ ¬flush.fire`
     - `IB_DEPTH=8`：FIFO entry 数量。
     - `valid_count`：拍初 FIFO 中已占用的 entry 数量。
       - `valid_count = (wptr_q - rptr_q) mod 16`
     - `wptr_q`：拍初写指针，指向下一个可写位置。
     - `rptr_q`：拍初读指针，指向当前 head payload。
   - Constraint：`enqueue_valid[1] -> enqueue_valid[0]`；`accepted_slot` 只能为 `00`、`01`、`11`。
   - Payload：`IB_payload[s]`。
   - State update：`entry.payload[(wptr_idx+s) mod IB_DEPTH] <- IB_payload[s]`；`wptr_q_next = wptr_q + enq_count`。
   - `wptr_idx = wptr_q[IB_PTR_W-2:0]`。
   - `enq_count = enqueue[0].fire + enqueue[1].fire`。

4. `dequeue`：消费 IB head payload。
   - Fire来源：
     - `dequeue[s].fire = inst_valid[s] ∧ ib_dequeue_request[s]`
     - `inst_valid[s]`：这个 entry 是否有效。
       - `inst_valid[0] = (valid_count >= 1)`
       - `inst_valid[1] = (valid_count >= 2)`
       - `valid_count`：见第 3 条 `enqueue`。
     - `ib_dequeue_request[s]`：是否收到出队请求。
   - Constraint：`ib_dequeue_request[1] -> ib_dequeue_request[0]`；`dequeue` 只能为 `00`、`01`、`11`。
   - State update：被消费逻辑 entry 从 `RESIDENT -> IDLE`；`rptr_q_next = rptr_q + deq_count`。
   - `rptr_idx = rptr_q[IB_PTR_W-2:0]`。
   - `deq_count = dequeue[0].fire + dequeue[1].fire`。
   - `valid_count_next = valid_count + enq_count - deq_count`。

优先级：`reset > flush > enqueue/dequeue pointer and payload update`。

## Data structure

### State

`IDLE / RESIDENT`：逻辑 entry 状态；压缩进 `wptr_q`、`rptr_q`（4 bit，`{loopbit,index[2:0]}`）；有效区间 `[rptr_q,wptr_q)`；reset=0；enqueue 更新 `wptr_q`，dequeue 更新 `rptr_q`，flush 清零二者。

### Header

无。

### Payload

`entry.payload[0:7]`：`IB_payload`

`IB_payload`：`pc[63:0]`、`inst_bits[31:0]`、`is_compressed`、`pred_taken`、`pred_target_pc[63:0]`、`fetch_excp_vld`、`fetch_excp_cause[4:0]`、`fetch_excp_tval[63:0]`。

## Data Path

- `enqueue[s] -> entry.payload[(wptr_q[2:0]+s) mod IB_DEPTH]`：`IB_payload`；`enqueue[s].fire` 时写入。
- `entry.payload[(rptr_q[2:0]+s) mod IB_DEPTH] -> decode_payload[s]`：`decode_payload`；每拍组合读。

## Interface

### In-event

- `enqueue[s]`：Transaction，`s∈{0,1}`，payload=`IB_payload[s]`（232 bit）；fire=`enqueue_valid[s] ∧ IB_ready[s]`；上升沿采样。
- `flush`：Notify，payload=`∅`；fire=`global_flush_late`；边沿复位指针。
- `reset`：异步 Event，payload=`∅`；fire=`¬rst_n`；异步清零状态。

### In Static Info

- `ib_dequeue_request[s]`：1 bit，`s∈{0,1}`；当前拍是否请求 dequeue。

### Out-event

- `dequeue[s]`：Notify，`s∈{0,1}`，payload=`∅`.

### Out Static Info

- `decode_payload[s]`：`decode_payload`，232 bit，`s∈{0,1}`；`entry.payload[(rptr_q+s) mod IB_DEPTH]`；组合连续读。
- `inst_valid[s]`：1 bit，`s∈{0,1}`；`valid_count >= s+1`。
- `IB_ready[s]`：1 bit，`s∈{0,1}`；见 FSM 第 3 条 `enqueue`。
- `accepted_slot[s]`：1 bit，`s∈{0,1}`；`enqueue_valid[s] ∧ IB_ready[s]`。

### Interface Timing

- `clk`：时钟；`rst_n`：异步低有效复位。
- `enqueue`：只使用拍初空位；`enqueue_valid[1] -> enqueue_valid[0]`。
- `dequeue`：fire 时推进 `rptr_q`。
- `flush`：屏蔽 enqueue/dequeue，指针次态为 0。
