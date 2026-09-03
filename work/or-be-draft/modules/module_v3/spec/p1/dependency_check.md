# Module `dependency_check`

The single P1 producer of operand readiness, wait tags, and source-select codes. It also derives allocation tags and the dispatch guard projections. It stores no state and does not perform data selection itself.

## Submodule
无。

## FSM
### State
#### Per-entry State
无。

### State Transition & Condition Name
无。

没有 Event fire 时状态保持。

### Detailed Condition Description
无。

## Data structure
### State
No state, header, or payload storage. `source_kind`, `producer_tag`, match vectors, and select vectors are combinational views.

### Header
无。

### Payload
无。

## Data Path
- `Buffer_tail` + slot index -> `self_tag[0:1]`：4 x 2；驱动 allocation tag
- INT/FP tag maps -> `producer_tag`, `arf_ready`：tag 4, busy 1；驱动 map query
- commit/bypass tags -> onehot source select：2 + 4 lanes；驱动 completion query
- predicates above -> `rsX_ready/wait_tag/select`：1 + 4 + 7 per source；驱动 source chain
- `scoreboard_valid/done` -> `slot_missed_wakeup[0:1]`：2；驱动 wakeup check

## Interface

### In-event

- 无。

### In Static Info

- `inst_valid[1:0]`：combinational
- `rd_idx[0:1]`：combinational
- `rd_is_fp/use_rd[0:1]`：combinational
- `is_serial/is_fp_instruction[0:1]`：combinational
- `use_rs1/use_rs2/use_rs3[0:1]`：combinational
- `rs1_idx/rs2_idx/rs3_idx[0:1]`：combinational
- `rs1_is_fp/rs2_is_fp/rs3_is_fp[0:1]`：combinational
- `Buffer_tail`：combinational
- `INT_tag_mapping_tag/busy[0:1][1:2]`：combinational
- `FP_tag_mapping_tag/busy[1:3]`：combinational
- `scoreboard_valid_bits`, `scoreboard_exec_done_bits`：combinational
- `commit_valid[0:1]`, `commit_tag[0:1]`：combinational
- `bypass_valid[0:3]`, `bypass_tag[0:3]`：combinational

### Out-event

- 无。

### Out Static Info

- **4.1 Allocation and slot projections**
```text
self_tag[s]        = Buffer_tail + TAG_W'(s)       // modulo 16
rd_write_enable[s] = use_rd[s] &&
                     !((rd_idx[s] == 0) && !rd_is_fp[s])
slot0_present      = inst_valid[0]
slot1_present      = inst_valid[1]
serial0            = is_serial[0]
serial_inst        = is_serial[0] || is_serial[1]
fp0                = is_fp_instruction[0]
fp1                = is_fp_instruction[1]
```
These projections are intentionally not gated by `inst_valid` except for the presence bits.

- **4.2 Slot-0-to-slot-1 RAW overlay**
For source number `x=1,2,3`:
```text
slot1_dep_hit[x] = slot0_present && rd_write_enable[0] &&
                   use_rs[1][x] &&
                   (rs_idx[1][x] == rd_idx[0]) &&
                   (rs_is_fp[1][x] == rd_is_fp[0])
```
This detects only same-cycle slot0 producer -> slot1 consumer RAW. It does not model WAR/WAW.

- **4.3 Source query**
```text
if x <= INT_SRC_PER_SLOT:
    int_tag[s][x]  = INT_tag_mapping_tag[s][x]
    int_busy[s][x] = INT_tag_mapping_busy[s][x]
else:
    int_tag[s][x]  = 0
    int_busy[s][x] = 1                 // no INT rs3 port
take_fp[s][x]    = rs_is_fp[s][x] || (x > INT_SRC_PER_SLOT)
producer_tag[s][x] = take_fp[s][x] ? FP_tag_mapping_tag[x] : int_tag[s][x]
arf_ready[s][x]    = take_fp[s][x] ? !FP_tag_mapping_busy[x] : !int_busy[s][x]
```
For `x=3`, the forced busy value makes a violated `rs3_is_fp` contract wait rather than read a nonexistent INT port.

- **4.4 Completion and bypass matches**
For each `(s,x)`, initialize match vectors to zero. Scan commit lanes `c=0,1` in ascending order; the first valid lane with `commit_tag[c] == producer_tag[s][x]` sets `commit_match=1` and onehot `commit_lane[c]=1`. Scan bypass lanes `b=0..3` similarly to set `bypass_match` and `bypass_lane[b]`.

- **4.5 Six-row first-hit chain**
For every slot `s` and source `x`, evaluate exactly this priority:
1. `WAIT_OVERLAY`: `s==1 && slot1_dep_hit[x]`; `ready=0`, `wait_tag=self_tag[0]`, `select=0`.
2. `NONE`: `!use_rs[s][x]`; `ready=1`, `wait_tag=0`, `select=0`.
3. `ARF`: `arf_ready[s][x]`; `ready=1`, `wait_tag=producer_tag[s][x]`, `select[6]=1`.
4. `COMMIT`: `commit_match[s][x]`; `ready=1`, `wait_tag=producer_tag[s][x]`, `select[5:4]=commit_lane[s][x]`.
5. `BYPASS`: `bypass_match[s][x]`; `ready=1`, `wait_tag=producer_tag[s][x]`, `select[3:0]=bypass_lane[s][x]`.
6. `WAIT_PRODUCER`: otherwise; `ready=0`, `wait_tag=producer_tag[s][x]`, `select=0`.

`rs_data_sel_t` is onehot0 with bit layout `{sel_arf,sel_commit[1:0],sel_bypass[3:0]}`. `rsX_ready`, `rsX_wait_tag`, and `rs_data_sel_t` have shape `[ISSUE_WIDTH][1:FP_READ_PORTS]` (2 x 3), with `x=1,2` also driving the INT read arrays.

- **4.6 Missed wakeup**
```text
slot_missed_wakeup[s] =
    OR over x=1..3 of
      (source_kind[s][x] == WAIT_PRODUCER) &&
      scoreboard_valid_bits[rsX_wait_tag[s][x]] &&
      scoreboard_exec_done_bits[rsX_wait_tag[s][x]]
```
Only row 6 is checked. Overlay waits on a not-yet-allocated tag; rows 3-5 are already ready.
- `self_tag[0:1]`：combinational
- `rd_write_enable[0:1]`：combinational
- `slot0_present/slot1_present/serial0/serial_inst/fp0/fp1`：combinational
- `slot_missed_wakeup[0:1]`：combinational
- `rsX_ready[0:1][1:3]`：combinational
- `rsX_wait_tag[0:1][1:3]`：combinational
- `rs_data_sel_t[0:1][1:3]`：combinational

### Interface Timing

- 无。


