# Module `csr_unit`

`csr_unit`：execute G0 CSR operations and publish a completion plus CSR sideband。

## Submodule
无。

## FSM
### State
#### Per-entry State
```text
IDLE: no completion is held.
HOLD: one completion and sideband wait for winner_grant.
Reset State: IDLE.
```

### State Transition & Condition Name
1. `IDLE -> HOLD`：`accept`
2. `HOLD -> IDLE`：`winner_grant`
3. `HOLD -> HOLD`：`no grant`
4. `ANY -> IDLE`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `accept`：
   accept = issue_valid ∧ fu_selected ∧ FU_ready ∧ ¬flush.fire

2. `winner_grant`：
   见本模块条件逻辑。

3. `no grant`：
   见本模块条件逻辑。

4. `flush`：
   见本模块条件逻辑。

## Data structure
### State

- ``busy_q``：Width=1; Role=hold state; Reset=0; Update=accept -> 1; winner/flush -> 0

### Header

- ``tag_q``：Width=4; Consumed by=completion tag; Update=accept
- ``csr_addr_q``：Width=12; Consumed by=sideband; Update=accept

### Payload

`result_data_q[63:0]`, exception fields, `csr_wdata_q[63:0]`, and sideband valid/write fields are one-entry output payload registers. Reset and flush clear all fields.

## Data Path
- `G0 issue payload + csr_rdata` -> `CSR datapath`：operation inputs；驱动 `issue`；accept
- `result/exception/sideband` -> `output registers`：completion schemas；驱动 CSR datapath；accept edge
- `output registers` -> `p3_arbiter_G0`：common + sideband；驱动 `completion_request`；request_valid
- `full_decode.csr_addr` -> `SIH read port`：12-bit address；驱动 `csr_read`；combinational

## Interface

### In-event

- `issue`：Transaction；G0 issue payload；accept when addressed and ready
- `flush`：Notify；`∅`；clears in-flight state

### In Static Info

- `csr_rdata`：Static Info；64-bit old CSR value；combinational
- `current_priv`, `mstatus_tvm`, `fs_enabled`：Static Info；control bits；combinational
- `winner_grant`, `loser_hold`：arbitration feedback；1 bit each；same-cycle

### Out-event

- `completion_request`:
  The output register is written on `accept` and held until `winner_grant`.
- ``result_valid``：Width / Type=1; Generation rule=`request_valid`
- ``tag_out``：Width / Type=`TAG_W=4`; Generation rule=issue self_tag
- ``result_data``：Width / Type=`XLEN=64`; Generation rule=csr_rdata
- ``mispredict_flag`, `mispredict_target_pc``：Width / Type=1 + 64; Generation rule=zero
- ``exception_flag``：Width / Type=1; Generation rule=`¬legal_csr_addr`
- ``exception_cause``：Width / Type=`EXCP_CAUSE_W=63`; Generation rule=2 when illegal, else zero
- ``exception_tval``：Width / Type=64; Generation rule=raw inst_bits when illegal, else zero
- ``is_mret`, `is_sret``：Width / Type=1 each; Generation rule=zero
- ``fpu_fflags``：Width / Type=5; Generation rule=zero

  `csr_sideband_t = {is_csr, csr_write_enable, csr_addr[11:0], csr_wdata[63:0]}` with `is_csr=1` and `csr_write_enable = csr_write_en ∧ csr_write_intent ∧ legal_csr_addr`.

### Out Static Info

`csr_addr = full_decode.csr_addr`, continuously driven with no fire.
- `csr_read`：Static Info；12-bit address；combinational
- `FU_ready`：Static Info；1 bit；combinational

### Interface Timing

- 无。


