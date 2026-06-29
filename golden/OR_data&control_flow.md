# Microarchitecture Specification: Dual-Issue Out-of-Order Processor Data Flow & Control Logic (Updated Whole Picture)

## 1. Architecture Baseline

Throughput topology: 2-wide In-order Dispatch -> 4-Group Out-of-Order Execute -> 4-wide Out-of-Order Writeback -> 2-wide In-order Commit.

Storage boundary:
- 16-entry ROB (4W2R) for result data and retire-time metadata
- ROB-depth `ROB_MetaArray` for precise per-tag PC and recovery metadata
- split 32x64b INT/FP ARF
- INT_DST_REG = 32 x (busy + 4-bit tag), 4R2W
- FP_DST_REG = 32 x (busy + 4-bit tag), 3R1W
- distributed single-entry Issue Queue per execution group (Group0..Group3)

Execution groups:
- Group 0: ALU0, BRU, DIV, CSR
- Group 1: ALU1, MUL
- Group 2: FPU
- Group 3: LSU

Core invariants:
- Data may be forwarded only through the 4-lane combinational Bypass Network.
- ROB is never used as an operand-forwarding source.
- Dispatch is in order: `slot1` never bypasses a blocked `slot0`.
- Commit is in order: `head1` never commits or flushes ahead of a blocked `head0`.
- ROB does not store PC metadata for late flush recovery; precise control-flow metadata lives in `ROB_MetaArray[tag]`.

## 2. P0 Stage: Instruction Dequeue & Speculation

This stage is the admission boundary between the decoupled frontend and the backend dispatch logic.

```text
1. Present up to 2 head instructions from ISB:
   Slot0 is always evaluated first.
   Slot1 is evaluated only after Slot0, against the updated resource view.

2. Per-slot backpressure check:
   - ROB must not be full.
   - The target ISQ selected by exe_type must be empty.
   - Slot1 cannot reuse an ISQ already claimed by Slot0 in the same cycle.

3. Dequeue rule:
   An instruction is removed from ISB only if DSP successfully writes it into the target ISQ.
   If dispatch is rejected, the instruction stays at the ISB head and retries next cycle.

4. Branch speculation:
   pred_taken + pred_target_pc come from the BPU combinationally.
   No early flush happens here; mispredict recovery is Late Flush at P4.
```

Practical consequence:
- Unrelated groups do not backpressure each other.
- A blocked Group 3 instruction can stall the frontend only when it reaches the ISB head or when the ROB eventually fills.

## 3. P1 Stage: Rename, Dispatch & Deadlock Prevention

This is the most control-heavy stage in the machine. It performs rename, dispatch legality checks, deadlock prevention, and ROB allocation in one combinational path.

```text
ISB -> DST_REG/ARF read -> same-cycle rename overlay -> stall check -> ROB tag assignment -> DST_REG update -> ISQ write
```

### 3.1 Source Resolution

```text
If use_rsX == 0:
    rsX_ready = 1
    rsX_data  = 64'h0
    rsX_wait_tag = 4'h0
Else if source matches a same-cycle normal P4 commit:
    rsX_ready = 1
    rsX_data  = committed result_data
    rsX_wait_tag = 4'h0
Else:
    read INT_DST_REG or FP_DST_REG based on rsX_is_fp
    if busy == 0:
        rsX_ready = 1
        rsX_data  = ARF.read(...)
        rsX_wait_tag = 4'h0
    else:
        rsX_ready = 0
        rsX_data  = 64'h0
        rsX_wait_tag = tag
```

Meaning:
- same-cycle commit overlay represents the post-commit architectural state of the current cycle
- `busy == 0`: source is architecturally ready in ARF
- `busy == 1`: source waits on an older in-flight producer tag

### 3.2 Same-Cycle Dual-Issue Rename Rule

`slot0` resolves first. If `slot0` is accepted and writes a destination, P1 forms a transient same-cycle overlay:

```text
slot0_overlay = {
    valid,
    rd_idx,
    rd_is_fp,
    tag = ROB_tail
}
```

`slot1` checks this overlay before persistent `DST_REG`.

This handles same-bundle RAW correctly:
- `slot1` sees `slot0` as the producer
- `slot1.rs_ready = 0`
- `slot1.rs_wait_tag = slot0.self_rob_tag`

For same-bundle WAW:
- both instructions may still allocate distinct ROB tags in order
- if both write the same logical destination in the same file, the final persistent `DST_REG` mapping after the cycle is the younger `slot1` tag

Overlay priority for `slot1`:
- first `slot0` same-cycle rename overlay
- then same-cycle normal P4 commit overlay
- then persistent `DST_REG/ARF`

This avoids any dependency on ARF/DST_REG same-cycle write/read implementation details.

### 3.3 Dispatch Restrictions

```text
Slot0 may dispatch if:
    - ROB not full
    - target ISQ is free for dispatch in this cycle
    - no deadlock-prevention stall condition fires

Slot1 may dispatch only if:
    - Slot0 already dispatches
    - ROB not full
    - its target ISQ is still free in the virtual post-slot0 view
    - no deadlock-prevention stall condition fires
    - no extra same-cycle rename rule blocks it
```

Here "free for dispatch in this cycle" means:

```text
isq_free_for_dispatch =
    (isq currently empty) ||
    (isq currently occupied by an older entry that will issue this cycle)
```

The same-cycle ordering rule is:

- old entry may issue this cycle
- P1 may refill that ISQ in the same cycle
- the newly written entry does not participate in same-cycle issue; it is visible to Select beginning next cycle

Important rename asymmetry:
- INT_DST_REG is 4R2W, so two INT destination writes in one cycle are allowed
- FP_DST_REG is 3R1W, so at most one FP-destination instruction may be accepted per cycle
- therefore `slot0 = FPU op` plus `slot1 = FP load` cannot dual-dispatch in the same cycle even though they target different execution groups
- CSR is stricter: it may dispatch only from `slot0` when the ROB is empty, and if `slot0` is accepted as CSR, `slot1` is blocked regardless of type

### 3.4 Deadlock Prevention

Because operands cannot be read from ROB, P1 must block instructions that would otherwise enter ISQ too late to catch data.

Priority order:

```text
Condition A: bypass broadcast overlap
    bypass_valid[g] && (wait_tag == bypass_tag[g])

Condition B: data stuck in ROB
    ROB[wait_tag].done == 1 && !same_cycle_commit_match(wait_tag)

Condition C: LSU early wakeup exemption
    wait_tag == agu_early_tag
```

Behavior:
- A or B -> stall dispatch for that instruction
- C cancels the stall for the special LSU predictive-wakeup case
- if the same producer is also committing normally in the current cycle, the explicit P4->P1 commit overlay wins and Condition B must not re-stall that source

Here, `same_cycle_commit_match(wait_tag)` means that one of the normal same-cycle P4 commit slots is retiring that exact producer tag.

### 3.5 ROB Allocation Contract

Tags are allocated strictly in program order:

```text
If only slot0 accepted:
    slot0.tag = ROB_tail

If both accepted:
    slot0.tag = ROB_tail
    slot1.tag = ROB_tail + 1
```

Legal same-cycle allocation patterns:

```text
alloc_valid = 2'b00  no dispatch
alloc_valid = 2'b01  slot0 only
alloc_valid = 2'b11  slot0 + slot1
alloc_valid = 2'b10  illegal
```

Result of P1:
- accepted instructions become tag-based ISQ entries
- rejected instructions remain in ISB
- P1 itself holds no long-lived buffer state

## 4. P2 Stage: Issue, Select & Execute

This stage performs dynamic scheduling with combinational wakeup.

### 4.1 Wakeup and Select

Each single-entry ISQ snoops all 4 bypass lanes every cycle.

```text
fast_ready_rsX = OR over all groups of:
    bypass_valid[g] && (wait_tag == bypass_tag[g])

operand_ready = (rs1_ready || fast_ready_rs1) &&
                (rs2_ready || fast_ready_rs2) &&
                (rs3_ready || fast_ready_rs3)

entry_select = entry.valid && operand_ready && !selected_fu_busy
```

Critical points:
- `rs_ready` is a dispatch-time static flag only
- there is no registered CAM wakeup and no wakeup-time ready flip-flop
- the dependent entry can wake up and issue in the same cycle as bypass
- `selected_fu_busy` must be the busy state of the FU chosen by `exe_subop`, not a whole-group busy bit

Local decode rule:
- `exe_type` selects the group
- `exe_subop` selects the FU inside that group
- Group 0 decodes to `ALU0 / BRU / DIV / CSR`
- Group 1 decodes to `ALU1 / MUL`
- Group 2 always selects `FPU`
- Group 3 always selects `LSU`

That means `DIV busy` blocks only DIV-class instructions, not `ALU0`, `BRU`, or `CSR`, and `MUL busy` blocks only MUL-class instructions, not `ALU1`.

### 4.2 FU Input Data Path

When an operand depended on an older producer:
- ISQ stores only the wait tag and a `64'h0` placeholder
- actual data comes from the FU input MUX directly from bypass

```text
rs1_source =
    entry.rs1_ready ? isq_stored_data :
    bypass_match ? bypass_data :
    64'h0
```

After `entry_select` goes high:
- operand buses are visible to all FUs in the selected group
- `exe_subop` local decode generates mutually exclusive enable signals
- exactly one FU consumes the operands and starts execution
- non-selected FUs see the bus but do not latch it because their local enable is low

### 4.3 FU Behavior

- BRU detects mispredict, produces `correct_pc`, sets `mispredict_flag`, but does not flush immediately
- DIV and MUL are multi-cycle and may retry after losing the P3 arbiter
- any FU that has accepted `entry_select` must not reject it later in the same cycle
- a FU that is holding a completed result for retry after losing P3 arbitration remains busy until that held result wins writeback
- CSR may produce a temporary GPR result through the ROB path, but no younger instruction may dispatch while the CSR remains in flight, and architectural CSR state changes only at commit
- LSU performs AGU internally and sends `agu_early_tag` predictively for Loads
- trap-on-execute instructions such as `EBREAK`, `ECALL`, and illegal-instruction cases must set `exception_flag` / `exception_cause`

## 5. P3 Stage: Intra-Group Arbitration, Writeback & Flush Metadata Capture

This stage resolves physical writeback contention and drives the global bypass network.

### 5.1 Intra-Group Arbitration

Static priority:
- Group 0: ALU0 > BRU > CSR > DIV
- Group 1: ALU1 > MUL
- Group 2: FPU only
- Group 3: LSU only

This revision intentionally keeps static priority only and does not promise fairness or anti-starvation across repeated same-group completions.

Winner:
- writes result into ROB
- broadcasts bypass tag + data

Loser:
- holds result internally and retries next cycle
- keeps its FU-local busy indication asserted while the held result is pending retry

Flush requirement:
- any FU-local hold/skid state and any multi-cycle FU internal execution state associated with younger speculative work must be synchronously cleared by `Global_Flush_Late`
- any FU-local speculative hold/skid state used for later retry must be cleared by `Global_Flush_Late`
- otherwise a younger flushed completion could incorrectly reappear at P3 in a later cycle

### 5.2 ROB Writeback

ROB stores:
- `result_data`
- `done`
- `rd_idx`, `rd_is_fp`
- `mispredict_flag`, `exception_flag`
- `is_csr`
- `csr_write_enable`
- any other retire-time non-PC metadata

ROB does not store:
- `pc`
- `correct_pc`
- `exception_cause`
- `csr_addr`
- `csr_wdata`

### 5.3 ROB_MetaArray

To keep ROB compact, precise control-flow metadata is captured in a separate ROB-depth metadata array indexed by ROB tag.

Per entry:

```text
inst_pc
flush_valid
flush_kind        // mispredict or exception
target_pc         // used by mispredict
exception_cause   // used by exception
```

Indexing rule:

```text
metadata for instruction with tag t lives in ROB_MetaArray[t]
```

Write rule:
- P1 allocation of tag `t` writes `ROB_MetaArray[t].inst_pc` and clears `flush_valid`
- mispredict result with `tag_out = t` -> write `{flush_valid, target_pc, flush_kind=MISPREDICT}` to `ROB_MetaArray[t]`
- exception result with `tag_out = t` -> write `{flush_valid, exception_cause, flush_kind=EXCEPTION}` to `ROB_MetaArray[t]`

Because live ROB tags are unique, different groups may write different metadata entries in the same cycle. No oldest-candidate reduction is needed.

Lifetime rule:
- when a new instruction is allocated ROB tag `t`, overwrite `inst_pc` and clear `ROB_MetaArray[t].flush_valid`
- on global late flush, bulk-clear metadata-array `flush_valid`
- normal commit may optionally clear the committed flush metadata, but correctness requires at least tag-reuse clear plus flush clear

## 6. P4 Stage: In-Order Commit & Late Flush

This stage is the architectural boundary of the machine.

### 6.1 2-Wide Commit Algorithm

Each cycle checks `head0 = ROB_head` and `head1 = ROB_head + 1`.

Evaluation order:

```text
1. Evaluate head0 first.
2. If head0 not done:
       commit nothing, ignore head1.
3. If head0 has exception:
       commit nothing, select flush from head0.
4. If head0 has mispredict:
       commit head0 only, select flush from head0.
5. Otherwise commit head0.
6. Only now evaluate head1.
7. If head1 not done:
       stop after head0 commit.
8. If head1 has exception:
       commit head0 only, select flush from head1.
9. If head1 has mispredict:
       commit both head0 and head1, select flush from head1.
10. Otherwise commit head1 too.
```

Per committed instruction:
- write result to INT_ARF or FP_ARF
- apply commit-time side effects such as CSR write
- clear `DST_REG.busy` if tag matches commit tag

### 6.2 Late Flush Recovery

Late Flush is selected only from the commit boundary described above.

Metadata source:
- P4 does not read recovery PC metadata from ROB
- P4 directly reads `ROB_MetaArray[flush_tag]`

Recovery by kind:

```text
If mispredict:
    Flush_Target_PC = ROB_MetaArray[flush_tag].target_pc

If exception:
    CSR.mepc   = ROB_MetaArray[flush_tag].inst_pc
    CSR.mcause = ROB_MetaArray[flush_tag].exception_cause
    Flush_Target_PC = CSR.mtvec
```

Flush actions:
- `Global_Flush_Late`: clear all visible valid state in P0/P1/P2 synchronously
- `Reset_ROB_Pointers`: drop all younger speculative entries
- `Clear_All_Busy`: bulk clear INT/FP rename busy bits
- `Clear_MetaArray_FlushValid`: bulk clear `ROB_MetaArray.flush_valid`
- same-cycle alloc-side writes are squashed: no ROB tail advance, no `DST_REG` alloc write, no `ROB_MetaArray` alloc-init write, no `ISQ` write, no `isb_dequeue`
- same-cycle `P2` issue launches are squashed

Important same-cycle detail:
- if `head0` commits and `head1` flushes, ROB pointers advance past the committed `head0` before speculative younger state is drained

Side note:
- because L1D is treated as a black box, any internal younger speculative request buffering may also need a flush-aware discard mechanism even though that mechanism is outside the backend spec body

## 7. LSU Behavior

This is a simplified AGU-fronted LSU that talks to an L1D-side memory subsystem treated as a black box. The backend does not define the internal store-buffering structure of L1D.

### 7.1 Ordering Model

- Loads and Stores execute in-order within Group 3
- ISQ depth is effectively 1 for the LSU path
- a request only decouples from Group 3 after L1D accepts it
- a cache miss blocks Group 3 only
- Groups 0/1/2 continue executing until ROB pressure eventually stops frontend dispatch

### 7.2 Store Safety Rule

Because the design does not implement speculative memory rollback:
- a Store may not architecturally commit before its L1D-side drain has completed
- after AGU, the store request enters the LSU/L1D-side store buffer when space is available
- store-buffer acceptance marks execution/buffering completion, not retirement
- when the store is oldest at the ROB head, `P4` emits `Store_Drain_Req_Tag`
- the store remains at the ROB head while the drain is in progress
- the LSU/L1D side later emits `Store_Done_Tag`
- only after `Store_Done` may the corresponding store retire architecturally
- at most one store drain request may be launched per cycle
- if a head store has not yet entered the store buffer, that store cannot request drain or retire and will block the ROB head

### 7.3 Load Early Wakeup

For Loads only:
- LSU computes AGU early
- sends `agu_early_tag` to P1 with 1-cycle registered latency only if the op is a Load, AGU completed, no synchronous address-side exception has already been detected, and the request has been accepted by the L1D-side interface
- dependent instruction may enter ISQ before load data returns
- real wakeup still happens only when load data later appears on bypass

### 7.4 Hard Stall at AGU -> L1D Boundary

- AGU only computes addresses
- a `Load` then attempts to enter the L1D request side
- a `Store` then attempts to enter the LSU/L1D-side store buffer
- if the load side or store-buffer side applies explicit backpressure, the request hard-stalls at the LSU tail
- store drain in progress does not by itself backpressure unrelated loads
- that stalled request keeps `lsu_busy = 1`
- `lsu_busy` backpressures Group 3 issue
- this design does not replay requests; they wait in place

## 8. Exception, Interrupt & CSR Model

### 8.1 Flush-Causing Sources

Instruction-originated flush classes:
- BRU mispredict
- any synchronous exception-producing instruction

Non-instruction source:
- external interrupt

### 8.2 Exception Flow

```text
P2:
    FU detects exception
    Result_Payload carries exception_cause + exception_flag

P3:
    ROB records exception_flag
    `ROB_MetaArray[tag_out]` records the precise exception metadata, while `inst_pc` remains the value written at P1 allocation

P4:
    when selected as flush source,
    write mepc/mcause,
    redirect to trap vector,
    perform Late Flush
```

### 8.3 Interrupt Rule

- external interrupt is considered only when no synchronous flush has already been selected from `head0` or `head1`
- synchronous instruction-originated events have higher priority than interrupt
- interrupt save-PC uses the next architectural PC after any same-cycle normal commits; `ROB_MetaArray.inst_pc` is available when that next PC belongs to a surviving in-flight instruction
- if no same-cycle normal commit occurred and `ISB` holds a valid oldest instruction, interrupt save-PC should be `ISB_head.pc`
- alloc-side work in the same cycle as the taken interrupt is squashed by `Global_Flush_Late`

### 8.4 CSR Rule

CSR instructions have split behavior:
- temporary result to GPR may be produced early and stored in ROB
- CSR architectural side effect is carried in a dedicated pending sideband
- architectural CSR update happens only at P4 commit

Serialization rule:
- a CSR may be dispatch-accepted only when the ROB is empty
- a CSR may be accepted only from `slot0`
- `csr_inflight_valid/tag` is set at successful P1 dispatch acceptance
- `csr_inflight_valid/tag` is cleared only at normal CSR commit or global flush
- while `csr_inflight_valid==1`, all younger dispatch is blocked at P1

Pending side-effect rule:
- after CSR execution completes in Group 0 and wins P3 arbitration, its real CSR side effect is written into `CSR_PEND_BUF`
- `CSR_PEND_BUF` holds `tag`, `addr`, and `wdata`
- if the CSR has no architectural write side effect, `CSR_PEND_BUF` is not allocated
- if the CSR raises exception, `CSR_PEND_BUF` is not allocated

Commit rule:
- if a CSR commits and `csr_write_enable=1`, P4 applies the architectural CSR write from `CSR_PEND_BUF`
- if a CSR commits and `csr_write_enable=0`, no CSR side effect is applied
- commit then clears both `csr_inflight` and `CSR_PEND_BUF.valid`

Consequences:
- younger instructions never dispatch around an in-flight CSR and therefore never observe speculative CSR state
- flushed CSR instructions need no rollback for CSR state
- illegal CSR access becomes a normal precise exception

## 9. Whole-Design Summary

This backend is a small OoO machine built around four ideas:

1. Dispatch stays in order, but execution and writeback are split into four OoO groups.
2. Dependency resolution is tag-based and wakeup is purely combinational through bypass.
3. ROB is used for precise retirement ordering, not as a forwarding source and not as a PC store.
4. Recovery is Late Flush at commit, with precise control-flow metadata tracked separately in `ROB_MetaArray`.

The result is a lightweight dual-issue backend that preserves precise architectural state while avoiding deep PC-tracking or complex speculative rollback structures.
