# Module `ISQ_Group3`

`ISQ_Group3`：hold one LSU instruction until its two sources and the LSU bridge are ready, then issue it。

## Submodule
Per-source entry/bypass selection is local combinational logic. 无。

## FSM
### State
#### Per-entry State

```text
FREE: no LSU instruction is resident.
RESIDENT: one LSU instruction is resident and may wait for rs1/rs2 bypass.
Reset State: FREE.
```

### State Transition & Condition Name
1. `FREE -> RESIDENT`：`dispatch`
2. `RESIDENT -> RESIDENT`：`dispatch`
3. `RESIDENT -> FREE`：`issue`
4. `RESIDENT -> RESIDENT`：`bypass_capture`
5. `ANY -> FREE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `dispatch`：
   ```text
   dispatch.fire = isq_dispatch_g3.fire
   wr_en         = dispatch.fire
   payload_in    = isq_dispatch_g3.payload
   ```

2. `dispatch`：见第 1 条 `dispatch`。

3. `issue`：
   ```text
   issue_request = isq_valid ∧ operand_ready
   operand_ready = (entry.rs1_ready ∨ fast_ready_rs1)
                ∧ (entry.rs2_ready ∨ fast_ready_rs2)
   issue_valid   = issue_request ∧ ¬flush.fire
   issue.fire    = issue_valid ∧ FU_ready
   ```

   `FU_ready` is class-qualified by `g3_lsu_iface` from the offered `exe_subop`/memory class. The issue payload is presented before that readiness value is consumed.

4. `bypass_capture`：
   For `X ∈ {rs1,rs2}` and `b ∈ {0,1,2,3}`:

   ```text
   hit_X[b] = bypass_publish[b].fire
             ∧ (bypass_publish[b].tag == entry.X_wait_tag)
   hit_any_X = ∃b: hit_X[b]
   winner_X[b] = hit_X[b] ∧ ∀j < b: ¬hit_X[j]
   forward_X = winner_X[0] ? bypass_publish[0].data :
               winner_X[1] ? bypass_publish[1].data :
               winner_X[2] ? bypass_publish[2].data :
               winner_X[3] ? bypass_publish[3].data : 0
   fast_ready_X = ¬entry.X_ready ∧ hit_any_X
   ```

   ```text
   bypass_capture = isq_valid ∧ ¬flush.fire ∧ ¬issue.fire
                  ∧ (fast_ready_rs1 ∨ fast_ready_rs2)
   bypass_capture_X = isq_valid ∧ ¬flush.fire ∧ ¬issue.fire
                    ∧ ¬entry.X_ready ∧ hit_any_X
   ```

   On `bypass_capture_X`, `entry.X_ready(next)=1`, `entry.X_data(next)=forward_X`, and `entry.X_wait_tag` remains unchanged.

5. `flush`：`flush.fire` 时清除 entry valid；优先级：`reset > flush > dispatch > issue > bypass_capture`。

   For resident dispatch, `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire` makes issue+replacement explicit: issue reads the old entry in cycle `t`, and dispatch writes the new payload at the edge into cycle `t+1`.

## Data structure
### State

- ``isq_valid``：Width / Depth=1 x 1; Role=state; Reset=0; Update=dispatch -> 1; issue without replacement or flush -> 0

### Header

- ``rs1_ready`, `rs2_ready``：Width / Depth=1 x 2; Consumed by=`operand_ready`, `fast_ready_X`; Update=dispatch capture; matching bypass capture -> 1
- ``rs1_wait_tag`, `rs2_wait_tag``：Width / Depth=`TAG_W=4` x 2; Consumed by=`hit_X[b]`; Update=dispatch capture; unchanged afterward

### Payload

- ``rs1_data`, `rs2_data``：Width / Depth=64 x 2; Storage=one entry; Written by=dispatch; bypass capture; Read by=`issue_g3`
- ``imm_valid`, `imm_data``：Width / Depth=1 + 64; Storage=one entry; Written by=dispatch; Read by=`issue_g3`
- ``is_store`, `mem_funct3`, `rd_is_fp``：Width / Depth=1 + 3 + 1; Storage=one entry; Written by=dispatch; Read by=`issue_g3`
- ``self_tag`, `exe_subop``：Width / Depth=4 + 24; Storage=one entry; Written by=dispatch; Read by=`issue_g3`

Reset sets all stored fields to zero; fields are unobservable while `isq_valid=0`.

## Data Path
- ``backend_top.slot_payload[0:1]`, selected by `backend_top.select_payload[G3][s]`` -> ``ISQ_Group3.entry``：`isq_payload_t` capture subset；驱动 `isq_dispatch_g3`；`wr_en = isq_dispatch_g3.fire`
- `completion lane `b`` -> ``entry.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`bypass_capture_X ∧ winner_X[b]`
- `completion lane `b`` -> ``issue_g3.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`issue.fire ∧ ¬entry.X_ready ∧ winner_X[b]`
- `stored entry fields` -> ``g3_lsu_iface``：`issue_g3_payload_t`；驱动 `entry`；`issue.fire`


## Interface

### In-event

- `isq_dispatch_g3`：Transaction / credit-based；`isq_payload_t`；same-cycle fire
- `bypass_publish[b]`：Notify；`{tag:4,data:64}`；same-cycle broadcast
- `flush`：Notify；`∅`；masks local fires

### In Static Info

- `FU_ready`：Static Info；1 bit, class-qualified；combinational

### Out-event

- `issue_g3`:
  - **Request:** `issue_valid = issue_request ∧ ¬flush.fire`.
  - **Fire:** `issue_g3.fire = issue_valid ∧ FU_ready`.
  - **Timing:** request and all nine payload fields are combinational and continuously presented; `g3_lsu_iface` samples on fire.
  - **Hold:** the entry and payload remain stable while `FU_ready=0`.
  - **Cancel:** flush masks the request and invalidates the entry.

  #### Payload Schema: `issue_g3_payload_t`
- ``rs1_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs1_ready ? entry.rs1_data : forward_rs1`
- ``rs2_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs2_ready ? entry.rs2_data : forward_rs2`
- ``imm_valid``：Width / Type=1; Cardinality=one; Generation rule=`entry.imm_valid`
- ``imm_data``：Width / Type=signed `XLEN=64`; Cardinality=one; Generation rule=`entry.imm_data`
- ``is_store``：Width / Type=1; Cardinality=one; Generation rule=`entry.is_store`
- ``mem_funct3``：Width / Type=`MEM_FUNCT3_W=3`; Cardinality=one; Generation rule=`entry.mem_funct3`
- ``rd_is_fp``：Width / Type=1; Cardinality=one; Generation rule=`entry.rd_is_fp`
- ``self_tag``：Width / Type=`TAG_W=4`; Cardinality=one; Generation rule=`entry.self_tag`
- ``exe_subop``：Width / Type=`EXE_SUBOP_W=24`; Cardinality=one; Generation rule=`entry.exe_subop`

  Total width: `226` bits. `req_property` and `st_br_resolve` are derived downstream by `g3_lsu_iface`, not by this module.

### Out Static Info

```text
isq_free_for_dispatch = ¬isq_valid ∨ issue.fire
isq_occupied          = isq_valid
```

Both are combinational projections; `isq_occupied` remains 1 in the issue cycle until the clock edge clears the entry.
- `isq_free_for_dispatch`：Static Info；1 bit；combinational credit
- `isq_occupied`：Static Info；1 bit；combinational state projection

### Interface Timing

`wr_en = isq_dispatch_g3.fire` and `payload_in = isq_dispatch_g3.payload` are the complete dispatch boundary. The downstream bridge adds LSU-specific fields after `issue_g3`.






