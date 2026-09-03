# Module `ISQ_Group2`

`ISQ_Group2`：hold one FPU instruction until rs1, rs2, rs3 and the FPU are ready, then issue it。

## Submodule
无。

## FSM
### State
#### Per-entry State

```text
FREE: no FPU instruction is resident.
RESIDENT: one FPU instruction is resident and may wait for any source.
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
   dispatch.fire = isq_dispatch_g2.fire
   wr_en         = dispatch.fire
   payload_in    = isq_dispatch_g2.payload
   ```

2. `dispatch`：见第 1 条 `dispatch`。

3. `issue`：
   ```text
   issue_request = entry_valid ∧ operand_ready
   operand_ready = ∧x∈{1,2,3}: (entry.rsX_ready ∨ fast_ready_X)
   issue_valid   = issue_request ∧ ¬flush.fire
   issue.fire    = issue_valid ∧ FU_ready
   ```

4. `bypass_capture`：
   For `X ∈ {rs1,rs2,rs3}` and `b ∈ {0,1,2,3}`:

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
   bypass_capture = entry_valid ∧ ¬flush.fire ∧ ¬issue.fire
                  ∧ (fast_ready_rs1 ∨ fast_ready_rs2 ∨ fast_ready_rs3)
   bypass_capture_X = entry_valid ∧ ¬flush.fire ∧ ¬issue.fire
                    ∧ ¬entry.X_ready ∧ hit_any_X
   ```

   On `bypass_capture_X`, `entry.X_ready(next)=1` and `entry.X_data(next)=forward_X`; the wait tag is unchanged.

5. `flush`：`flush.fire` 时清除 entry valid；优先级：`reset > flush > dispatch > issue > bypass_capture`。

   Resident dispatch consumes the same-cycle credit `isq_free_for_dispatch = ¬entry_valid ∨ issue.fire`; therefore dispatch+issue reads the old entry and captures the new payload at the edge.

## Data structure
### State

- ``entry_valid``：Width / Depth=1 x 1; Role=state; Reset=0; Update=dispatch -> 1; issue without replacement or flush -> 0

### Header

- ``rs1_ready`, `rs2_ready`, `rs3_ready``：Width / Depth=1 x 3; Consumed by=`operand_ready`, `fast_ready_X`; Update=dispatch capture; matching bypass capture -> 1
- ``rs1_wait_tag`, `rs2_wait_tag`, `rs3_wait_tag``：Width / Depth=`TAG_W=4` x 3; Consumed by=`hit_X[b]`; Update=dispatch capture; unchanged afterward

### Payload

- ``rs1_data`, `rs2_data`, `rs3_data``：Width / Depth=64 x 3; Storage=one entry; Written by=dispatch; bypass capture; Read by=`issue_g2`
- ``self_tag``：Width / Depth=4; Storage=one entry; Written by=dispatch; Read by=`issue_g2`
- ``exe_subop``：Width / Depth=24; Storage=one entry; Written by=dispatch; Read by=`issue_g2`
- ``full_decode``：Width / Depth=17; Storage=one entry; Written by=dispatch; Read by=`issue_g2`

Reset sets all stored fields to zero; fields are unobservable while `entry_valid=0`.

## Data Path
- ``backend_top.slot_payload[0:1]`, selected by `backend_top.select_payload[G2][s]`` -> ``ISQ_Group2.entry``：`isq_payload_t` capture subset；驱动 `isq_dispatch_g2`；`wr_en = isq_dispatch_g2.fire`
- `completion lane `b`` -> ``entry.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`bypass_capture_X ∧ winner_X[b]`
- `completion lane `b`` -> ``issue_g2.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`issue.fire ∧ ¬entry.X_ready ∧ winner_X[b]`
- `stored entry fields` -> ``fpu_simple``：`issue_g2_payload_t`；驱动 `entry`；`issue.fire`

## Interface

### In-event

- `isq_dispatch_g2`：Transaction / credit-based；`isq_payload_t`；same-cycle fire
- `bypass_publish[b]`：Notify；`{tag:4,data:64}`；same-cycle broadcast
- `flush`：Notify；`∅`；masks local fires

### In Static Info

- `FU_ready`：Static Info；1 bit；combinational

### Out-event

- `issue_g2`:
  - **Request:** `issue_valid = issue_request ∧ ¬flush.fire`.
  - **Fire:** `issue_g2.fire = issue_valid ∧ FU_ready`.
  - **Timing:** combinational request; `fpu_simple` samples on fire.
  - **Hold:** the entry and non-forwarded fields stay stable while `FU_ready=0`.
  - **Cancel:** flush masks the request and invalidates the entry.

  #### Payload Schema: `issue_g2_payload_t`
- ``rs1_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs1_ready ? entry.rs1_data : forward_rs1`
- ``rs2_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs2_ready ? entry.rs2_data : forward_rs2`
- ``rs3_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs3_ready ? entry.rs3_data : forward_rs3`
- ``self_tag``：Width / Type=`TAG_W=4`; Cardinality=one; Generation rule=`entry.self_tag`
- ``exe_subop``：Width / Type=`EXE_SUBOP_W=24`; Cardinality=one; Generation rule=`entry.exe_subop`
- ``full_decode``：Width / Type=`FULL_DECODE_W=17`; Cardinality=one; Generation rule=`entry.full_decode`

  Total width: `237` bits. `full_decode.rm` is the effective rounding mode selected before dispatch and is held in the entry.

### Out Static Info

```text
Type: 1 bit
Generation: isq_free_for_dispatch = ¬entry_valid ∨ issue.fire
Validity: combinational every cycle; consumed as G2 credit.
```
- `isq_free_for_dispatch`：Static Info；1 bit；combinational credit

### Interface Timing

- 无。






