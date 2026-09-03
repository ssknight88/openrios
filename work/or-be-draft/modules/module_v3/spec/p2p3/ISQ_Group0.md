# Module `ISQ_Group0`

`ISQ_Group0`：hold one G0 instruction until its operands and selected FU are ready, then issue it。

## Submodule
无。

## FSM
### State
#### Per-entry State

```text
FREE: no instruction is resident; dispatch credit may be consumed.
RESIDENT: one G0 instruction is resident; operands may wait for bypass.
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
   dispatch.fire = isq_dispatch_g0.fire
   wr_en         = dispatch.fire
   payload_in    = isq_dispatch_g0.payload
   ```

   The complete candidate selection, slot order, group route, and credit equations are defined once by `backend_top` composition Output.

2. `dispatch`：见第 1 条 `dispatch`。

3. `issue`：
   ```text
   issue_request = isq_valid ∧ operand_ready
   operand_ready = (entry.rs1_ready ∨ fast_ready_rs1)
                ∧ (entry.rs2_ready ∨ fast_ready_rs2)
   fu_ready_sel  = FU_ready[entry.fu_group] for entry.fu_group ∈ {0,1,2}; otherwise 0
   issue_valid   = issue_request ∧ ¬flush.fire
   issue.fire    = issue_valid ∧ fu_ready_sel
   ```

4. `bypass_capture`：
   For `X ∈ {rs1,rs2}` and lane `b ∈ {0,1,2,3}`:

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

   On `bypass_capture_X`, `entry.X_ready(next)=1` and `entry.X_data(next)=forward_X`; `entry.X_wait_tag` is unchanged.

5. `flush`：`flush.fire` 时清除 entry valid；优先级：`reset > flush > dispatch > issue > bypass_capture`。

   For a resident entry, `dispatch.fire -> issue.fire` because dispatch consumes `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire`. Thus dispatch+issue reads `entry(t)` and captures the replacement payload into `entry(t+1)`.

## Data structure
### State

- ``isq_valid``：Width / Depth=1 x 1; Role=state; Reset=0; Update=`dispatch` -> 1; `issue` without replacement or `flush` -> 0

### Header

- ``rs1_ready`, `rs2_ready``：Width / Depth=1 x 2; Consumed by=`operand_ready`, `fast_ready_X`; Update=payload capture; matching bypass capture -> 1
- ``rs1_wait_tag`, `rs2_wait_tag``：Width / Depth=`TAG_W=4` x 2; Consumed by=`hit_X[b]`; Update=payload capture; unchanged afterward
- ``fu_group``：Width / Depth=`FU_GROUP_W=2`; Consumed by=`fu_ready_sel`; Update=payload capture; replacement dispatch overwrites

### Payload

- ``rs1_data`, `rs2_data``：Width / Depth=`XLEN=64` x 2; Storage=one entry; Written by=dispatch; bypass capture; Read by=`issue_g0`
- ``imm_valid`, `imm_data``：Width / Depth=1 + 64; Storage=one entry; Written by=dispatch; Read by=`issue_g0`
- ``pc`, `inst_bits`, `is_compressed``：Width / Depth=64 + 32 + 1; Storage=one entry; Written by=dispatch; Read by=`issue_g0`
- ``pred_taken`, `pred_target_pc``：Width / Depth=1 + 64; Storage=one entry; Written by=dispatch; Read by=`issue_g0`
- ``self_tag`, `exe_subop`, `full_decode``：Width / Depth=4 + 24 + 17; Storage=one entry; Written by=dispatch; Read by=`issue_g0`
- ``fetch_excp_vld`, `fetch_excp_cause`, `fetch_excp_tval``：Width / Depth=1 + 5 + 64; Storage=one entry; Written by=dispatch; Read by=`issue_g0`

Reset sets every stored header and payload field to zero. Fields are unobservable while `isq_valid=0`.

## Data Path
- ``backend_top.slot_payload[0:1]`, selected by `backend_top.select_payload[G0][s]`` -> ``ISQ_Group0.entry``：`isq_payload_t` capture subset；驱动 `isq_dispatch_g0`；`wr_en = isq_dispatch_g0.fire`
- `completion lane `b`` -> ``entry.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`bypass_capture_X ∧ winner_X[b]`
- `completion lane `b`` -> ``issue_g0.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`issue.fire ∧ ¬entry.X_ready ∧ winner_X[b]`
- `stored G0 fields` -> `selected G0 FU`：`issue_g0_payload_t`；驱动 `entry`；`issue.fire`


## Interface

### In-event

- `isq_dispatch_g0`：Transaction / credit-based；`isq_payload_t`；same-cycle producer fire
- `bypass_publish[b]`：Notify；`{tag:4,data:64}`；same-cycle broadcast
- `flush`：Notify；`∅`；masks all local fires

### In Static Info

- `FU_ready[0:2]`：Static Info；1 bit per requester；combinational

### Out-event

- `issue_g0`:
  - **Kind:** Transaction.
  - **Request:** `issue_valid = issue_request ∧ ¬flush.fire`.
  - **Fire:** `issue_g0.fire = issue_valid ∧ fu_ready_sel`.
  - **Timing:** combinational request; the selected FU samples the payload on fire.
  - **Hold:** while `issue_valid=1` and `fu_ready_sel=0`, the resident entry and all issue fields remain stable.
  - **Cancel:** `flush.fire` masks the request and clears the entry at the clock edge.

  #### Payload Schema: `issue_g0_payload_t`
- ``rs1_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs1_ready ? entry.rs1_data : forward_rs1`
- ``rs2_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs2_ready ? entry.rs2_data : forward_rs2`
- ``FU_Group``：Width / Type=`FU_GROUP_W=2`; Cardinality=one; Generation rule=`entry.fu_group`
- ``imm_valid``：Width / Type=1; Cardinality=one; Generation rule=`entry.imm_valid`
- ``imm_data``：Width / Type=signed `XLEN=64`; Cardinality=one; Generation rule=`entry.imm_data`
- ``pc``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.pc`
- ``inst_bits``：Width / Type=32; Cardinality=one; Generation rule=`entry.inst_bits`
- ``is_compressed``：Width / Type=1; Cardinality=one; Generation rule=`entry.is_compressed`
- ``pred_taken``：Width / Type=1; Cardinality=one; Generation rule=`entry.pred_taken`
- ``pred_target_pc``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.pred_target_pc`
- ``self_tag``：Width / Type=`TAG_W=4`; Cardinality=one; Generation rule=`entry.self_tag`
- ``exe_subop``：Width / Type=`EXE_SUBOP_W=24`; Cardinality=one; Generation rule=`entry.exe_subop`
- ``full_decode``：Width / Type=`FULL_DECODE_W=17`; Cardinality=one; Generation rule=`entry.full_decode`
- ``fetch_excp_vld``：Width / Type=1; Cardinality=one; Generation rule=`entry.fetch_excp_vld`
- ``fetch_excp_cause``：Width / Type=`FETCH_EXCP_CAUSE_W=5`; Cardinality=one; Generation rule=`entry.fetch_excp_cause`
- ``fetch_excp_tval``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.fetch_excp_tval`

  Total width: `472` bits. The payload is continuously driven; only `issue_g0.fire` transfers it.

### Out Static Info

```text
Type: 1 bit
Generation: isq_free_for_dispatch = ¬isq_valid ∨ issue.fire
Validity: combinational every cycle; consumed by `backend_top` credit logic.
```
- `isq_free_for_dispatch`：Static Info；1 bit；combinational same-cycle credit

### Interface Timing

`wr_en = isq_dispatch_g0.fire` and `payload_in = isq_dispatch_g0.payload` are the complete dispatch boundary. There is no second ready signal at this module boundary.






