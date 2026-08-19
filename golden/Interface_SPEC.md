# Interface Specification: Dual-Issue OoO Backend Signals

This document is the signal-level companion to `DEFINITIVE_SPEC.md`. It focuses on port widths, payload fields, control signals, and the exact RTL-facing contracts needed to implement the backend without guessing.

## Part I: P1 Stage Addressing & Read Interface

P1 is a combinational rename/dispatch block between `ISB_reg` and the per-group ISQ state.

### 1. Physical Register File Interface

P1 reads these structures asynchronously:

- `INT_DST_REG` (32x5b): `busy + 4-bit tag`, **4R2W**
- `FP_DST_REG` (32x5b): `busy + 4-bit tag`, **3R1W**
- `INT_ARF` (32x64b): 4R2W
- `FP_ARF` (32x64b): 3R1W

Notes:
- `INT_DST_REG` supports two same-cycle destination writes.
- `FP_DST_REG` supports only one same-cycle destination write, so at most one FP-destination instruction may be accepted per cycle.
- `rd_idx == 0` is architecturally x0 and must not create a rename mapping.

### 1A. `DST_REG` Same-Cycle Write Priority

For the same logical destination entry in the same cycle, the effective persistent next-state priority is:

1. same-cycle `P1` allocation write `{busy=1, tag=new_tag}`
2. same-cycle `P4` tag-matched commit clear `{busy=0}`
3. `Global_Flush_Late` bulk `Clear_All_Busy`, after alloc-side writes have already been squashed

Rules:
- a younger same-cycle allocation write supersedes an older producer's commit-clear
- commit-clear is meaningful only when no younger allocation targets the same entry
- when `Global_Flush_Late == 1`, alloc-side writes are squashed, so the flush clear becomes the effective state transition

### 2. Addressing & Steering Logic

P1 selects the register file by `rsX_is_fp`.

```verilog
assign INT_DST_REG_Raddr_0 = rs1_idx;
assign FP_DST_REG_Raddr_0  = rs1_idx;
assign INT_ARF_Raddr_0     = rs1_idx;
assign FP_ARF_Raddr_0      = rs1_idx;

wire current_rs1_busy;
wire [3:0] current_rs1_tag;
wire [63:0] current_rs1_arf_data;

assign current_rs1_busy     = rs1_is_fp ? FP_DST_REG_Rdata_0.busy : INT_DST_REG_Rdata_0.busy;
assign current_rs1_tag      = rs1_is_fp ? FP_DST_REG_Rdata_0.tag  : INT_DST_REG_Rdata_0.tag;
assign current_rs1_arf_data = rs1_is_fp ? FP_ARF_Rdata_0.data : INT_ARF_Rdata_0.data;

wire rs1_ready = ~current_rs1_busy;
wire [63:0] payload_rs1_data = rs1_ready ? current_rs1_arf_data : 64'h0;
wire [3:0] payload_rs1_wait_tag = rs1_ready ? 4'h0 : current_rs1_tag;
```

### 3. Same-Cycle Rename Overlay

Slot0 is resolved first. If slot0 is accepted and has a real destination, P1 forms a transient overlay:

```text
slot0_overlay = {
    valid,
    rd_idx,
    rd_is_fp,
    tag = ROB_tail
}
```

Slot1 source lookup checks this overlay before consulting the persistent `DST_REG` state.

Consequences:
- same-bundle RAW uses `slot0.self_rob_tag`
- same-bundle WAW updates the persistent rename state to the younger `slot1` tag

### 4. Same-Cycle Commit Overlay

P1 source resolution must also observe normal same-cycle P4 commits through an explicit overlay path rather than relying on ARF/DST_REG macro read-after-write semantics.

Effective match condition (per source operand):

```text
commit_overlay_match =
    commit_valid[k] &&
    (rsX_idx   == commit_payload[k].rd_idx) &&
    (rsX_is_fp == commit_payload[k].rd_is_fp) &&
    !(rsX_idx == 0 && !rsX_is_fp)
```

Behavior:
- if a source matches a same-cycle committed destination, resolve it as ready
- source data comes from `commit_payload[k].result_data`
- `rs_wait_tag = 0`

Priority:
1. for `slot1`, the same-cycle `slot0` rename overlay has highest priority
2. then same-cycle normal P4 commit overlay
3. then persistent `DST_REG/ARF` state

If both `head0` and `head1` commit in the same cycle and both match the same source, the effective overlay source is the younger `head1` commit result.

### 4A. Global Flush vs Allocation Priority

When `Global_Flush_Late = 1` in a cycle, all same-cycle `P1` alloc-side writes are squashed:

- `ROB_tail` does not advance from allocation
- `DST_REG` allocation writes are gated off
- `ROB_MetaArray[self_rob_tag]` allocation initialization writes are gated off
- `ISQ` payload writes are gated off
- `isb_dequeue` is gated off
- `csr_inflight_valid` must not be newly set by that cycle's P1 acceptance attempt

This rule defines a single precise recovery boundary and prevents same-cycle flush/alloc races from depending on implementation ordering.

---

## Part II: Pipeline Interface Specification

### 1. P0 -> P1: `ISB_Payload` (per slot)

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `inst_valid` | 1 | ISB / frontend | P1 DSP | Marks whether this slot participates in rename, stall check, ROB allocation, and ISQ admission. |
| `pc` | 64 | ISB / frontend | P1 DSP, ROB_MetaArray alloc-init | Original instruction PC. Used at P1 allocation to initialize `ROB_MetaArray[self_rob_tag].inst_pc`. |
| `exe_type` | 2 | decode / frontend | P0 admission logic, P1 DSP | Selects the destination execution group and therefore the target single-entry ISQ. |
| `exe_subop` | 6 | decode / frontend | FU datapath | Group-local operation control word consumed by the selected FU. Interpreted only after `exe_type` selects the execution group. |
| `is_csr` | 1 | decode / frontend | P1 CSR quiesce logic | Marks that this instruction is a CSR op and must participate in the quiescent CSR dispatch rule. |
| `rd_idx` | 5 | decode / frontend | P1 rename, P4 commit | Logical destination register index. `rd_idx==0` means x0 for the integer file and must not create a rename mapping. |
| `rs1_idx` | 5 | decode / frontend | P1 DST_REG/ARF read ports | Logical source 1 address used to probe rename state and, if ready, ARF data. |
| `rs2_idx` | 5 | decode / frontend | P1 DST_REG/ARF read ports | Logical source 2 address used to probe rename state and, if ready, ARF data. |
| `rs3_idx` | 5 | decode / frontend | P1 DST_REG/ARF read ports | Logical source 3 address, primarily for FMA-class operations. |
| `use_rd` | 1 | decode / frontend | P1 DSP | Enables destination rename/ROB metadata generation. If 0, no destination mapping is written. |
| `use_rs1` | 1 | decode / frontend | P1 DSP | If 0, source 1 bypasses rename/ARF lookup and is treated as ready. |
| `use_rs2` | 1 | decode / frontend | P1 DSP | If 0, source 2 bypasses rename/ARF lookup and is treated as ready. |
| `use_rs3` | 1 | decode / frontend | P1 DSP | If 0, source 3 bypasses rename/ARF lookup and is treated as ready. |
| `rd_is_fp` | 1 | decode / frontend | P1 rename, P4 commit | Selects whether the destination belongs to INT or FP architectural state. Also participates in the FP 1-write dispatch restriction. |
| `rs1_is_fp` | 1 | decode / frontend | P1 read steering | Selects INT vs FP DST_REG and ARF lookup for source 1. |
| `rs2_is_fp` | 1 | decode / frontend | P1 read steering | Selects INT vs FP DST_REG and ARF lookup for source 2. |
| `rs3_is_fp` | 1 | decode / frontend | P1 read steering | Selects INT vs FP DST_REG and ARF lookup for source 3. |
| `imm_valid` | 1 | decode / frontend | P1/P2 datapath assembly | Indicates that the immediate path is live for this instruction. |
| `imm_data` | 64 | decode / frontend | P1/P2 datapath assembly | Sign-extended immediate value forwarded into the FU operand/control path. |
| `pred_taken` | 1 | BPU | P1/P2 branch context | Predicted branch direction carried with the instruction until BRU resolution. |
| `pred_target_pc` | 64 | BPU | P1/P2 branch context | Predicted branch target carried so BRU can compare against actual control-flow outcome. |

Rules:
- `slot0` always evaluates first.
- `slot1` may not bypass a blocked `slot0`.
- `slot1` may not dispatch if it would require a second FP destination write in the same cycle.
- a CSR may dispatch only from `slot0` and only when the ROB is empty at the start of the P1 decision
- if `slot0` is accepted as CSR, `slot1` must be blocked regardless of `slot1` type
- after a CSR has been accepted, no younger instruction may dispatch until that CSR commits or flushes

### 2. P1 -> P2: `ISQ_Payload` (per entry, per group)

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `isq_valid` | 1 | P1 DSP | ISQ entry state | Owns occupancy of the single-entry ISQ. Cleared on issue or synchronous flush. |
| `self_rob_tag` | 4 | ROB allocator via P1 | FU, ROB, bypass, P4 | Global physical identity of the instruction. Used for writeback, wakeup, and precise commit order. |
| `exe_subop` | 6 | ISB_reg | FU local decode | Selects the specific operation inside the chosen execution group. After issue grant, this field is decoded into mutually exclusive FU-local enable signals. The same numeric value may legally mean different things in different groups. |
| `rs1_ready` | 1 | P1 DST_REG logic | ISQ select | Static dispatch-time ready bit. If 1, source 1 data already came from ARF at dispatch. |
| `rs2_ready` | 1 | P1 DST_REG logic | ISQ select | Static dispatch-time ready bit for source 2. |
| `rs3_ready` | 1 | P1 DST_REG logic | ISQ select | Static dispatch-time ready bit for source 3. |
| `rs1_data` | 64 | ARF at dispatch or `64'h0` | FU input MUX | Holds real ARF data when `rs1_ready=1`; otherwise placeholder data that must be ignored in favor of bypass. |
| `rs2_data` | 64 | ARF at dispatch or `64'h0` | FU input MUX | Holds real ARF data when `rs2_ready=1`; otherwise placeholder data. |
| `rs3_data` | 64 | ARF at dispatch or `64'h0` | FU input MUX | Holds real ARF data when `rs3_ready=1`; otherwise placeholder data. |
| `rs1_wait_tag` | 4 | DST_REG tag or slot0 overlay tag | bypass compare, P1 stall protection | Producer tag compared against all bypass lanes. Used for wakeup and late-dispatch stall detection. |
| `rs2_wait_tag` | 4 | DST_REG tag or slot0 overlay tag | bypass compare, P1 stall protection | Producer tag for source 2. |
| `rs3_wait_tag` | 4 | DST_REG tag or slot0 overlay tag | bypass compare, P1 stall protection | Producer tag for source 3. |
| `pc` | 64 | ISB_reg | Group 0 AUIPC/BRU fast path | Original instruction PC kept only for Group 0 execution paths that compute `pc+imm` or `pc+4`. Non-Group0 execution paths do not consume a live PC. |
| `pred_taken` | 1 | ISB_reg | Group 0 BRU | Prediction context bit used for mispredict detection. Non-Group0 payload writes may tie this low. |
| `pred_target_pc` | 64 | ISB_reg | Group 0 BRU | Prediction target used to compare predicted vs actual target in the BRU. Non-Group0 payload writes may tie this to zero. |
| `is_store` | 1 | decode / LSU path | Group 3 LSU control | Marks that this LSU entry is a Store and must obey conservative store-visibility rules. |
| `store_data` | 64 | decode / register path | Group 3 LSU / L1D request path | Store write data forwarded toward the L1D request interface. |
| `store_mask` | 8 | decode / LSU path | Group 3 LSU / L1D request path | Byte-lane enable mask for partial stores. |
| `store_size` | 3 | decode / LSU path | Group 3 LSU / L1D request path | Encodes store width for alignment and L1D-side control. |

ISQ select rule:
- issue only when `operand_ready && !selected_fu_busy && !Global_Flush_Late`
- `rs_ready` is static from dispatch time
- wakeup is via combinational bypass compare

Selected-FU rule:
- `exe_type` selects the execution group and therefore the ISQ.
- `exe_subop` is then decoded locally inside that group to select the exact FU.
- `exe_subop` is a 6-bit group-local field, not a globally unique backend op code.
- `selected_fu_busy` must come from that decoded FU, not from a coarse group-level busy bit.

Required local decode contract:
```text
Group 0:
    exe_subop in GroupShared_ALU_set -> selected_fu = ALU0
    exe_subop in Group0_BRU_set  -> selected_fu = BRU
    exe_subop in Group0_DIV_set  -> selected_fu = DIV
    exe_subop in Group0_CSR_set  -> selected_fu = CSR

Group 1:
    exe_subop in GroupShared_ALU_set -> selected_fu = ALU1
    exe_subop in Group1_MUL_set  -> selected_fu = MUL

Group 2:
    selected_fu = FPU

Group 3:
    selected_fu = LSU
```

Required busy selection:
```text
selected_fu_busy =
    alu0_busy / bru_busy / div_busy / csr_busy /
    alu1_busy / mul_busy / fpu_busy / lsu_busy
    according to the decoded selected_fu
```

Required startup behavior after `entry_select`:
- operand buses are made visible to all FUs inside the selected group
- `exe_subop` local decode generates mutually exclusive one-hot enables
- only the enabled FU latches operands and begins execution
- all non-selected FUs see the bus physically but do not consume it because their local enable is low

Required FU issue-acceptance contract:
- if `selected_fu_busy == 0` at the start of a cycle and `entry_select == 1`, the selected FU must accept the instruction in that cycle
- a FU must not retract acceptance later in the same cycle because of a late downstream response
- any downstream structural backpressure must appear as `selected_fu_busy == 1` before selection, not as a same-cycle reject after `entry_select`
- for any FU with a writeback-hold state, `fu_busy` must remain asserted while that held result is pending retry

PC note:
- `pc` is intentionally kept in `ISQ_Payload` for Group 0 AUIPC/BRU fast-path execution
- `ROB_MetaArray.inst_pc` remains the persistent source for trace, interrupt save-PC, and late-flush recovery
- Group 1/2/3 execution paths do not consume live `pc`; debug/trace should recover PC by ROB tag instead of carrying it through those datapaths

### 3. P3 -> P4 / Bypass: `Result_Payload` (per group)

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `result_valid` | 1 | FU / group arbiter | ROB write ports, bypass, flush sidecar capture | Indicates that this group produced the winning writeback result for the cycle. If `Global_Flush_Late` is asserted in the same cycle, this local result is killed before persistent publication. |
| `tag_out` | 4 | FU self tag | ROB, bypass, ROB_MetaArray | Physical tag of the completing instruction. Drives ROB write address, bypass compare identity, and the matching `ROB_MetaArray[tag_out]` index for any flush-metadata update. |
| `result_data` | 64 | FU datapath | ROB, bypass | Numerical or loaded result written into ROB and broadcast for zero-cycle wakeup. |
| `exception_flag` | 1 | FU control | ROB metadata, ROB_MetaArray flush-field write logic | Marks that the instruction completed with a precise synchronous exception. |
| `mispredict_flag` | 1 | BRU | ROB metadata, ROB_MetaArray flush-field write logic | Marks that a branch resolved incorrectly and will later request a late flush at commit. |
| `correct_pc` | 64 | BRU | ROB_MetaArray flush-field write logic | Actual branch redirect target captured only when `mispredict_flag=1`. |
| `exception_cause` | 64 | FU control | ROB_MetaArray flush-field write logic, P4 trap CSR write | Precise trap cause code that will later drive `mcause`/trap-cause state. |
| `is_csr` | 1 | FU / decode-carried context | ROB metadata, CSR control block | Marks that this completing instruction is a CSR op. |
| `csr_write_enable` | 1 | FU / decode-carried context | ROB metadata, CSR control block | Indicates whether this CSR op has an architectural CSR write side effect. |
| `csr_addr` | 12 | FU / decode-carried context | CSR_PEND_BUF | CSR address captured for commit-time side-effect application. |
| `csr_wdata` | 64 | FU / decode-carried context | CSR_PEND_BUF | New CSR value captured for commit-time side-effect application. |
| `is_fp` | 1 | FU / decode-carried context | ROB metadata, P4 commit routing | Selects FP vs INT architectural writeback at commit. |
| `rd_idx` | 5 | FU / decode-carried context | ROB metadata, P4 commit routing | Logical destination register recorded for later ARF writeback and DST_REG cleanup. |

Bypass bus:

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `bypass_valid[4]` | 4 | P3 group arbiters masked by `!Global_Flush_Late` | all ISQs, P1 stall logic | One valid bit per group winner. Enables same-cycle wakeup compare and Condition A late-dispatch stall detection. Must be `0` for every lane while `Global_Flush_Late == 1`. |
| `bypass_tag[4][3:0]` | 16 | P3 group arbiters | all ISQs, P1 stall logic | Broadcast producer tags. Compared against each waiting operand tag to form `fast_ready` and overlap-stall matches. |
| `bypass_data[4][63:0]` | 256 | P3 group arbiters | FU input MUXes | Broadcast result data. Selected directly by the FU input MUX when a bypass tag match occurs. |

### 4. ROB_MetaArray (P1/P3 -> P4 metadata sidecar)

Precise PC/trap metadata is not stored in ROB. It is stored in a separate ROB-depth metadata array indexed by ROB tag.

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `inst_pc` | 64 | P1 alloc-init from `ISB_Payload.pc` | P2 BRU path, P4 trap / trace / interrupt path | Supplies precise instruction PC without enlarging ROB or carrying PC through every execution payload. |
| `flush_valid` | 1 | P1 clear, P3 flush-field write, global flush clear | P4 recovery control | Marks whether this `ROB_MetaArray[tag]` entry contains valid flush metadata for the instruction owning that ROB tag. |
| `flush_kind` | 2 | P3 flush-field write | P4 recovery control | Distinguishes branch mispredict recovery from synchronous exception recovery. |
| `target_pc` | 64 | `Result_Payload.correct_pc` | P4 redirect logic | Supplies the real branch target when `flush_kind=MISPREDICT`. |
| `exception_cause` | 64 | `Result_Payload.exception_cause` | P4 trap CSR write | Supplies the precise trap cause when `flush_kind=EXCEPTION`. |

Policy:
- successful P1 allocation writes `inst_pc` and clears `flush_valid` for the new tag
- a flush-causing completion writes the flush fields of `ROB_MetaArray[tag_out]` directly
- different groups may write different `ROB_MetaArray[tag_out]` flush fields in the same cycle because live tags are unique
- there is no oldest-candidate reduction or single-entry replacement policy
- successful allocation of a new ROB tag must clear that tag's `flush_valid`
- `Global_Flush_Late` may bulk-clear all `ROB_MetaArray.flush_valid` bits

### 4A. CSR Control Block

CSR side effects and CSR serialization-barrier control are carried by a dedicated backend-global sequential control block, not by ROB.

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `csr_inflight_valid` | 1 | CSR control block state | P1 DSP, P4 commit | Dispatch-time CSR barrier bit. If 1, no younger instruction of any type may be dispatch-accepted at P1. |
| `csr_inflight_tag` | 4 | CSR control block state | P4 commit assertions | ROB tag of the only in-flight CSR instruction. |
| `csr_pend_valid` | 1 | P3 CSR completion logic | P4 commit | Indicates that a CSR write side effect is waiting for normal commit. |
| `csr_pend_tag` | 4 | P3 CSR completion logic | P4 commit | ROB tag of the CSR instruction owning the pending side effect. |
| `csr_pend_addr` | 12 | P3 CSR completion logic | CSR file write port | CSR address used when the matching CSR instruction commits. |
| `csr_pend_wdata` | 64 | P3 CSR completion logic | CSR file write port | New CSR value used when the matching CSR instruction commits. |

Rules:
- `csr_inflight_valid/tag` is set at successful P1 dispatch acceptance of a CSR instruction.
- `csr_inflight_valid/tag` is cleared only when that CSR commits normally or when global flush occurs.
- a CSR may dispatch only from `slot0`, only when the ROB is empty, and only when `csr_inflight_valid==0`
- if `csr_inflight_valid==1`, P1 must block all younger dispatch
- `csr_pend_*` is written only when a CSR completes in P3 with `csr_write_enable=1` and no exception.
- If a committing CSR has `csr_write_enable=1`, then `csr_pend_valid==1 && csr_pend_tag==commit_tag` must hold.
- `Global_Flush_Late` clears both `csr_inflight_valid` and `csr_pend_valid`.

### 5. P4 -> ARF: `Commit_Payload` (per commit, 2-wide)

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `commit_valid` | 1 | P4 commit-control FSM | ARF / CSR / P1 commit overlay / retire logic | Means this slot performs a real architectural commit. Gates ARF write, CSR side effect, same-cycle P1 overlay, and `ROB_head` retirement. |
| `commit_tag` | 4 | P4 from `ROB_head` | DST_REG cleanup, retire bookkeeping | Identifies which physical rename mapping is being retired. |
| `rd_idx` | 5 | ROB metadata | INT_ARF / FP_ARF, DST_REG cleanup, P1 commit overlay | Logical destination register written at commit and checked for matching busy-tag clear. |
| `rd_is_fp` | 1 | ROB metadata | ARF routing, P1 commit overlay | Selects INT vs FP architectural write port and same-cycle P1 overlay file selection. |
| `result_data` | 64 | ROB data array | ARF write ports, P1 commit overlay | Clean non-speculative data written into the final architectural register file and exposed to same-cycle P1 source resolution. |

Store-specific retirement rule:
- `COMMIT_WIDTH = 2` still applies to instructions overall
- but at most one store drain request may be launched per cycle
- a store-buffered indication from LSU does not mean architectural commit
- a store may produce `commit_valid` only after the LSU/L1D side reports `Store_Done` for that tag

### 5A. Store Drain / Done Interface

| Signal | Width | Source/Driver | Target | Hardware Behavior |
|---|---:|---|---|---|
| `Store_Drain_Req_Valid` | 1 | P4 commit-control FSM | LSU / L1D-side store buffer | Requests that the oldest buffered store at ROB head begin its L1D-side drain. This is not architectural commit. |
| `Store_Drain_Req_Tag` | 4 | P4 commit-control FSM | LSU / L1D-side store buffer | ROB tag of the store requested to drain. |
| `Store_Done_Valid` | 1 | LSU / L1D-side store buffer | ROB / P4 commit-control FSM | Indicates that a requested store drain has completed and the store is now eligible for architectural commit. |
| `Store_Done_Tag` | 4 | LSU / L1D-side store buffer | ROB / P4 commit-control FSM | ROB tag of the completed store drain. |
| `Store_Done_Exception` | 1 | LSU / L1D-side store buffer | ROB / P4 commit-control FSM | Optional synchronous store-drain failure indication for the completed tag. |
| `Store_Done_Cause` | XLEN | LSU / L1D-side store buffer | ROB metadata | Optional exception cause associated with `Store_Done_Exception`. |

Rules:
- `Store_Drain_Req_Valid` may be asserted at most once per cycle
- a drain request may be issued only for a store that is already buffered in the LSU/L1D-side store buffer and is oldest at the ROB commit boundary
- a drain request does not advance `ROB_head` and does not assert `commit_valid`
- while the head store waits for `Store_Done`, younger instructions may not commit past it
- if both `head0` and `head1` are stores, only the older store may be considered for drain or commit in that cycle
- `Store_Done_Valid/Tag` authorizes P4 to commit the matching store, or to select a precise exception if `Store_Done_Exception=1`
- the store remains forwardable from the store buffer while drain is in progress

### 6. Global Flush Control Signals

| Signal | Source/Driver | Target | Hardware Behavior |
|---|---|---|---|
| `Global_Flush_Late` | P4 late-flush control | P0, P1, P2 | Synchronously clears all visible pipeline valid state after a selected mispredict, exception, or interrupt. |
| `Flush_Target_PC` | P4 recovery logic | IFU / frontend PC select | Supplies the fetch redirect target. Branch uses `ROB_MetaArray[flush_tag].target_pc`; exception uses trap-vector logic; interrupt uses next-architectural-PC logic after same-cycle commits. |
| `Reset_ROB_Pointers` | P4 retire / flush control | ROB pointer logic | Forces `ROB_tail = ROB_head + commit_count_before_flush`, preserving any older same-cycle commits while draining all younger speculative entries. |
| `Clear_All_Busy` | P4 late-flush control | INT_DST_REG / FP_DST_REG | Bulk clears all rename busy bits so post-flush instructions reread clean architectural state from ARF. |
| `Clear_MetaArray_FlushValid` | P4 late-flush control | ROB_MetaArray | Bulk clears metadata-array `flush_valid` bits after recovery so stale flush metadata cannot match future tags. |
| `Clear_CSR_Trackers` | P4 late-flush control | CSR control block | Clears `csr_inflight_valid` and `csr_pend_valid` so no speculative CSR state survives a flush. |

Priority:
- `head0` flush beats `head1`
- synchronous flush beats external interrupt in the same cycle

When `Global_Flush_Late = 1`:
- alloc-side writes from `P1` must be squashed
- FU issue launches from `P2` must be squashed
- all multi-cycle FU internal state associated with pre-flush speculative work must be synchronously cleared
- same-cycle `P3` result publication must be suppressed: bypass valid is forced low and ROB, `ROB_MetaArray`, and CSR pending captures take their recovery clear/reset path instead of recording killed results

### 7. LSU Predictive Wakeup

| Signal | Width | Source | Target | Hardware Behavior |
|---|---:|---|---|---|
| `agu_early_tag` | 4 | Group 3 LSU AGU register | P1 DSP stall logic | One-cycle registered predictive tag for Loads only. Cancels the too-late dispatch stall so a dependent instruction may enter ISQ before load data returns. |

Notes:
- LSU never broadcasts real data on bypass before L1D returns
- Stores are conservative: P4 requests drain only at the precise ROB head boundary, and the store commits only after `Store_Done`
- `agu_early_tag` may be emitted only for a Load whose AGU completed, whose address-side checks have not already raised a synchronous exception, and whose request has been accepted by the L1D-side request interface

---

## Part III: P4 Late Flush Global Control Interface

Late Flush is precise and commit-based.

Behavior:
- `head0` is always evaluated before `head1`
- `head1` can only commit if `head0` commits or is absent
- if a flush is selected, P4 first advances `ROB_head` by the number of older same-cycle commits, then drains younger speculative state
- branch mispredict uses `ROB_MetaArray[flush_tag].target_pc`
- exception uses `ROB_MetaArray[flush_tag].inst_pc` + `exception_cause` and redirects to trap vector logic
- external interrupt does not set `flush_valid` in `ROB_MetaArray`
- if a synchronous flush is selected, `ROB_MetaArray[flush_tag].flush_valid` must be 1 and `flush_kind` must match the selected event kind
- if no synchronous flush is selected, any older same-cycle normal commits may still complete before an external interrupt redirect is taken, and the interrupt save PC uses the next architectural PC after those commits
- if no same-cycle normal commit occurred and `ISB` holds a valid oldest instruction, interrupt save-PC uses `ISB_head.pc`
- otherwise the frontend must provide the non-speculative "next instruction that would execute" PC as the interrupt save-PC source

---

## Part IV: LSU Predictive Wakeup Interface

`agu_early_tag` is a registered 1-cycle hint from the LSU AGU to P1.

Use:
- if a load’s dependent instruction matches `agu_early_tag`, P1 cancels the too-late dispatch stall
- the dependent instruction still waits in ISQ for the real data bypass from L1D

`agu_early_tag` is a predictive control contract, not speculative data. It must not be emitted for Stores or for a Load that has already detected a synchronous address-side fault.

---

## Part V: Implementation Notes

- `INT_DST_REG` is 4R2W
- `FP_DST_REG` is 3R1W
- ROB does not store PC metadata
- `ROB_MetaArray` is the only precise PC/trap metadata store
- `commit_valid` means architectural commit, not just `done`
- stores must not be allowed to become architecturally visible speculatively
- multi-cycle FUs must clear internal datapath/state-machine state on `Global_Flush_Late`
- `EBREAK`, `ECALL`, and illegal-instruction cases must set `exception_flag` / `exception_cause` like any other synchronous exception
