# Module `ISQ_Group1`

`ISQ_Group1`：hold one ALU1 or MUL instruction until both operands and the selected FU are ready, then issue it。

## Submodule
无。

## FSM
### State
#### Per-entry State

```text
FREE: no instruction is resident.
RESIDENT: one ALU1/MUL instruction is resident and may wait for bypass.
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
   dispatch.fire = isq_dispatch_g1.fire
   wr_en         = dispatch.fire
   payload_in    = isq_dispatch_g1.payload
   ```

   The complete two-slot selection, credit, and payload relation is defined by `backend_top` composition Output.

2. `dispatch`：见第 1 条 `dispatch`。

3. `issue`：
   ```text
   issue_request = isq_valid ∧ operand_ready
   operand_ready = (entry.rs1_ready ∨ fast_ready_rs1)
                ∧ (entry.rs2_ready ∨ fast_ready_rs2)
   fu_ready_sel  = (entry.fu_group == 0) ? FU_ready[0] : FU_ready[1]
   issue_valid   = issue_request ∧ ¬flush.fire
   issue.fire    = issue_valid ∧ fu_ready_sel
   ```

   `entry.fu_group` domain is `{0=ALU1, 1=MUL}`. Dispatch guarantees this domain.

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

   On `bypass_capture_X`, `entry.X_ready(next)=1`, `entry.X_data(next)=forward_X`, and `entry.X_wait_tag` is unchanged.

5. `flush`：`flush.fire` 时清除 entry valid；优先级：`reset > flush > dispatch > issue > bypass_capture`。

   For a resident entry, dispatch fire implies issue fire through `isq_free_for_dispatch = ¬isq_valid ∨ issue.fire`; issue reads `entry(t)`, while replacement dispatch is captured into `entry(t+1)`.

## Data structure
### State

- ``isq_valid``：Width / Depth=1 x 1; Role=state; Reset=0; Update=dispatch -> 1; issue without replacement or flush -> 0

### Header

- ``rs1_ready`, `rs2_ready``：Width / Depth=1 x 2; Consumed by=`operand_ready`, `fast_ready_X`; Update=dispatch capture; bypass capture -> 1
- ``rs1_wait_tag`, `rs2_wait_tag``：Width / Depth=`TAG_W=4` x 2; Consumed by=`hit_X[b]`; Update=dispatch capture; unchanged afterward
- ``fu_group``：Width / Depth=`FU_GROUP_W=2`; Consumed by=`fu_ready_sel`; Update=dispatch capture; replacement dispatch overwrites

### Payload

- ``rs1_data`, `rs2_data``：Width / Depth=64 x 2; Storage=one entry; Written by=dispatch; bypass capture; Read by=`issue_g1`
- ``imm_valid`, `imm_data``：Width / Depth=1 + 64; Storage=one entry; Written by=dispatch; Read by=`issue_g1`
- ``self_tag`, `exe_subop``：Width / Depth=4 + 24; Storage=one entry; Written by=dispatch; Read by=`issue_g1`

Reset sets all header and payload fields to zero; fields are unobservable while `isq_valid=0`.

## Data Path
- ``backend_top.slot_payload[0:1]`, selected by `backend_top.select_payload[G1][s]`` -> ``ISQ_Group1.entry``：`isq_payload_t` capture subset；驱动 `isq_dispatch_g1`；`wr_en = isq_dispatch_g1.fire`
- `completion lane `b`` -> ``entry.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`bypass_capture_X ∧ winner_X[b]`
- `completion lane `b`` -> ``issue_g1.X_data``：`{tag:4,data:64}`；驱动 `bypass_publish[b]`；`issue.fire ∧ ¬entry.X_ready ∧ winner_X[b]`
- `stored entry fields` -> `selected G1 FU`：`issue_g1_payload_t`；驱动 `entry`；`issue.fire`



## Interface

### In-event

- `isq_dispatch_g1`：Transaction / credit-based；`isq_payload_t`；same-cycle fire
- `bypass_publish[b]`：Notify；`{tag:4,data:64}`；same-cycle broadcast
- `flush`：Notify；`∅`；masks local fires

### In Static Info

- `FU_ready[0:1]`：Static Info；1 bit per FU；combinational

### Out-event

- `issue_g1`:
  - **Request:** `issue_valid = issue_request ∧ ¬flush.fire`.
  - **Fire:** `issue_g1.fire = issue_valid ∧ fu_ready_sel`.
  - **Timing:** combinational request; selected FU samples on fire.
  - **Hold:** entry and payload remain stable while selected FU is not ready.
  - **Cancel:** flush masks the request and invalidates the entry.

  #### Payload Schema: `issue_g1_payload_t`
- ``rs1_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs1_ready ? entry.rs1_data : forward_rs1`
- ``rs2_data``：Width / Type=`XLEN=64`; Cardinality=one; Generation rule=`entry.rs2_ready ? entry.rs2_data : forward_rs2`
- ``FU_Group``：Width / Type=`FU_GROUP_W=2`; Cardinality=one; Generation rule=`entry.fu_group`
- ``imm_valid``：Width / Type=1; Cardinality=one; Generation rule=`entry.imm_valid`
- ``imm_data``：Width / Type=signed `XLEN=64`; Cardinality=one; Generation rule=`entry.imm_data`
- ``self_tag``：Width / Type=`TAG_W=4`; Cardinality=one; Generation rule=`entry.self_tag`
- ``exe_subop``：Width / Type=`EXE_SUBOP_W=24`; Cardinality=one; Generation rule=`entry.exe_subop`

  Total width: `223` bits. Payload is continuously driven; only `issue_g1.fire` transfers it.

### Out Static Info

```text
Type: 1 bit
Generation: isq_free_for_dispatch = ¬isq_valid ∨ issue.fire
Validity: combinational every cycle; consumed as G1 credit.
```
- `isq_free_for_dispatch`：Static Info；1 bit；combinational credit

### Interface Timing

- 无。







