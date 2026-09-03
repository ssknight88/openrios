# Module `g3_lsu_iface`

`g3_lsu_iface`：bridge ISQ_Group3 to the LSU boundary and convert LSU terminal channels to lane-3 completion and bypass。

## Submodule
无。

## FSM
### State
#### Per-entry State
Per tag (`ROB_DEPTH=16`):

```text
req_in_flight[tag]: request accepted by LSU and not terminal.
wakeup_held[tag]: untagged wakeup authorization held before issue.
read_done[tag]: normal read-side result received.
store_done[tag]: store-side completion received.
held_data[tag]: normal read result storage.
```

### State Transition & Condition Name
- State=`req_in_flight[tag]=0`; Condition=`issue_accept(tag)`; Action=set in-flight
- State=`req_in_flight[tag]=1`; Condition=`terminal(tag)`; Action=clear in-flight
- State=`wakeup_held[tag]=0`; Condition=`wakeup_hold_set(tag)`; Action=set held authorization
- State=`wakeup_held[tag]=1`; Condition=`issue_accept(tag)`; Action=consume held authorization
- State=`read_done[tag]=0`; Condition=`done ∧ lsu_bypass`; Action=set read done and data
- State=`store_done[tag]=0`; Condition=`done`; Action=set store done
- State=`ANY`; Condition=`flush`; Action=clear vectors and held data

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `Issue assembly and handshake`：
   ```text
   req_property = req_property_from_subop(exe_subop)
   be_lsu_issue_pld = {self_tag, req_property, exe_subop, mem_funct3, rd_is_fp,
                       rs1_data, rs2_data, imm_valid, imm_data,
                       is_store, st_br_resolve ∧ req_property.is_store}
   bridge_has_room = ¬req_in_flight[self_tag]
   FU_ready = bridge_has_room ∧ lsu_be_issue_ready
   be_lsu_issue_valid = issue_valid ∧ bridge_has_room ∧ ¬flush.fire
   issue_accept = be_lsu_issue_valid ∧ lsu_be_issue_ready
   ```

   The issue payload is continuously presented because LSU ready is derived from its request class.

2. `Wakeup relay`：
   ```text
   wakeup_in = store_wakeup.fire ∧ rst_n ∧ ¬flush.fire
   wakeup_accept = wakeup_in ∧ ¬(∨tag: wakeup_held[tag])
   wakeup_consumed_at_issue = issue_accept ∧ (self_tag == store_wakeup.tag)
   wakeup_target_present = req_in_flight[store_wakeup.tag] ∨ wakeup_consumed_at_issue
   wakeup_relay_now = wakeup_accept ∧ wakeup_target_present
   wakeup_relay_held = issue_accept ∧ wakeup_held[self_tag]
   wakeup_hold_set = wakeup_accept ∧ ¬wakeup_target_present
   store_wakeup_relay.fire = wakeup_relay_now ∨ wakeup_relay_held
   ```

3. `Terminal merge`：
   ```text
   done_in = lsu_done.fire ∧ ¬flush.fire
   exc_in = lsu_exception.fire ∧ ¬flush.fire
   read_side = lsu_bypass.fire ∧ ¬flush.fire
   terminal = done_in ∨ exc_in
   terminal_tag = exc_in ? lsu_exception.tag : lsu_done.tag
   read_done_next = read_done[done_tag] ∨ (done_in ∧ read_side)
   store_done_next = store_done[done_tag] ∨ done_in
   result_valid = (done_in ∧ (read_done_next ∨ store_done_next)) ∨ exc_in
   ```

## Data structure
### State

- ``req_in_flight``：Width / Depth=1 x 16; Reset=zero; Update=issue set; terminal clear
- ``wakeup_held``：Width / Depth=1 x 16; Reset=zero; Update=wakeup hold set; issue clear
- ``read_done``：Width / Depth=1 x 16; Reset=zero; Update=done+bypass set
- ``store_done``：Width / Depth=1 x 16; Reset=zero; Update=done set

### Header

No persistent request header. Issue fields are carried by `issue_g3`.

### Payload

- ``held_data[tag]``：Width / Depth=64 x 16; Storage=per-tag; Written by=normal done+bypass; Read by=lane-3 completion/bypass

## Data Path
- `ISQ_Group3` -> `LSU issue boundary`：`be_lsu_issue_pld_t`；驱动 `issue_g3`；`issue_accept`
- `SCB` -> `wakeup state / LSU`：tag；驱动 `store_wakeup`；wakeup accept/relay
- `LSU` -> `terminal state`：tag/data；驱动 `lsu_done`；`done_in`
- `LSU` -> `lane 3`：tag/cause/tval；驱动 `lsu_exception`；`exc_in`
- `LSU` -> `held data/lane 3`：tag/data；驱动 `lsu_bypass`；`read_side`

## Interface

### In-event

- `issue_g3`：Transaction；`issue_g3_payload_t`；request stable until bridge fire
- `store_wakeup`：Notify；4-bit tag；one-cycle pulse
- `LSU ready/done/exception/bypass`：Static/Transaction；LSU schemas；external protocol timing
- `flush`：Notify；`∅`；clears all state

### In Static Info

- `st_br_resolve`：Static Info；1 bit；current tag

### Out-event

- `lsu_issue`:
  `lsu_issue.fire = issue_accept`.
- ``self_tag``：Width / Type=4; Generation rule=issue `self_tag`
- ``req_property``：Width / Type=LSU property schema; Generation rule=function of `exe_subop`
- ``exe_subop``：Width / Type=24; Generation rule=issue payload
- ``mem_funct3``：Width / Type=3; Generation rule=issue payload
- ``rd_is_fp``：Width / Type=1; Generation rule=issue payload
- ``rs1_data`, `rs2_data``：Width / Type=64 each; Generation rule=issue payload
- ``imm_valid`, `imm_data``：Width / Type=1 + 64; Generation rule=issue payload
- ``is_store``：Width / Type=1; Generation rule=issue payload
- ``st_br_resolve``：Width / Type=1; Generation rule=`st_br_resolve ∧ req_property.is_store`
- `completion_g3`:
  ```text
  Result_valid = result_valid
  tag_out = terminal_tag
  result_data = read_side ? held_data_rd : 0
  exception_flag = exc_in
  exception_cause = exc_in ? zero_extend(lsu_exception.cause) : 0
  exception_tval = exc_in ? lsu_exception.tval : 0
  mispredict_flag = 0; mispredict_target_pc = 0
  is_mret = 0; is_sret = 0; fpu_fflags = 0
  ```
- `bypass_publish_g3`:
  ```text
  bypass_publish_g3.fire = Result_valid ∧ read_side ∧ ¬exception_flag
  bypass_publish_g3.tag = done_tag
  bypass_publish_g3.data = held_data_rd
  ```
- `store_wakeup_relay`：Notify；`∅`；immediate/held relay

### Out Static Info

```text
FU_ready = bridge_has_room ∧ lsu_be_issue_ready
be_lsu_entry_ready = rst_n ∧ ¬flush.fire
```
- `FU_ready`：Static Info；1 bit；bridge room ∧ LSU ready

### Interface Timing

- 无。


