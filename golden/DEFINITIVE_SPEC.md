# Or - Lightweight 4-Group Dual-Issue Out-of-Order Backend
## Definitive Architecture Specification v1.0

> **Design Positioning**: Area/Power-constrained lightweight dual-issue core targeting edge computing, IoT, and coprocessor applications. Not a deep OoO PC/server design.

---

## 1. Architecture Overview

### 1.1 Throughput Topology

```
2-wide In-order Dispatch -> 4-Group OoO Execute -> 4-wide OoO Writeback -> 2-wide In-order Commit
```

| Stage | Width | Ordering | Description |
|---|---|---|---|
| P0 - Fetch/Dequeue | 2 | In-order | Extract from Instruction Buffer (ISB), branch speculation via BPU |
| P1 - Rename/Dispatch | 2 | In-order | Register renaming via DST_REG, deadlock prevention, ISQ enqueue |
| P2 - Issue/Execute | 4 groups | Out-of-order | Associative wakeup via Bypass network, select arbitration, FU execution |
| P3 - Writeback | 4 | Out-of-order | Intra-group arbitration, 4-wide Bypass broadcast, ROB write |
| P4 - Commit | 2 | In-order | In-order retire into ARF, DST_REG cleanup, Late Flush recovery |

### 1.2 Execution Group Topology

Each group has its own dedicated output path and its own subset of the Issue Queue.

| Group | Functional Units | Shared MUX |
|---|---|---|
| Group 0 | ALU0, BRU, DIV, CSR | 3-to-1 MUX |
| Group 1 | ALU1, MUL | 2-to-1 MUX |
| Group 2 | FPU | Independent |
| Group 3 | LSU | Independent |

### 1.3 Storage Budget

| Structure | Depth | Width | Ports | Implementation |
|---|---|---|---|---|
| **ROB** | 16 entries | 64-bit data + metadata | 4W 2R | DFF array (not SRAM) |
| **ROB_MetaArray** | 16 entries | ~195 bits/entry | 2W alloc init + up to 4W flush update + 2R | DFF array |
| **INT_ARF** | 32 entries | 64-bit | 4R 2W | SRAM/RegFile |
| **FP_ARF** | 32 entries | 64-bit | 3R 1W | SRAM/RegFile |
| **INT_DST_REG** | 32 entries | 5-bit (1 busy + 4 tag) | 4R 2W | SRAM/RegFile |
| **FP_DST_REG** | 32 entries | 5-bit (1 busy + 4 tag) | 3R 1W | SRAM/RegFile |
| **ISQ Group 0** | 1 entry | ~180 bits | 1W Bypass snooping | SRAM/RegFile |
| **ISQ Group 1** | 1 entry | ~180 bits | 1W Bypass snooping | SRAM/RegFile |
| **ISQ Group 2** | 1 entry | ~180 bits | 1W Bypass snooping | SRAM/RegFile |
| **ISQ Group 3** | 1 entry | ~180 bits | 1W Bypass snooping | SRAM/RegFile |

**Tag Width**: 4-bit (`TAG_W = 4`). Strictly bound to 16-entry ROB depth. Tag values range 0x0-xF.

**ROB PC policy**: ROB entries intentionally do **not** store `pc`, `correct_pc`, or exception-PC metadata. Any precise control-flow metadata needed for commit trace, interrupt save-PC, and later Late Flush is stored in the separate `ROB_MetaArray[tag]`, indexed by ROB tag.

---

## 2. Pipeline Stage Specifications

### 2.1 P0 - Instruction Dequeue & Speculation

**Purpose**: Boundary between decoupled frontend and backend. Present up to 2 head instructions from ISB to the DSP combinational dispatch logic, handle branch prediction, and respond to backend backpressure.

- `slot0` is always evaluated first.
- `slot1` is evaluated only after `slot0`, against the updated resource view after any successful `slot0` dispatch.
- If a slot's target ISQ is occupied, that slot is **not** dequeued from ISB. The same head instruction remains in ISB and is retried on the next cycle.
- An instruction is dequeued from ISB **only** when DSP successfully writes it into the target ISQ.
- Because dispatch is in-order, `slot1` may not bypass a blocked `slot0`.
- Unrelated groups do not backpressure each other. For example, a busy Group 3 ISQ does not block a Group 0 instruction at the head of ISB.

**Branch Speculation**:
- BPU lookup is combinational, single-cycle
- `pred_taken` and `pred_target_pc` override IFU PC directly
- No flush at P0 - mispredicts are resolved at P4 (Late Flush)

---

### 2.2 P1 - Rename, Dispatch & Deadlock Prevention

**Purpose**: `P1` is the in-order rename-and-admit stage implemented as DSP combinational logic between `ISB` and the per-group `ISQ` state. It resolves source dependencies through `DST_REG` / `ARF`, checks dispatch legality and backpressure, applies deadlock-prevention rules, allocates ROB tags, updates destination rename state, and writes accepted instructions into the destination ISQ.

**P1 datapath summary**:
```text
ISB -> DSP combinational logic -> ISQ write
    -> source dependency resolution from DST_REG / ARF
    -> per-slot admission and backpressure check
    -> deadlock-prevention stall check
    -> ROB allocation + DST_REG update + ISQ payload generation
```

#### 2.2.1 Source Dependency Resolution from DST_REG / ARF

P1 reads `INT_DST_REG` and `FP_DST_REG` in parallel based on logical register index, then decides whether each source operand is immediately ready from `ARF` or must wait on a producer tag.

P1 resolves the two dispatch slots strictly in program order. `slot0` reads the current `DST_REG` / `ARF` state directly. If `slot0` is accepted and writes a destination register, P1 forms a transient same-cycle rename overlay:
```text
slot0_overlay = {
    valid: slot0 accepted && slot0.use_rd,
    rd_idx: slot0.rd_idx,
    rd_is_fp: slot0.rd_is_fp,
    tag: ROB_tail
}
```
`slot1` source lookup checks this overlay before consulting the persistent `DST_REG` state. This overlay exists only inside the current combinational P1 evaluation; it is not a new storage field inside `DST_REG`.

**Read Port Counts**:
| Register File | Read Ports | Why |
|---|---|---|
| INT_DST_REG | 4 | Dual-issue x 2 sources/instruction = max 4 simultaneous INT reads |
| FP_DST_REG | 3 | Dual-issue, but at most 3 FP sources expected (e.g., one FMA per cycle). 1 port saved for area. |

**Per Source Operand Logic** (per slot, per file):
```text
if (use_rsX == 0):
    rsX_ready = 1
    rsX_data  = 64'h0
    rsX_wait_tag = 4'h0
else if (same_cycle_commit_overlay_match):
    rsX_ready = 1
    rsX_data  = same_cycle_commit_data
    rsX_wait_tag = 4'h0
else:
    if (rsX_is_fp):
        {busy, tag} = FP_DST_REG.read(rsX_idx)
    else:
        {busy, tag} = INT_DST_REG.read(rsX_idx)

    if (busy == 0):
        rsX_ready = 1
        rsX_data  = ARF.read(is_fp=rsX_is_fp, addr=rsX_idx)
        rsX_wait_tag = 4'h0
    else:
        rsX_ready = 0
        rsX_data  = 64'h0
        rsX_wait_tag = tag   // producer tag for Bypass snooping
```

**Meaning**:
- `same_cycle_commit_overlay_match`: the source matches a normal same-cycle P4 committed destination and therefore must resolve from the committed architectural value, not from stale pre-commit ARF contents.
- `busy == 0`: source is architecturally ready, so P1 reads the value from ARF and stores it in the ISQ payload.
- `busy == 1`: source is waiting on an older in-flight producer, so P1 records only the `wait_tag`; the real data will later come from the Bypass network or, after commit, from ARF.

**Same-cycle commit overlay rule**:
- P1 source resolution must include a same-cycle commit overlay for normal P4 commits.
- This overlay has priority over persistent `ARF/DST_REG` state.
- A matching source resolves as:
```text
rsX_ready    = 1
rsX_data     = committed result_data
rsX_wait_tag = 4'h0
```
- This rule exists so the architecture does **not** depend on implementation-specific same-cycle ARF read-after-write or DST_REG clear visibility.
- If both `head0` and `head1` commit in the same cycle and both write the same logical destination in the same file, the effective overlay value is the younger `head1` commit result, because P1 must see the post-commit architectural state for that cycle.
- Integer `x0` still behaves as architecturally zero and must not be resolved through a destination mapping or commit overlay writeback.

**Same-cycle `slot0 -> slot1` RAW rule**:
```text
// slot1 source resolution checks same-cycle slot0 overlay first
if (slot0_overlay.valid &&
    (slot1.rsX_idx   == slot0_overlay.rd_idx) &&
    (slot1.rsX_is_fp == slot0_overlay.rd_is_fp)):
    rsX_ready    = 0
    rsX_data     = 64'h0
    rsX_wait_tag = slot0_overlay.tag
else:
    // fall back to the normal DST_REG / ARF lookup above
```
This guarantees that a same-bundle dependency uses `slot0.self_rob_tag` as the producer tag, rather than incorrectly reading stale `ARF` data or an older `DST_REG` mapping.

**Overlay priority order for `slot1`**:
1. same-cycle `slot0 -> slot1` rename overlay
2. same-cycle normal P4 commit overlay
3. persistent `DST_REG/ARF` state

This ordering is required because `slot0` is younger than all same-cycle commits and therefore must override any older architectural value for `slot1` RAW resolution.

#### 2.2.2 Per-Slot Admission and Backpressure Check

P1 does not own an internal holding register. It evaluates the head instruction(s) currently visible from `ISB` and decides whether each instruction may be written into its destination ISQ in the current cycle.

**Admission rules**:
- `slot0` is always evaluated first.
- `slot1` is evaluated only after `slot0`, against the updated resource view after any successful `slot0` dispatch.
- Define:
```text
ROB_empty = (ROB_head == ROB_tail) && (ROB_full_flag == 0)
```
- A slot may dispatch only if:
  - `ROB_full == 0`
  - its target ISQ, chosen by `exe_type`, is free for dispatch in this cycle
  - no older-slot ordering rule blocks it
  - no P1 deadlock-prevention stall condition blocks it
- Because `FP_DST_REG` has only 1 write port, at most one FP-destination instruction may be accepted per cycle. Therefore `slot1` must be blocked if `slot0` is accepted with `rd_is_fp == 1` and `slot1` would also perform an FP rename write, even when the two instructions target different execution groups (for example, Group 2 FPU op + Group 3 FP load).
- CSR quiesce rule:
  - A CSR instruction may be dispatch-accepted only from `slot0`.
  - A CSR in `slot0` may dispatch only if `ROB_empty == 1`.
  - A CSR in `slot1` may not dispatch in the same cycle; it must wait until it becomes the `ISB` head in a later cycle.
  - If `slot0` is accepted as CSR, `slot1` is blocked regardless of `slot1` type.
  - After a CSR has entered the machine, no younger instruction may dispatch until that CSR commits normally or the machine is flushed.
  - While `csr_inflight_valid == 1`, all younger dispatch is blocked.
- If a slot is accepted, P1 writes the payload into the destination ISQ and the corresponding head instruction is dequeued from ISB.
- If a slot is not accepted, P1 withholds the ISQ write; the same head instruction remains in ISB and is retried next cycle.
- Because dispatch is in-order, `slot1` may not bypass a blocked `slot0`.

**ISQ same-cycle refill rule**:
```text
isq_free_for_dispatch[g] =
    !ISQ_valid_q[g] || issue_en_q[g]
```

Meaning:
- if the ISQ is already empty at the start of the cycle, P1 may dispatch into it
- if the ISQ holds an older entry that will successfully issue this cycle, P1 may also dispatch into it in the same cycle
- the newly written entry does not itself participate in same-cycle issue; it becomes selectable beginning next cycle

`slot1` must evaluate against the virtual post-`slot0` occupancy view after accounting for any accepted `slot0` claim on the target group.

This is the backpressure boundary for the frontend/backend interface:
`ISB -> DSP -> ISQ`

#### 2.2.3 Deadlock Prevention Stall Conditions

To enforce the "no-forward-from-ROB" constraint, P1 blocks dispatch of instructions whose data is about to be missed by wakeup. Conditions are evaluated in priority order:

| Condition | Trigger Logic | Meaning |
|---|---|---|
| **A - Bypass Broadcast Overlap** | `bypass_valid[g] && (wait_tag == bypass_tag[g])` for any g | Data is broadcasting this exact cycle via bypass bus. If dispatched now, the instruction enters ISQ too late to catch the combinational bypass pulse. Instead, it should wait until ROB commits and reads from ARF. |
| **B - Data Stuck in ROB** | `ROB[wait_tag].done == 1 && !same_cycle_commit_match(wait_tag)` | Data computed but locked in ROB with no Bypass broadcast. Keeps stalling dispatched-too-late instructions until ROB commits and DST_REG clears. A same-cycle normal P4 commit for that exact `wait_tag` suppresses Condition B because the explicit commit overlay already makes the architectural value visible. |
| **C - LSU Early Wakeup Exemption** | `wait_tag == agu_early_tag` | **Cancel Stall** (see Section 2.2.4) |

**Stall Action**: If Condition A or B triggers, assert `P1_Stall`. DSP withholds the ISQ write for that instruction, so the corresponding head instruction remains in ISB and is retried on the next cycle. Condition C cancels the stall for LSU predictive wakeup.

Here, `same_cycle_commit_match(wait_tag)` means that one of the normal same-cycle P4 commit slots is retiring that exact producer tag and therefore exposing the committed value through the explicit P4->P1 commit overlay.

**Two-layer stall design** (P1 is combinational DSP between ISB and ISQ):
- **Condition A** (fast path): Uses bypass_tag from P3 arbiter (combinational, available immediately). Provides early stall detection - cuts off the P1 combinational path before ROB DFF updates.
- **Condition B** (backup path): Uses ROB.done from ROB DFF (requires clock-to-Q delay). Catches cases where the bypass pulse ended but ROB still has uncommitted data.
- P1 DSP is purely combinational: `ISB -> DST_REG read -> stall check -> ISQ payload -> ISQ write`. Both conditions feed into the same combinational `P1_Stall` signal.

**Protection chain for same-cycle dependency** (e.g., inst0 completes at cycle N+2, inst4 depends on inst0 and enters DSP at N+2):
1. Cycle N+2: inst0 completes in FU. ROB[tag0] written at posedge clk. During combinational evaluation, `bypass_tag[0]=tag0` matches `wait_tag=tag0` -> **Condition A triggers** (fast, bypass tag available immediately). inst4 stalls in DSP.
2. Cycle N+3: bypass_valid[0]=0 (pulse ended). `ROB[tag0].done=1` -> **Condition B triggers** (slower, requires ROB DFF clock-to-Q). inst4 stays in DSP.
3. Cycle N+3+: ROB commits inst0 -> ARF[R5] written, DST_REG[R5].busy=0. `ROB[tag0].done` may still be 1, but at commit DST_REG clears. The next time inst4 reaches DSP and ROB entry has moved past head, Condition B no longer applies -> DST_REG[R5].busy=0 -> `rs_ready=1` -> enters ISQ with data from ARF[R5].

Both conditions work as a chain: Condition A blocks the same-cycle case (bypass broadcast active, fast detection), Condition B blocks the next-cycle case (data in ROB not yet committed, backup). Only after ROB commits does the dependent instruction get through. If that normal commit happens in the current cycle, the explicit same-cycle commit overlay resolves the source as ready and also suppresses Condition B for that exact producer tag.

**Note**: These stall conditions only protect against "dispatch too late, miss the Bypass broadcast." Normal same-cycle or next-cycle dependencies (e.g., ALU->ALU cross-group) do **not** trigger P1 stall. Instead, the dependent instruction enters ISQ with `rs_ready=0` and waits for Bypass wakeup. The ISQ Select stage (Section 2.3.1.2) is the primary dependency gate - it never selects entries with `rs_ready=0`.

#### 2.2.4 LSU Predictive Wakeup (agu_early_tag)

When a Load instruction enters the LSU FU stage (Group 3), the address computation (AGU) is performed internally. At the end of this stage, `agu_early_tag` (4-bit) is sent to P1.

**Registered timing**: `agu_early_tag` is registered at the LSU FU output (posedge clk). P1 samples it at the next posedge clk. This 1-cycle registered latency ensures STA closure on the long Group 3->P1 timing path.

**Sequence**:
1. Load instruction enters Group 3 LSU FU -> AGU computes address, `agu_early_tag` latched at posedge clk
2. Next cycle, P1 sees `agu_early_tag = inst0_tag`. Dependent instruction matches `wait_tag == agu_early_tag` -> **Stall cancelled** (Condition C)
3. Dependent instruction enters Issue Queue with `rs_ready = 0`, waits in ISQ
4. Load instruction proceeds to L1Dcache, reads data -> pushes real `result_data` + `tag_out` onto Bypass bus
5. Dependent instruction in queue latches Bypass data via tag match -> ready for execution

**Key constraint**: LSU FU **never** broadcasts data on Bypass until L1Dcache returns. Only sends `agu_early_tag` control signal to P1 predictively.

`agu_early_tag` may be emitted only when all of the following hold:
1. the instruction is a **Load**, not a Store
2. AGU address computation for that load completed
3. no synchronous address-side exception has already been detected for that load (for example misalignment, permission, or translation failure)
4. the corresponding load request has been accepted by the L1D-side request interface

If any of those conditions fail, `agu_early_tag` must remain deasserted for that load.

#### 2.2.5 ROB Allocation, DST_REG Update, and ISQ Write

For non-stalled instructions that pass the per-slot admission checks in Section 2.1, ROB allocation is performed in strict program order.

**Single accepted instruction**:
```text
self_rob_tag = ROB_tail
ROB_tail_next = ROB_tail + 1
```

**Two accepted instructions in the same cycle**:
```text
slot0.self_rob_tag = ROB_tail
slot1.self_rob_tag = ROB_tail + 1
ROB_tail_next      = ROB_tail + 2
```

This ordering is independent of destination type. For example, if both accepted instructions write integer destination registers, then:
```text
slot0 -> INT_DST_REG[rd0].tag = ROB_tail
slot1 -> INT_DST_REG[rd1].tag = ROB_tail + 1
```
If one instruction writes INT and the other writes FP, each instruction still receives its ROB tag in program order; only the destination rename table (`INT_DST_REG` vs `FP_DST_REG`) differs.

If both accepted slots write the **same** logical destination register in the same file, the final persistent `DST_REG` state must hold the younger mapping:
```text
if (slot0.use_rd && slot1.use_rd && (slot0.rd_idx == slot1.rd_idx) &&
    (slot0.rd_is_fp == slot1.rd_is_fp)):
    DST_REG[rd].busy = 1
    DST_REG[rd].tag  = slot1.self_rob_tag
```
This is a same-cycle WAW rule for the persistent rename-table next state. It does **not** change the same-cycle RAW rule above: `slot1` source resolution still sees `slot0` as the older producer through the transient overlay.

**Per accepted instruction**:
```text
// Allocate ROB tag in program order
self_rob_tag = allocated_tag_for_this_slot

// Initialize ROB metadata entry for this live tag
ROB_MetaArray[self_rob_tag].inst_pc       = pc
ROB_MetaArray[self_rob_tag].flush_valid   = 0
ROB_MetaArray[self_rob_tag].flush_kind    = NONE
ROB_MetaArray[self_rob_tag].target_pc     = 64'h0
ROB_MetaArray[self_rob_tag].exception_cause = 64'h0

// Write destination rename state if use_rd == 1
DST_REG[rd].busy = 1
DST_REG[rd].tag  = self_rob_tag

// Assemble ISQ_Payload with operands, metadata, and self_rob_tag
// Route to destination group by exe_type
// Write to the corresponding ISQ entry
// On successful ISQ write, dequeue the corresponding head instruction from ISB
```
For dual-issue, these destination writes are applied only for accepted slots. `INT_DST_REG` supports two same-cycle writes. `FP_DST_REG` remains single-write, so P1 must forbid the `alloc_valid[1]` case that would otherwise require two same-cycle FP destination writes.

**Same-cycle `DST_REG` write priority**:
- If a same-cycle younger `P1` allocation write and a same-cycle older `P4` tag-matched clear target the same `DST_REG` entry, the `P1` allocation write wins for the persistent next-state.
- Therefore the surviving rename entry becomes `{busy=1, tag=new_alloc_tag}`.

**Flush-vs-allocation priority**:
- `Global_Flush_Late` is the recovery boundary and squashes all same-cycle alloc-side state changes.
- When `Global_Flush_Late == 1` in the current cycle:
  - `ROB_tail` must not advance from `P1` allocation
  - `DST_REG` alloc writes are squashed
  - `ROB_MetaArray[self_rob_tag]` initialization writes are squashed
  - `ISQ` payload writes are squashed
  - `isb_dequeue` is squashed
  - `csr_inflight_valid` must not be newly set from that cycle's `P1` acceptance attempt
- A same-cycle flush therefore always beats same-cycle allocation.

**ROB Allocation Control Logic**:
The ROB does not guess whether `ROB_tail` should advance by 0, 1, or 2. It advances only from the actual accepted dispatch results of the current cycle.

Define:
```text
alloc_valid[0] = 1 if slot0 successfully writes into its destination ISQ this cycle
alloc_valid[1] = 1 if slot1 successfully writes into its destination ISQ this cycle
```

Because dispatch is in-order, the pattern `alloc_valid = 2'b10` is illegal. `slot1` may not allocate unless `slot0` also allocates in the same cycle.

Legal ROB-tail update logic:
```text
alloc_tag[0] = ROB_tail
alloc_tag[1] = ROB_tail + 1

case ({alloc_valid[1], alloc_valid[0]})
  2'b00: ROB_tail_next = ROB_tail
  2'b01: ROB_tail_next = ROB_tail + 1
  2'b11: ROB_tail_next = ROB_tail + 2
  2'b10: illegal
endcase
```

**Interpretation**:
- `2'b00`: no instruction was accepted into ISQ, so ROB performs no allocation and `ROB_tail` does not advance
- `2'b01`: only `slot0` was accepted, so ROB allocates one entry
- `2'b11`: both `slot0` and `slot1` were accepted, so ROB allocates two consecutive entries
- `2'b10`: must never happen in legal RTL because `slot1` cannot bypass a blocked `slot0`

This logic is the exact ROB-side contract for RTL: `P1/DSP` determines acceptance, the ROB advances `ROB_tail` only by the count of successful same-cycle allocations, and `ROB_MetaArray[self_rob_tag]` is initialized for every newly allocated live tag.

**Result of P1**:
- accepted instructions become tag-based ISQ entries
- rejected instructions remain at the head of ISB for retry
- P1 itself does not buffer instructions; the holding structure before acceptance is ISB, and the holding structure after acceptance is ISQ

---

### 2.3 P2 - Issue, Select & Execute

**Purpose**: Dynamic scheduling. Wakeup operands from Bypass snooping, select oldest ready entry, drive functional units.

#### 2.3.1 Bypass Wakeup

Each ISQ entry performs parallel **combinational** tag comparison every cycle against all 4 Bypass buses. All 4 ISQ modules snoop the 4 Bypass buses - this is how Group 1 ISQ catches a result broadcast by Group 0 ALU.

**Bypass bus** is a combinational broadcast from P3 arbiter outputs. The tag comparison is done combinatorially for zero-cycle wakeup, but matched bypass data is latched into ISQ entries at the clock edge to preserve data when the FU is busy.

**Per source operand per group**:
```verilog
// Combinational tag comparison (drives same-cycle issue decision)
for each entry e in ISQ[group]:
    if (!e.valid): continue

    // Compare all 4 bypass buses combinatorially
    wire bypass_match_rs1 = bypass_valid[0] && (e.rs1_wait_tag == bypass_tag[0]) ||
                            bypass_valid[1] && (e.rs1_wait_tag == bypass_tag[1]) ||
                            bypass_valid[2] && (e.rs1_wait_tag == bypass_tag[2]) ||
                            bypass_valid[3] && (e.rs1_wait_tag == bypass_tag[3]);

    // fast_ready_rs1 = combinational result, drives Select immediately
    wire fast_ready_rs1 = bypass_match_rs1;

    // entry_ready = combinational, enables same-cycle issue
    wire entry_ready = e.valid &&
                       (e.rs1_ready || fast_ready_rs1) &&
                       (e.rs2_ready || fast_ready_rs2) &&
                       (e.rs3_ready || fast_ready_rs3);
```

**Sequential data capture**: When `bypass_match_rs1` is true, the ISQ latches both the ready bit and the data at the next clock edge:
```verilog
always_ff @(posedge clk) begin
    if (entry_valid && bypass_match_rs1) begin
        entry.rs1_ready <= 1'b1;
        entry.rs1_data  <= matched_bypass_data;  // Preserve data for later cycles
    end
end
```

This dual-path design supports:
- **Zero-cycle forwarding**: When FU is not busy, instruction issues in the same cycle as bypass arrival using combinational `fast_ready`.
- **Data preservation**: When FU is busy, matched bypass data is latched so it survives after the bypass pulse ends.

**Bypass Comparator Implementation**: 4-bit bitwise XOR comparison per tag. No CAM array, no associative storage. Simple combinational tag comparators: 4 tags x 4 ISQs x 3 sources x 4 bits XOR + AND. Total ~192 XOR gates + AND tree.

**How it differs from the old CAM path**:
- **Old (CDB + CAM)**: CDB broadcast -> CAM associative array -> match detected -> flip-flop `rs_ready` updated at posedge clk -> next cycle Select picks entry. 1-cycle registered delay.
- **New (Bypass)**: P3 arbiter output -> combinational bypass bus -> tag comparator -> `fast_ready` combinatorial -> **same cycle** Select picks entry if FU ready. Matched data latched at clock edge for later use if FU busy.

#### 2.3.1.1 rs_ready - Dispatch-Time Static Flag

`rs_ready` is set at **dispatch time** (from ARF data, when `busy == 0` in DST_REG). It is not updated during wakeup - wakeup readiness is indicated by the combinational `fast_ready` signal.

```verilog
// At dispatch (P1): rs_ready = 1 if source data from ARF (no dependency)
//                  : rs_ready = 0 if source data from producer (dependency)

// At select (P2): entry_ready = valid && (rs_ready_from_dispatch || fast_ready) && rs2_ready
//                  (fast_ready = combinational bypass match, zero delay)
```

**Entry data path**: When an entry has `rs_ready = 0` at dispatch (waiting on dependency), its `rs1_data` field holds `64'h0` (placeholder). When bypass match occurs, the matched data is latched into `rs1_data` at the clock edge, and `rs1_ready` is set to 1. The actual data forwarding to FU comes from the **FU input MUX** (Section 2.3.2).

```verilog
// ISQ entry storage at dispatch:
entry.rs1_data = 64'h0;    // placeholder
entry.rs1_wait_tag = tag0; // producer tag for bypass matching

// ISQ entry update at wakeup (sequential):
always_ff @(posedge clk) begin
    if (bypass_match_rs1) begin
        entry.rs1_ready <= 1'b1;        // Mark as ready
        entry.rs1_data  <= bypass_data; // Latch data
    end
end

// FU input MUX (combinational, per source operand):
wire [63:0] rs1_source = entry.rs1_ready   ? entry.rs1_data :      // Latched data from previous wakeup
                         bypass_match_rs1  ? bypass_data[g] :      // Same-cycle bypass (FU not busy case)
                         64'h0;                                    // Should not happen
FU_input.rs1_data = rs1_source;
```

**Data flow priorities**: 
1. If `rs_ready = 1`: Use latched data from `entry.rs1_data` (captured from earlier bypass match or ARF at dispatch)
2. If `rs_ready = 0` but `bypass_match = 1` this cycle: Use current bypass bus data for same-cycle forwarding
3. Otherwise: placeholder (should not issue)

#### 2.3.1.2 Select & Dependency Gate (Primary Dependency Control)

**Critical invariant**: An ISQ entry with `rs_ready == 0` and `bypass_match == 0` or `selected_fu_busy == 1` is **never selected** by the ISQ Select stage. The ISQ Select checks two independent conditions:

1. **Operand readiness**: `rs_ready=1` (data from ARF) or `fast_ready=1` (bypass match) for all sources.
2. **FU availability**: the specific FU selected by `exe_subop` is not busy.

**Two-level execution decode**:
- `exe_type` selects the execution group and therefore the destination ISQ.
- Within the selected group, `exe_subop` selects the exact FU that will execute the instruction.
- `exe_subop` is a **6-bit group-local control field**. It is interpreted only after `exe_type` selects the execution group.
- Therefore the same numeric `exe_subop` value may legally mean different things in different execution groups.
- Busy checking must therefore be done **after** the local `exe_subop` decode, not with a coarse group-level busy bit.

For Group 0:
```text
if (exe_subop in GroupShared_ALU_set): selected_fu = ALU0
if (exe_subop in Group0_BRU_set ): selected_fu = BRU
if (exe_subop in Group0_DIV_set ): selected_fu = DIV
if (exe_subop in Group0_CSR_set ): selected_fu = CSR
```

For Group 1:
```text
if (exe_subop in GroupShared_ALU_set): selected_fu = ALU1
if (exe_subop in Group1_MUL_set ): selected_fu = MUL
```

For Group 2 and Group 3:
```text
if (exe_type == 2): selected_fu = FPU
if (exe_type == 3): selected_fu = LSU
```

The sets above are decode-table classes owned by the decode/FU contract. RTL must implement them as a **mutually exclusive one-hot local decode inside the selected group**. Any illegal or overlapping `exe_subop` pattern within the selected group is an illegal RTL state.

**Selected busy derivation**:
```verilog
logic selected_fu_busy;

case (selected_fu)
  ALU0: selected_fu_busy = alu0_busy;
  BRU : selected_fu_busy = bru_busy;
  DIV : selected_fu_busy = div_busy;
  CSR : selected_fu_busy = csr_busy;
  ALU1: selected_fu_busy = alu1_busy;
  MUL : selected_fu_busy = mul_busy;
  FPU : selected_fu_busy = fpu_busy;
  LSU : selected_fu_busy = lsu_busy;
endcase
```

The combinational select logic:
```verilog
wire operand_ready = (rs1_ready || fast_ready_rs1) && (rs2_ready || fast_ready_rs2) && (rs3_ready || fast_ready_rs3);
wire entry_select  = entry.valid && operand_ready && !selected_fu_busy && !Global_Flush_Late;
```

ISQ has depth=1 per group - there is no priority encoder within the ISQ. Each ISQ module has exactly one entry, so the Select stage is a simple single-entry check. If either condition is false (operands not ready, or the selected FU is busy), the entry stays in ISQ.

P1 stall conditions (A/B in Section 2.2.3) are a secondary protection for rare "dispatch too late" edge cases. The ISQ Select handles all dependency and FU availability gating. P1 (dispatch) does NOT check selected-FU busy - it only checks ISQ_full and ROB_full, allowing the frontend to keep feeding instructions into ISQ regardless of FU state.

#### 2.3.2 FU Input Data MUX

**Select logic** (per group, single entry per ISQ):
```verilog
wire operand_ready = (rs1_ready || fast_ready_rs1) && (rs2_ready || fast_ready_rs2) && (rs3_ready || fast_ready_rs3);
wire entry_select  = entry.valid && operand_ready && !selected_fu_busy && !Global_Flush_Late;
```

- `entry.rs1_ready`: set at **dispatch time** when source data comes from ARF (no dependency).
- `fast_ready_rs1`: **combinational** bypass match - fires when `bypass_match_rs1` is true. Zero-cycle delay.

**FU Input Data MUX** (combinational at FU input, per source operand):
```verilog
wire [63:0] rs1_source = bypass_match_rs1  -  bypass_data[g] :   // Bypass path: combinational from P3
                         entry.rs1_ready   -  ISQ_sram.rs1_data : // ARF path: data from dispatch
                         64'h0;                                  // placeholder (shouldn't happen)

FU_input.rs1_data = rs1_source;
```

**Two-way MUX**: bypass data (combinational from P3 arbiter) for dependency case, ISQ SRAM data (from ARF at dispatch) for ready case. No registered latch, no CAM path, no posedge clk update.

#### 2.3.2.1 Group-Local FU Enable Decode and Startup

When `entry_select == 1`, the issue path performs a physical local-enable startup, not a software-style function call.

**Physical behavior**:
- The selected group's operand buses (`rs1_source`, `rs2_source`, `rs3_source`, immediate/control context) are made visible to all FUs in that group.
- `exe_subop` is decoded locally into mutually exclusive enable signals.
- Only the FU whose local enable is asserted latches the operands and begins execution.
- All non-selected FUs see the bus physically but keep internal state unchanged because their local enable is low.

Example for Group 0:
```verilog
logic en_alu0, en_bru, en_div, en_csr;

en_alu0 = entry_select && (exe_subop inside GroupShared_ALU_set);

en_bru  = entry_select && (exe_subop inside {G0_BRU_BEQ,
                                             G0_BRU_BNE,
                                             G0_BRU_BLT,
                                             G0_BRU_BGE,
                                             G0_BRU_JAL,
                                             G0_BRU_JALR});

en_div  = entry_select && (exe_subop inside {G0_DIV_DIV,
                                             G0_DIV_DIVU,
                                             G0_DIV_REM,
                                             G0_DIV_REMU});

en_csr  = entry_select && (exe_subop inside {G0_CSR_RW,
                                             G0_CSR_RS,
                                             G0_CSR_RC,
                                             G0_CSR_RWI,
                                             G0_CSR_RSI,
                                             G0_CSR_RCI});
```

Example for Group 1:
```verilog
logic en_alu1, en_mul;

en_alu1 = entry_select && (exe_subop inside GroupShared_ALU_set);

en_mul  = entry_select && (exe_subop inside {G1_MUL_MUL,
                                             G1_MUL_MULH,
                                             G1_MUL_MULHSU,
                                             G1_MUL_MULHU});
```

For Group 2 and Group 3, the decode is trivial because there is only one FU:
```verilog
en_fpu = entry_select;  // Group 2 only
en_lsu = entry_select;  // Group 3 only
```

**Required decode invariant**:
```text
For any legal issued instruction:
    exactly one local FU enable within the selected group must be 1

For any illegal or unimplemented exe_subop pattern:
    no FU may start execution
    implementation must either block the instruction earlier or raise an assertion / illegal-instruction path
```

**Why no confusion occurs when all FUs see the bus**:
- Operand visibility is not execution permission.
- Execution starts only in the FU whose local enable is asserted.
- Non-selected FUs ignore the presented operands because their local enable is low.

**Multi-cycle self-locking rule**:
- When a multi-cycle FU such as `DIV` or `MUL` accepts its local enable, it raises its own busy signal on the next cycle.
- That busy signal feeds back into `selected_fu_busy`, preventing a new instruction targeting that same FU from issuing until the FU becomes free again.

---

#### 2.3.3 P1 -> ISQ -> P2 Data Flow - Complete Picture

```text
P1 (DSP, combinational): ISB -> DST_REG read -> stall check -> ISQ_Payload -> ISQ write enable
    Stall check: P1_Stall = Condition_A | Condition_B (stall conditions in Section 2.2.3)
    Dispatch gate: P1 dispatches freely when ISQ not full AND ROB not full.
    P1 NEVER checks selected-FU busy - it only checks capacity, not execution state.

ISQ (depth=1 per group, per pipeline stage):
    Entry valid bit set at P1 dispatch (posedge clk).
    Entry sits in ISQ until BOTH conditions true:
      1. Operand ready:  rs_ready=1 (ARF) OR fast_ready=1 (bypass match)
      2. FU available:   selected_fu_busy == 0
    If operands ready but selected FU busy -> entry held in ISQ.
    If selected FU free but operands not ready -> entry held in ISQ.

P2 (FU execution):
    entry_select asserts.
    exe_subop local decode asserts exactly one FU enable inside the selected group.
    That FU latches the operands and starts execution.
    FU executes, completes -> P3 arbiter resolves -> bypass broadcast + ROB write.
```

**Multi-cycle FU scenario** (e.g., MUL):

```text
Cycle N:   inst0 enters P2 (MUL), ISQ_1 empty. mul_busy=1 starts.
Cycle N+1: inst3 assigned to Group 1 with exe_subop selecting MUL, dispatches into ISQ_1. operand_ready=1, mul_busy=1 -> held in ISQ.
Cycle N+2: inst3 still in ISQ. operand_ready=1, mul_busy=1 -> still held.
Cycle N+3: inst0 completes MUL. selected_fu_busy=0 for MUL. operand_ready=1 -> inst3 enters P2 immediately.
```

**Key boundary**: P1 (dispatch) is decoupled from FU state via ISQ. P1 only checks capacity (`ISQ_full`, `ROB_full`). ISQ acts as the buffer between dispatch and execution, independently checking operand readiness and the busy state of the FU selected by `exe_subop` before allowing entries into P2.

#### 2.3.4 Functional Unit Execution

| Group | FU | Special Behavior |
|---|---|---|
| 0 | BRU | Evaluates branch condition. On mispredict: sets `mispredict_flag=1`, writes `correct_pc`, forwards via normal Result_Payload (no immediate flush) |
| 0 | DIV | Multi-cycle. Loses arbiter -> internal skid buffer, retries next cycle |
| 0 | CSR | Executes only after entering from a quiescent backend state. May produce a temporary GPR result through the normal ROB path, but no younger instruction may dispatch while the CSR remains in flight, and architectural CSR side effects become visible only at P4 commit |
| 1 | MUL | Multi-cycle (Wallace tree). Same skid buffer behavior |
| 3 | LSU | AGU stage for address computation -> L1Dcache for data. Sends `agu_early_tag` predictively |

**FU issue acceptance contract**:
- `selected_fu_busy` is sampled from the start-of-cycle FU state.
- If `selected_fu_busy == 0` and `entry_select == 1`, that FU must accept the instruction in that cycle.
- A FU must not retract that acceptance later in the same cycle because of a late downstream response.
- External backpressure must be represented by keeping `selected_fu_busy == 1`, not by a same-cycle reject after `entry_select`.

**FU busy lifecycle contract**:
- For multi-cycle FUs, `fu_busy` must remain `1` throughout:
  - active execution
  - completed-but-waiting-for-writeback state
  - any arbitration-loser hold/retry state
- Therefore a FU in hold after losing group arbitration is still considered busy and must not accept a new instruction.

**Trap-on-execute rule**:
- Any instruction whose execution semantics are a synchronous trap must assert `exception_flag=1` and provide the architectural `exception_cause`.
- This includes at minimum:
  - `EBREAK`
  - `ECALL`
  - illegal instruction / illegal operand cases
- `MRET` / `SRET` are control-flow redirects, not synchronous exceptions; they follow the normal control-transfer path instead of the trap path.

---

### 2.4 P3 - Intra-Group Arbitration & Writeback

**Purpose**: Resolve physical writeback port contention from OoO execution. Drive 4-wide Bypass broadcast to ISQ wakeup network.

#### 2.4.1 Intra-Group Arbiter

Within each group, if multiple FUs complete simultaneously, arbiter resolves using **static priority**:

| Group | Priority Order |
|---|---|
| 0 | ALU0 > BRU > CSR > DIV |
| 1 | ALU1 > MUL |
| 2 | FPU (only one) |
| 3 | LSU (only one) |

**Winner**: Gains access to MUX path -> data flows to ROB and Bypass bus.
**Loser**: Internal `Hold` signal freezes result and Tag in output buffer register -> retries next cycle. While that hold is pending, the losing FU remains busy and must not accept a new instruction.

This revision intentionally keeps static priority only. No fairness or anti-starvation mechanism is specified in the backend contract.

**Flush rule for loser-hold state**:
- Any FU-local speculative completion-hold state used to retry P3 writeback in a later cycle must be synchronously cleared by `Global_Flush_Late`.
- A flush-caused younger instruction must not be allowed to reappear later at P3 from a stale hold/skid buffer.

#### 2.4.2 4-Wide Writeback & Bypass Broadcast

Four independent groups provide up to 4 concurrent data paths per cycle.

**ROB Write** (4-port DFF array):
```
for g in [0..3]:
    if (Group[g].Result_valid && !Global_Flush_Late):
        ROB.WRITE(
            waddr = Group[g].tag_out,
            wdata = Group[g].result_data,
            wen   = 1
        )
```
In parallel with `result_data`, the ROB updates its non-PC metadata for that tag (`done`, `rd_idx`, `rd_is_fp`, `mispredict_flag`, `exception_flag`, `is_csr`, `csr_write_enable`, and any other retire-time state). Precise PC-related metadata is handled separately by `ROB_MetaArray[tag_out]`, not stored in ROB. The actual CSR write payload (`csr_addr`, `csr_wdata`) is captured in `CSR_PEND_BUF`, not in ROB.

**Same-cycle flush priority**: `Global_Flush_Late` is the recovery boundary and wins over any same-cycle P3 result publication. If `Global_Flush_Late == 1`, same-cycle P3 `Result_Payload` values may exist on local FU/arbiter wires, but they must not update ROB, `ROB_MetaArray`, CSR pending state, or any other persistent backend state.

**Bypass Broadcast** (4 independent buses, fan-out to all 4 ISQs):
```
for g in [0..3]:
    Bypass[g] = '{
        valid:      Group[g].Result_valid && !Global_Flush_Late,
        tag:        Group[g].tag_out,       // 4-bit
        data:       Group[g].result_data,   // 64-bit
        is_fp:      Group[g].is_fp,
        rd_idx:     Group[g].rd_idx
    }
```

Bypass drives:
- All 4 ISQ tag comparators for wakeup (combinational fast path)
- P1 stall logic (Condition A: `bypass_valid[g] && wait_tag==bypass_tag[g]`)

**Note**: The Bypass bus replaces the previously defined CDB. It carries the same data (tag + result_data) and serves as the combinational fast path to ISQ Select. Purely combinational - no registered CAM, no flip-flop. During `Global_Flush_Late`, bypass `valid` is forced low so P1 and P2 cannot observe a killed same-cycle producer as a real wakeup source.

#### 2.4.3 ROB Tag Collision Immunity

**No arbitration needed** for 4-write-port ROB. Guarantee:

1. **Sequential allocation**: `self_rob_tag` assigned in program order by ROB allocator. At most 16 in-flight instructions -> all alive tags are unique.
2. **Orthogonal addresses**: 4 concurrent `tag_out` values must belong to 4 different instructions -> mathematically impossible for two to be equal.
3. **Direct wiring**: Each `tag_out` hardwired to one of 4 independent `WADDR` ports. No contention.

#### 2.4.4 ROB Metadata Array (ROB_MetaArray)

To keep ROB compact, the backend uses a separate ROB-depth `ROB_MetaArray` for precise PC and recovery metadata. ROB stores only retirement data and flush flags; it does **not** store instruction PCs or branch-correction PCs.

`ROB_MetaArray` is indexed directly by ROB tag. For any live instruction with physical tag `t`, the corresponding metadata entry is `ROB_MetaArray[t]`.

**Per-entry fields**:
```text
inst_pc           // original instruction PC
flush_valid       // 1 if flush metadata is present for this tag
flush_kind        // 2'b01 = mispredict, 2'b10 = exception
target_pc         // branch correct target when flush_kind = mispredict
exception_cause   // valid only when flush_kind = exception
```

Because the array index already identifies the instruction, the entry itself does **not** need to store `tag`.

**Write policy at P1 allocation**:
- Every successfully dispatched instruction initializes `ROB_MetaArray[self_rob_tag]`:
```text
ROB_MetaArray[self_rob_tag].inst_pc         = ISB.pc
ROB_MetaArray[self_rob_tag].flush_valid     = 0
ROB_MetaArray[self_rob_tag].flush_kind      = NONE
ROB_MetaArray[self_rob_tag].target_pc       = 64'h0
ROB_MetaArray[self_rob_tag].exception_cause = 64'h0
```

This guarantees that all in-flight instructions have a precise PC available by tag, even if they never mispredict or raise an exception.

**Write policy at P3 completion**:
- Any `Result_Payload` with `mispredict_flag == 1` updates the flush fields at `ROB_MetaArray[Group[g].tag_out]`:
```text
ROB_MetaArray[tag_out].flush_valid     = 1
ROB_MetaArray[tag_out].flush_kind      = MISPREDICT
ROB_MetaArray[tag_out].target_pc       = Group[g].correct_pc
ROB_MetaArray[tag_out].exception_cause = 64'h0
```
- Any `Result_Payload` with `exception_flag == 1` updates the flush fields at `ROB_MetaArray[Group[g].tag_out]`:
```text
ROB_MetaArray[tag_out].flush_valid     = 1
ROB_MetaArray[tag_out].flush_kind      = EXCEPTION
ROB_MetaArray[tag_out].target_pc       = 64'h0
ROB_MetaArray[tag_out].exception_cause = Group[g].exception_cause
```

`inst_pc` is **not** written at P3. It was already initialized at P1 allocation. Because live ROB tags are unique within the 16-entry window, different groups may update different `ROB_MetaArray[tag_out]` entries in the same cycle without any oldest-candidate reduction.

**Read policy**:
- P2 Group 0 BRU-class operations should use `ISQ_Payload.pc` on the fast execution path when control-flow resolution requires the original PC.
- P2 Group 0 AUIPC also uses `ISQ_Payload.pc` for `pc+imm`; Group 1/2/3 execution paths do not consume live PC.
- P4 uses the selected flush-source tag as a direct index into `ROB_MetaArray[flush_tag]`.
- Commit-trace or debug sinks may also read `ROB_MetaArray[commit_tag].inst_pc` at normal retirement.
- If a ROB entry reaches P4 with `mispredict_flag == 1` or `exception_flag == 1` but `ROB_MetaArray[flush_tag].flush_valid == 0`, that is an illegal RTL state.
- If a synchronous flush event is selected at P4, `ROB_MetaArray[flush_tag].flush_valid` must be 1 and `ROB_MetaArray[flush_tag].flush_kind` must match the selected event kind. These are valid RTL assertions.

**Lifetime**:
- On successful P1 dispatch acceptance of a new instruction allocating ROB tag `t`, `ROB_MetaArray[t].inst_pc` is overwritten and `flush_valid` is cleared to 0. This prevents stale flush metadata from surviving tag reuse.
- `inst_pc` remains meaningful for all live ROB entries until they retire or are flushed.
- `Global_Flush_Late` may bulk-clear all `ROB_MetaArray.flush_valid` bits synchronously through `Clear_MetaArray_FlushValid`. Bulk-clearing `inst_pc` is not required for correctness.

#### 2.4.5 CSR Quiesce Tracker and Pending Sideband

CSR handling uses a dedicated backend-global sequential control block. It is **not** stored in ROB, `DST_REG`, or the architectural CSR file.

**State elements**:
```text
csr_inflight_valid   // 1-bit dispatch/quiesce tracker
csr_inflight_tag     // 4-bit ROB tag of the only in-flight CSR

csr_pend_valid       // 1-bit commit-side-effect buffer valid
csr_pend_tag         // 4-bit ROB tag of the CSR owning the pending side effect
csr_pend_addr        // 12-bit CSR address
csr_pend_wdata       // 64-bit new CSR value to be written at commit
```

**Meaning**:
- `csr_inflight_*` is a dispatch-time CSR barrier resource. P1 reads it every cycle to decide whether a CSR may enter the machine and whether any younger instruction may dispatch while that CSR remains in flight.
- `csr_pend_*` is a P3-to-P4 sidecar buffer carrying the actual architectural CSR side effect. It is written only after CSR execution completes.

**Dispatch-time rule at P1**:
- A slot decoded as CSR may dispatch only if it is `slot0`, `ROB_empty == 1`, and `csr_inflight_valid == 0`.
- A CSR in `slot1` is always blocked; it must wait until it becomes the `ISB` head in a later cycle.
- If `slot0` is accepted as CSR, `slot1` is blocked regardless of `slot1` type.
- After the CSR has been accepted, no younger instruction may dispatch until that CSR commits or flushes.
- While `csr_inflight_valid == 1`, P1 must block all younger dispatch.

**Set / clear timing of `csr_inflight`**:
- Set: at successful P1 dispatch acceptance of a CSR instruction
```text
csr_inflight_valid_next = 1
csr_inflight_tag_next   = self_rob_tag
```
- Clear: only when that CSR commits normally at P4, or when `Global_Flush_Late` occurs

This means CSR lifetime is defined from **successful P1 dispatch acceptance** until **P4 commit or global flush**. During this lifetime, the backend does not dispatch any younger instruction.

**P3 write-allocate rule for `CSR_PEND_BUF`**:
- When a CSR instruction finishes execution in Group 0, wins Group 0 arbitration, and `csr_write_enable == 1` with `exception_flag == 0`, write:
```text
csr_pend_valid <= 1
csr_pend_tag   <= Group0.tag_out
csr_pend_addr  <= Group0.csr_addr
csr_pend_wdata <= Group0.csr_wdata
```
- If `csr_write_enable == 0` (read-only CSR form), do **not** allocate `CSR_PEND_BUF`
- If `exception_flag == 1`, do **not** allocate `CSR_PEND_BUF`

Because `csr_inflight` guarantees at most one CSR in flight and no younger instruction may dispatch around it, `CSR_PEND_BUF` never faces multi-entry contention in legal RTL.

**P4 consume rule**:
- If `ROB[head].is_csr == 1`, then `csr_inflight_valid` must be 1 and `csr_inflight_tag == head_tag`
- If `ROB[head].is_csr == 1 && ROB[head].csr_write_enable == 1`, then:
```text
csr_pend_valid == 1
csr_pend_tag   == head_tag
```
must hold before the architectural CSR file write occurs

These are valid RTL assertions.

**Flush rule**:
- `Global_Flush_Late` clears both `csr_inflight_valid` and `csr_pend_valid`
- No architectural CSR rollback is required because CSR state is never updated before commit

---

### 2.5 P4 - In-Order Commit & Late Flush

**Purpose**: Architectural consistency. In-order retire, DST_REG cleanup, and global rollback on speculative failure. ROB provides the done/flag ordering point, while `ROB_MetaArray[tag]` provides the precise PC metadata needed for commit trace, interrupt save-PC, and flush recovery.

#### 2.5.1 2-Wide In-Order Commit

ROB maintains FIFO circular buffer. Each cycle, 2 read ports check `ROB_head` and `ROB_head + 1`.

Define:
```text
head0_tag       = ROB_head
head1_tag       = ROB_head + 1

head0_done      = ROB[head0_tag].done
head0_exception = ROB[head0_tag].exception_flag
head0_mispredict = ROB[head0_tag].mispredict_flag
head0_can_commit = head0_done && !head0_exception && !head0_mispredict

head1_done      = ROB[head1_tag].done
head1_exception = ROB[head1_tag].exception_flag
head1_mispredict = ROB[head1_tag].mispredict_flag
head1_can_commit = head1_done && !head1_exception && !head1_mispredict
```

**Commit evaluation order**:
1. Evaluate `head0` first.
2. If `head0_done == 0`, commit nothing and ignore `head1`.
3. If `head0_exception == 1`, commit nothing; Late Flush is selected from `head0`.
4. If `head0_mispredict == 1`, commit `head0` itself, then Late Flush is selected from `head0`.
5. If `head0_can_commit == 1`, commit `head0`.
6. Only after a successful `head0` commit may `head1` be evaluated.
7. If `head1_done == 0`, stop after committing only `head0`.
8. If `head1_exception == 1`, commit `head0` only; Late Flush is then selected from `head1` in the same cycle.
9. If `head1_mispredict == 1`, commit both `head0` and `head1`, then Late Flush is selected from `head1` in the same cycle.
10. If `head1_can_commit == 1`, commit both `head0` and `head1`.

This is the exact 2-wide commit contract: `head1` is never allowed to commit or flush ahead of an older blocked `head0`.

For Stores, `head*_done` from the normal execution/writeback path means the store has completed AGU and entered the LSU/L1D-side store buffer. It is not sufficient for architectural commit; the store must also complete the drain protocol described below.

**Store commit width rule**:
- Overall retirement width remains 2 instructions/cycle.
- However, at most **one** store drain request may be launched per cycle (`STORE_DRAIN_REQ_WIDTH = 1`).
- Store execution/buffering completion is not architectural commit.
- A store at the ROB head first requests L1D-side drain and remains at the ROB head while the drain is in progress.
- A store is eligible for normal commit only after the LSU/L1D-side subsystem reports `Store_Done` for that tag.
- If both `head0` and `head1` are stores, only the older store may be considered for drain or commit in that cycle.
- A younger non-store may not commit past a head store waiting for `Store_Done`.

**Per committed instruction**:
```text
    if (commit_valid):
    // 1. Write result to ARF
    ARF.write(addr=rd_idx, data=result_data, is_fp=rd_is_fp)

    // 1b. Apply any architectural side effect owned by this ROB entry
    //     (for example CSR state update)
    if (ROB[head].is_csr):
        assert(csr_inflight_valid && (csr_inflight_tag == commit_tag))

        if (ROB[head].csr_write_enable):
            assert(csr_pend_valid && (csr_pend_tag == commit_tag))
            CSR.write(addr=csr_pend_addr, data=csr_pend_wdata)

        // clear CSR quiesce / pending-side-effect state
        csr_inflight_valid = 0
        csr_pend_valid     = 0

    // 2. Clear DST_REG busy bit
    if (DST_REG[rd_idx].tag == commit_tag):
        DST_REG[rd_idx].busy = 0
```

**P1 visibility of same-cycle normal commits**:
- The architectural effect of a normal P4 commit is considered visible to P1 source resolution in the same cycle.
- This visibility must be implemented through the explicit same-cycle commit overlay described in Section 2.2.1.
- P1 must not rely solely on implementation-specific ARF/DST_REG same-cycle write/read behavior to observe committed values.

**Same-cycle `DST_REG` conflict rule**:
- If a same-cycle younger `P1` allocation write targets the same `DST_REG` entry as an older same-cycle `P4` tag-matched clear, the younger allocation mapping wins for the persistent next-state.
- The older commit still retires architecturally, but it must not erase the newer producer mapping.

**Store drain request for head stores**:
- If a buffered store reaches the ROB head and has not yet completed drain, P4 emits:
```text
Store_Drain_Req_Valid = 1
Store_Drain_Req_Tag   = head_store_tag
```
- `Store_Drain_Req_Tag` asks the L1D-side store buffer to start draining that exact store. It is not architectural commit.
- At most one `Store_Drain_Req_Tag` may be emitted per cycle.
- If both `head0` and `head1` are stores, only the older `head0` may be considered in that cycle.
- If a head store has not yet entered the L1D-side store buffer, that store blocks retirement at ROB head and no drain request may be emitted for it.
- When L1D/LSU later reports `Store_Done_Valid/Tag`, P4 may commit the matching store if it is still at the precise commit boundary.
- If `Store_Done_Exception` is reported, the matching store is treated as a precise exception source instead of a normal commit.

**Commit count before flush**:
```text
commit_count_before_flush =
    0 if exception flush selected from head0
    1 if head0 mispredict (head0 commits, then flush)
    1 if head0 commits normally and head1 exception flush selected
    2 if head0 commits normally, head1 commits, then head1 mispredict flush selected
    2 if both instructions commit normally and no flush is selected
```
If a flush is selected, `ROB_head` first advances by the number of older same-cycle commits represented by `commit_count_before_flush`; `Reset_ROB_Pointers` then forces `ROB_tail` to that same post-commit head position.

**Exception vs Mispredict commit behavior**:
- **Exception**: The faulting instruction does NOT commit. `commit_count_before_flush = 0` (head0 exception) or `1` (head1 exception after head0 normal commit).
- **Mispredict**: The mispredicted branch DOES commit before flush. This is necessary for JAL/JALR to write their return address to the destination register. `commit_count_before_flush` includes the mispredicted branch itself.

If an external interrupt is taken after the normal commit evaluation, the same commit-count mechanism is reused for the number of older same-cycle normal commits that completed before the interrupt redirect.

#### 2.5.2 Late Flush State Machine

Flush is triggered only from the architectural commit boundary selected by the algorithm above. This is the defining characteristic of Late Flush.

**Synchronous flush sources**:
- `head0` with `mispredict_flag == 1`
- `head0` with `exception_flag == 1`
- `head1` with `mispredict_flag == 1`, but only after `head0` commits normally
- `head1` with `exception_flag == 1`, but only after `head0` commits normally

**Metadata source**:
- P4 does **not** read `pc` or `correct_pc` from ROB.
- Instead, P4 reads the indexed `ROB_MetaArray[flush_tag]` entry using the selected flushing ROB tag.

**Per-kind recovery behavior**:
```text
if (flush_kind == MISPREDICT):
    Flush_Target_PC = ROB_MetaArray[flush_tag].target_pc

if (flush_kind == EXCEPTION):
    CSR.mepc   = ROB_MetaArray[flush_tag].inst_pc
    CSR.mcause = ROB_MetaArray[flush_tag].exception_cause
    Flush_Target_PC = CSR.mtvec   // or trap-vector logic derived from mtvec
```

**Flush actions** (all combinational, take effect at next `posedge clk`):

| Signal | Target | Behavior |
|---|---|---|
| `Global_Flush_Late` | P0, P1, P2 | Synchronous clear - sets `valid = 0` for all visible ISB output slots, `Issue_queue` entries, FU pipeline registers, and all multi-cycle FU internal speculative state. Connected as data-path control, **NOT** as async reset pin. |
| `Flush_Target_PC` | IFU | Branch mispredict uses `ROB_MetaArray[flush_tag].target_pc`; exception uses trap-vector redirect logic; interrupt uses next-architectural-PC logic after same-cycle commits |
| `Reset_ROB_Pointers` | ROB | `ROB_tail = ROB_head + commit_count_before_flush` - drains all younger speculative entries after any older same-cycle commits |
| `Clear_All_Busy` | P1 DST_REG | Bulk clears all 32 entries in both INT_DST_REG and FP_DST_REG |
| `Clear_MetaArray_FlushValid` | ROB_MetaArray | Bulk clears `flush_valid` bits synchronously so no stale recovery metadata survives the flush |
| `Clear_CSR_Trackers` | CSR control block | Clears `csr_inflight_valid` and `csr_pend_valid` synchronously |
| `Store_Drain_Req_Valid` | LSU / L1D-side store buffer | Requests drain for one buffered head store; does not commit it |
| `Store_Drain_Req_Tag` | LSU / L1D-side store buffer | ROB tag of the single store requested to drain |
| `Store_Done_Valid/Tag` | ROB / P4 | Reports completed store drain so the matching head store may commit or raise precise exception |

All multi-cycle FUs must also consume `Global_Flush_Late` as a synchronous clear for:
- internal datapath flip-flops
- internal state machines
- any deferred writeback hold/skid state
- any pending `result_valid` for a pre-flush in-flight instruction

After a flush:
- `fu_busy` must be `0` starting the next cycle
- a flushed older instruction must never later reappear with `result_valid=1`
- `P2` must not launch a new FU transaction in the same cycle that `Global_Flush_Late` is asserted
- same-cycle alloc-side writes and `isb_dequeue` activity are squashed
- same-cycle P3 writeback, flush-metadata capture, CSR pending capture, and bypass wakeup are suppressed for all non-architectural younger results

**Why Clear_All_Busy is 100% safe**:

1. Flush fires at `ROB_head` - all instructions older than the flushed instruction have already been committed to ARF.
2. All instructions remaining in pipeline/queues/ROB are **younger** than the flushed instruction (speculative/ poisoned).
3. All `busy` states in DST_REG are fake mappings from these poisoned instructions.
4. Clearing all `busy` bits discards all fake mappings.
5. Next cycle, new correct instructions see `busy == 0`, read directly from clean ARF state.

**Synchronous Flush Implementation**:

`Global_Flush_Late` must be implemented as a **synchronous clear** in RTL:
```verilog
always @(posedge clk) begin
    if (flush) begin
        valid <= 1'b0;
    end else begin
        // normal operation
    end
end
```
This ensures static timing analysis (STA) closure and clock-domain safety.

**Side note on L1D black-box state**:
- The backend contract does not define L1D internals.
- However, if L1D internally retains younger speculative memory requests, it may also need a flush-aware discard path so those requests cannot later become architecturally visible after `Global_Flush_Late`.

**Interrupt priority rule**:
- Synchronous instruction-originated events (`mispredict_flag`, `exception_flag`) always take priority over an external interrupt in the same cycle.
- External interrupts are taken only when no synchronous flush event is selected from `head0` or `head1`.

---

## 3. Payload Interface Definitions

### 3.1 P0 -> P1: ISB_Payload (per slot)

Carries decoded instruction metadata from the frontend side of ISB to the P1 DSP rename/dispatch logic.

| Signal | Width | Description |
|---|---|---|
| `inst_valid` | 1 | Instruction valid flag |
| `pc` | 64 | Program counter |
| `exe_type` | 2 | Execution group selector (0=ALU0/BRU/DIV/CSR, 1=ALU1/MUL, 2=FPU, 3=LSU) |
| `exe_subop` | 6 | Group-local operation control word forwarded to FU. Interpreted only after `exe_type` selects the execution group. |
| `rd_idx` | 5 | Destination logical register index (0-31) |
| `rs1_idx` | 5 | Source 1 logical register index |
| `rs2_idx` | 5 | Source 2 logical register index |
| `rs3_idx` | 5 | Source 3 logical register index (FMA) |
| `use_rd` | 1 | Destination register used |
| `use_rs1` | 1 | Source 1 used |
| `use_rs2` | 1 | Source 2 used |
| `use_rs3` | 1 | Source 3 used |
| `rd_is_fp` | 1 | Datapath routing: 1=FP, 0=INT |
| `rs1_is_fp` | 1 | FP/INT routing for source 1 |
| `rs2_is_fp` | 1 | FP/INT routing for source 2 |
| `rs3_is_fp` | 1 | FP/INT routing for source 3 |
| `imm_valid` | 1 | Immediate valid flag |
| `imm_data` | 64 | Sign-extended immediate data |
| `pred_taken` | 1 | BPU predicted branch direction |
| `pred_target_pc` | 64 | BPU predicted target address |

### 3.2 P1 -> P2: ISQ_Payload (per entry, per group)

Logical register semantics removed; fully tag-based physical scheduling unit.

| Signal | Width | Description |
|---|---|---|
| `isq_valid` | 1 | Queue entry valid |
| `self_rob_tag` | 4 | Physical tag assigned by ROB allocator (0x0-xF) |
| `exe_subop` | 6 | Forwarded group-local operation control word |
| `rs1_ready` | 1 | Source 1 operand ready (1) or waiting (0) |
| `rs2_ready` | 1 | Source 2 operand ready or waiting |
| `rs3_ready` | 1 | Source 3 operand ready or waiting (FMA) |
| `rs1_data` | 64 | Source 1 data (from ARF at dispatch when rs_ready=1; placeholder 64'h0 when rs_ready=0 - actual data routed via FU input MUX from bypass) |
| `rs2_data` | 64 | Source 2 data |
| `rs3_data` | 64 | Source 3 data |
| `rs1_wait_tag` | 4 | Producer tag for Bypass snooping (4'h0 if ready) |
| `rs2_wait_tag` | 4 | Producer tag for source 2 |
| `rs3_wait_tag` | 4 | Producer tag for source 3 |
| `pc` | 64 | Group 0 AUIPC/BRU fast-path PC context; non-Group0 execution paths do not consume live PC |
| `pred_taken` | 1 | Group 0 branch prediction context; non-Group0 writes may tie low |
| `pred_target_pc` | 64 | Group 0 predicted target for branch resolution; non-Group0 writes may tie zero |
| `is_store` | 1 | LSU store flag (for memory ordering) |
| `store_data` | 64 | Store data payload |
| `store_mask` | 8 | Store byte/word lane mask |
| `store_size` | 3 | Store access size encoding |

### 3.3 P3 -> P4 / Bypass: Result_Payload (per group, 4-wide)

Physical writeback of execution results and driving the Bypass wakeup network. Instantiated 4 times (one per group).

| Signal | Width | Description |
|---|---|---|
| `result_valid` | 1 | Writeback and Bypass broadcast enable |
| `tag_out` | 4 | Global broadcast tag (drives ISQ tag comparators, P1 stall logic, and indexes `ROB_MetaArray[tag_out]`) |
| `result_data` | 64 | Computation or memory result |
| `exception_flag` | 1 | Hardware exception indicator (div-by-zero, page fault, illegal operand) |
| `mispredict_flag` | 1 | Branch mispredict flag (asserted only by Group 0 BRU) |
| `correct_pc` | 64 | Actual branch target for pipeline recovery (branch mispredict only) |
| `exception_cause` | 64 | Precise trap cause written into `ROB_MetaArray[tag_out]` on exception |
| `is_csr` | 1 | Marks that this instruction is a CSR op |
| `csr_write_enable` | 1 | Indicates this CSR op has an architectural CSR side effect |
| `csr_addr` | 12 | CSR address written into `CSR_PEND_BUF` when `csr_write_enable == 1` |
| `csr_wdata` | 64 | New CSR value written into `CSR_PEND_BUF` when `csr_write_enable == 1` |
| `is_fp` | 1 | Destination type routing |
| `rd_idx` | 5 | Logical destination register index (0-31) |

**Bypass bus** (broadcast from P3 arbiter outputs to all 4 ISQ modules):
```
Bypass_valid[4]   - 4 bits (one per group arbiter winner)
Bypass_tag[4][3:0] - 16 bits (one 4-bit tag per group)
Bypass_data[4][63:0] - 256 bits (one 64-bit result per group)
```
Total: 276 bits broadcast combinational from P3 to all 4 ISQ Select stages. Enables back-to-back issue.

### 3.4 P4 -> ARF: Commit_Payload (per commit, 2-wide)

Final architectural state commitment when ROB head advances.

| Signal | Width | Description |
|---|---|---|
| `commit_valid` | 1 | `ROB[head].done == 1 && mispredict_flag == 0 && exception_flag == 0`, ready for ARF writeback |
| `commit_tag` | 4 | Equals `ROB_head` pointer |
| `rd_idx` | 5 | Logical destination register index (0-31) |
| `rd_is_fp` | 1 | Write port routing: 1=FP_ARF, 0=INT_ARF |
| `result_data` | 64 | Clean, non-speculative data written to ARF |

### 3.5 Global Flush Control Signals (P4 -> P0/P1/P2)

Asserted when P4 selects a Late Flush event from `head0` / `head1` or takes an external interrupt.

| Signal | Target | Behavior |
|---|---|---|
| `Global_Flush_Late` | P0, P1, P2 | Synchronous clear for all valid flip-flops |
| `Flush_Target_PC` | IFU | Branch mispredict uses `ROB_MetaArray[flush_tag].target_pc`; exception uses trap vector; interrupt uses next-architectural-PC logic after same-cycle commits |
| `Reset_ROB_Pointers` | ROB | `ROB_tail = ROB_head + commit_count_before_flush` (drain speculative) |
| `Clear_All_Busy` | DST_REG (P1) | Bulk clear all busy bits in INT_DST_REG and FP_DST_REG |
| `Clear_MetaArray_FlushValid` | ROB_MetaArray | Bulk clear all `flush_valid` bits in the recovery metadata array |
| `Clear_CSR_Trackers` | CSR control block | Clears `csr_inflight_valid` and `csr_pend_valid` |

### 3.6 LSU Predictive Wakeup Signal

| Signal | Width | Source | Target | Description |
|---|---|---|---|---|
| `agu_early_tag` | 4 | Group 3 AGU (registered) | P1 DSP | Predictive tag for dependent instruction release. Registered at AGU output, 1-cycle latency to P1. |

---

## 4. LSU Behavior - L1D Black-Box Boundary Model

### 4.1 Physical Definition

The Group 3 LSU presents AGU-generated requests to an L1D-side memory subsystem treated as a black box. The backend defines only request/backpressure behavior plus a store drain request / store done handshake at the precise commit boundary.

**1. In-order Group 3 Admission**

Without an LSQ for hardware memory disambiguation and alias checking, memory instructions dispatched to Group 3 enter a strict FIFO queue:

- All Load/Store instructions issue in program order within Group 3
- Each ISQ entry depth per group is effectively 1 (single in-flight memory instruction per group)
- AGU remains `Busy` whenever a request cannot leave the `AGU -> L1D` boundary
- No younger memory instruction may bypass an older Group 3 request that is stalled at that boundary

**Store safety rule (precise memory visibility)**:
- A Store instruction may not complete architectural commit before its L1D-side drain has completed.
- In this design, a Store computes address/data at AGU, then enters an L1D-side store buffer when that buffer accepts it.
- Store-buffer acceptance marks execution/buffering completion, not architectural commit.
- When the store becomes oldest at the ROB head, P4 requests drain for that tag.
- The store remains in the store buffer while drain is in progress and remains forwardable to younger loads that alias it.
- The store may commit only after the LSU/L1D-side subsystem reports `Store_Done` for that tag.
- This rule is stricter than merely waiting for older synchronous flush-risk instructions to resolve: it also preserves precise external interrupt semantics, because an interrupt may be taken at the commit boundary after older normal commits while younger speculative instructions are flushed.
- Therefore, without speculative memory rollback machinery, earlier visible stores are not allowed.

**2. AGU -> L1D Request Handoff**

- `Store` performs AGU in Group 3.
- The AGU outputs `{tag, addr, data, mask, size, is_load/is_store}` toward L1D.
- If L1D-side store-buffer space accepts the request (`ready=1`), the AGU/LSU slot may be released.
- If L1D does not accept the request (`ready=0`), the request hard-stalls at the `AGU -> L1D` boundary, keeps `lsu_busy=1`, and backpressures Group 3 issue.
- The accepted store remains tracked by the LSU/L1D side until P4 requests drain and L1D/LSU later returns `Store_Done`.

**3. Load Hard-Stall Path**

- `Load` performs AGU in Group 3, then attempts to enter the `L1D` request side.
- Store drain does not by itself backpressure loads.
- If `L1D` returns explicit load-side backpressure (`ready=0`), the load hard-stalls at the `AGU -> L1D` boundary.
- Any additional internal conflict checks inside L1D are black-box L1D behavior from the backend point of view.
- This stalled load keeps `lsu_busy=1` and backpressures Group 3 issue.
- This design does **not** use replay/re-execute for loads; it uses hard stall at the LSU tail.

**4. Isolated L1 Cache Miss Blocking**

When a Load encounters L1Dcache miss:
- Group 3 pipeline blocked, waiting for memory data return
- **Groups 0, 1, 2 completely unaffected** - independent instructions continue OoO execution via their own queues
- Group 3 issue queue accepts no new entries while busy

**3. Global Backpressure Boundary**

LSU blocking affects the system only through structural hazard:
- Cache miss or `L1D` backpressure -> Group 3 request stuck at LSU tail -> cannot retire progress for that request
- Frontend continues dispatching -> 16-entry ROB fills up
- `ROB_tail == ROB_head` -> `P0_Stall` triggered
- **Before ROB fill-up**: system maintains full-speed OoO execution across all groups

### 4.2 LSU Pipeline

```
P2 (Issue) -> Group 3 LSU FU (AGU + address calc)
                           -> Load path: L1D request -> data return -> Bypass broadcast
                           -> Store path: enter store buffer -> P4 drain request at ROB head -> Store_Done -> commit
                           -> agu_early_tag sent to P1 (registered, 1-cycle)
```

- **Group 3 LSU FU**: Computes `phys_addr = base_reg + offset_imm`, produces load/store request information, and sends `agu_early_tag` to P1 (registered at posedge clk, 1-cycle latency).
- **Load path**: Uses a valid/ready style handoff into `L1D`. If the load side returns explicit backpressure or waits on data, the load hard-stalls at the LSU tail. Store drain in progress is not, by itself, a load-side backpressure reason. On success, returned load data later becomes normal `result_data` and uses the standard P3 bypass path.
- **Store path**: Uses a valid/ready style handoff into the LSU/L1D-side store buffer. Successful acceptance releases the LSU slot and reports execution/buffering completion. P4 later requests drain only when the store is oldest at the ROB head. The store may architecturally commit only after `Store_Done` returns for that tag.
- **Result broadcast**: Real load or arithmetic `result_data` + `tag_out` pushed onto Bypass bus (combinational, same cycle as arbiter resolution). Store data itself is not broadcast as a normal result.

---

## 5. Exception and Interrupt Handling

### 5.1 Exception Flow

All exceptions (divide-by-zero, page fault, illegal operand, memory violation) follow the same Late Flush path:

**Execution Stage (P2)**:
- Functional unit detects exception
- Sets `exception_flag = 1`, writes `exception_cause` into Result_Payload
- No pipeline interruption - normal writeback proceeds

**Writeback (P3)**:
- Result written into ROB at corresponding tag
- `exception_flag` stored in ROB entry metadata
- `ROB_MetaArray[tag_out]` updates `{flush_valid=1, flush_kind=EXCEPTION, exception_cause}` directly at the completing instruction's tag, while `inst_pc` remains the value written earlier at P1 allocation

**Commit Stage (P4)**:
- When the exception-bearing instruction is selected as the flush source by the 2-wide commit algorithm:
  - P4 detects `exception_flag == 1`
  - Reads `ROB_MetaArray[flush_tag]`
  - Writes `ROB_MetaArray[flush_tag].inst_pc` to the trap PC CSR (for example `mepc` in RISC-V)
  - Writes `ROB_MetaArray[flush_tag].exception_cause` to the trap-cause CSR (for example `mcause`)
  - Triggers `Global_Flush_Late` + `Clear_All_Busy` + `Clear_MetaArray_FlushValid`
  - Forces next PC to trap handler base (for example `mtvec` from CSR)

### 5.2 Interrupt Handling

External interrupts are checked at the commit stage only after the head0/head1 commit/flush evaluation has completed for the current cycle.

Priority rule:
- synchronous flush selected from `head0` or `head1`
- eligible older normal commits from `head0` / `head1`
- external interrupt redirect
- continue normal execution with no redirect

Interrupt entry does **not** set `flush_valid` in `ROB_MetaArray`, because it is not tied to an already-completed speculative instruction result.
Interrupt save-PC uses the next architectural PC after any same-cycle normal commits. `ROB_MetaArray` provides `inst_pc` for surviving post-commit head tags when that next PC belongs to an in-flight instruction.

Interrupt save-PC derivation:
- if any normal commit happened earlier in the cycle, use the next architectural PC after those commits
- else if the `ISB` still holds a valid oldest instruction, use `ISB_head.pc`
- else use the frontend-provided non-speculative "next instruction that would execute if the interrupt were not taken" PC
- do not use a younger speculative predicted target as the interrupt save-PC source

External interrupt handling:
```
if (sync_flush_selected):
    handle synchronous late flush first
else:
    // head0/head1 may still commit normally in this cycle
    perform 0/1/2 normal commits according to the P4 commit algorithm

    if (!irq_blocked &&
        csr_ie_enabled &&
        ext_irq_valid == 1):
        CSR.mepc = next_architectural_pc_after_same_cycle_commits
                   // if no same-cycle commit occurred and ISB holds a valid oldest instruction,
                   // this resolves to ISB_head.pc
        trigger Global_Flush_Late
        Flush_Target_PC = exception_vector
```

### 5.3 4-Group Coordination

Exception in any single group does not cause timing interference to other groups:
- Each group broadcasts independently on its own Bypass bus
- Exception flag travels within that group's Result_Payload
- Flush is a global synchronous control signal - single assertion, no arbiter

### 5.4 CSR Instruction Behavioral Specification

CSR instructions execute in **Group 0** and share the Group 0 arbitration / writeback path with `ALU0`, `DIV`, and `BRU`. Their arbitration priority is the Group 0 static priority already defined in Section 2.4.1:
`ALU0 > DIV > BRU > CSR`

**CSR handling is split into three physical pieces**:
1. **Temporary GPR result path** - `old_csr_value` may be produced and written into ROB / bypass like a normal integer result
2. **Dispatch-time serialization barrier tracker** - `csr_inflight_valid/tag` ensures a CSR enters only when the backend is quiescent and blocks all younger dispatch while that CSR remains in flight
3. **Commit-side side-effect buffer** - `CSR_PEND_BUF` holds the real architectural CSR write payload until P4 commit

This means a CSR instruction behaves like a normal ROB producer for its destination register, but it also acts as a serialization barrier, and the CSR state itself remains a commit-time side effect.

**Front-end decode requirement**:
- The decoder must explicitly classify CSR instructions (`is_csr = 1`)
- `exe_type = 0`
- `exe_subop` must decode into the CSR subset of Group 0

**Serialization policy**:
- A CSR instruction may be dispatch-accepted only when the ROB is empty
- A CSR may be accepted only from `slot0`
- If `slot0` is accepted as CSR, `slot1` is blocked regardless of type
- While a CSR is in flight, no younger instruction may dispatch
- CSR vs CSR is serialized across the CSR lifetime
- CSR vs non-CSR is also serialized across the CSR lifetime

**Physical placement of CSR control state**:
- `csr_inflight_*` and `CSR_PEND_BUF` live in a dedicated backend-global sequential CSR control block
- They are **not** stored inside ROB
- They are **not** part of `DST_REG`
- They are **not** architectural CSR-file state

**Dispatch-time rule**:
- P1 reads `csr_inflight_valid` as a normal backend resource bit
- A CSR slot may dispatch only if it is `slot0`, `ROB_empty == 1`, and `csr_inflight_valid == 0`
- If `slot0` is accepted as CSR, `slot1` is blocked in the same cycle even if `slot1` is non-CSR
- In cycles after that CSR has been accepted, younger dispatch remains blocked until the CSR commits or flushes
- While `csr_inflight_valid == 1`, any younger instruction remains blocked

**Set / clear timing of `csr_inflight`**:
- Set: at successful P1 dispatch acceptance of a CSR instruction
```text
csr_inflight_valid_next = 1
csr_inflight_tag_next   = self_rob_tag
```
- Clear: only when that CSR commits normally at P4, or when `Global_Flush_Late` occurs

Because `csr_inflight` is sequential backend state, P1 still sees the pre-commit value during the same cycle that an older CSR commits. Therefore the next younger instruction may dispatch beginning on the following cycle, not in the same combinational cycle as the older CSR's commit.

This defines CSR lifetime from **successful P1 dispatch acceptance** until **P4 commit or global flush**.

**CSR read / read-modify/write semantics**:
- If the CSR instruction returns an old CSR value to an integer destination register, that returned value is computed in Group 0, written into `result_data`, and stored in ROB at P3
- That returned value may later commit to `INT_ARF` at P4 like any other scalar result
- The actual architectural CSR update is never applied at P2 or P3
- The actual architectural CSR update is applied only when the CSR instruction reaches `ROB_head` and commits successfully at P4

**P3 write-allocate rule for `CSR_PEND_BUF`**:
- When a CSR instruction finishes execution in Group 0, wins Group 0 arbitration, and `csr_write_enable == 1` with `exception_flag == 0`, write:
```text
csr_pend_valid <= 1
csr_pend_tag   <= Group0.tag_out
csr_pend_addr  <= Group0.csr_addr
csr_pend_wdata <= Group0.csr_wdata
```
- If `csr_write_enable == 0` (read-only CSR form), do **not** allocate `CSR_PEND_BUF`
- If `exception_flag == 1`, do **not** allocate `CSR_PEND_BUF`

Because `csr_inflight` guarantees at most one CSR in flight, `CSR_PEND_BUF` never faces multi-entry contention in legal RTL.

**Minimal ROB metadata for CSR**:
- `is_csr`
- `csr_write_enable`
- normal retire metadata (`done`, `rd_idx`, `rd_is_fp`, `exception_flag`, etc.)

The ROB must **not** store:
- `csr_addr`
- `csr_wdata`

**P4 commit-time rule**:
- If `ROB[head].is_csr == 1`, then:
```text
csr_inflight_valid == 1
csr_inflight_tag   == head_tag
```
must hold before retirement

- If `ROB[head].is_csr == 1 && ROB[head].csr_write_enable == 1`, then:
```text
csr_pend_valid == 1
csr_pend_tag   == head_tag
```
must hold before the CSR file write occurs

These are valid RTL assertions.

**Commit-time ordering rule**:
- If a CSR instruction commits, its operations occur in program order at P4:
  1. produce any destination-register architectural writeback from ROB to `INT_ARF`
  2. if `csr_write_enable == 1`, write the architectural CSR state from `CSR_PEND_BUF`
  3. clear `csr_pend_valid` and `csr_inflight_valid`
  4. clear rename state and retire the ROB entry

This preserves in-order architectural visibility for both GPR and CSR state.

**Speculative visibility rule**:
- Younger instructions may **not** dispatch past an older in-flight CSR instruction
- Therefore the architectural CSR state observed after a CSR dispatch remains the last committed CSR state until that CSR itself commits
- No CSR renaming or speculative CSR forwarding is defined in this design

**Flush / recovery rule**:
- If a CSR instruction is flushed before commit due to older mispredict / exception / interrupt handling, its ROB entry is discarded
- Any speculative GPR result carried in ROB is discarded normally
- `Global_Flush_Late` clears both `csr_inflight_valid` and `csr_pend_valid`
- Because the architectural CSR state update has not yet been applied, no CSR undo / rollback mechanism is required

**Exception rule for CSR instructions**:
- Illegal CSR access, privilege violation, or read-only CSR write attempts are detected during execution in Group 0
- Such a CSR instruction sets `exception_flag = 1` and records its exception metadata through the normal precise exception path
- The architectural CSR side effect is suppressed because the instruction never reaches successful commit

**Interrupt interaction rule**:
- External interrupts are sampled against committed architectural CSR state only
- A younger interrupt must not observe an uncommitted older CSR update
- Therefore, interrupt enable / trap-vector behavior changes caused by CSR instructions take effect only after that CSR instruction commits

---

## 6. Parameter Summary

| Parameter | Value | Source |
|---|---|---|
| `XLEN` | 64 | RISC-V RV64 |
| `FLEN` | 64 | IEEE 754 double-precision |
| `ISSUE_NUM` | 2 | Dual-issue width |
| `ROB_DEPTH` | 16 | Fixed |
| `ROB_META_DEPTH` | 16 | One metadata entry per ROB tag |
| `ARF_DEPTH` | 32 | RISC-V architectural registers |
| `TAG_W` | 4 | `log2(ROB_DEPTH)` |
| `EXE_SUBOP_W` | 6 | Group-local FU control field width |
| `SEQ_W` | 4 | Same as TAG_W |
| `GROUP_NUM` | 4 | ALU0/BRU/DIV/CSR, ALU1/MUL, FPU, LSU |
| `BYPASS_W` | 4 | One per group (replaces CDB) |
| `COMMIT_WIDTH` | 2 | 2-wide in-order commit |
| `STORE_DRAIN_REQ_WIDTH` | 1 | At most one store drain request may launch per cycle |
| `ISQ_DEPTH_PER_GROUP` | 1 | Single-entry queue per execution group |
