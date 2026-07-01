# Documentation Modification Summary

**Date**: 2026-07-01  
**Purpose**: Correct golden spec based on actual RTL implementation  
**Feedback Document Source**: `C:\Users\rivai\Downloads\golden_spec_alignment_feedback.md`

---

## Overview

This document records all modifications made to align documentation with RTL code reality. Each modification is based on direct RTL evidence and includes file/line references for verification.

---

## Modifications Made

### 1. **DEFINITIVE_SPEC.md - Section 2.2.1: P1 Source Resolution**

**Location**: Lines 136-157

**Issue (A1)**: Original text only described commit overlay for `busy==0` case, missing the tag-match case.

**RTL Evidence**: 
- `be_code/p1_source_resolution.sv:145`
- Condition: `(!current_busy || current_tag == c_pay[1].commit_tag)`

**Change Made**:
```diff
**Same-cycle commit overlay rule**:
- P1 source resolution must include a same-cycle commit overlay for normal P4 commits.
- This overlay has priority over persistent `ARF/DST_REG` state.
+ The overlay matches in two cases (OR condition):
+   1. **rd-based architectural overlay**: `DST_REG[rs].busy == 0` and register index matches
+   2. **tag-based same-producer match**: `DST_REG[rs].busy == 1` but `DST_REG[rs].tag == commit_tag` (exact producer committing)
- A matching source resolves as:
```text
rsX_ready    = 1
rsX_data     = committed result_data
rsX_wait_tag = 4'h0
```
- This rule exists so the architecture does **not** depend on implementation-specific same-cycle ARF read-after-write or DST_REG clear visibility.
+ The tag-based match (case 2) is critical: it allows a consumer at P1 to use the exact producer's commit value even when `DST_REG[rs].busy == 1`, suppressing Condition B stall.
+ **RTL implementation**: p1_source_resolution.sv line 145: `(!current_busy || current_tag == c_pay[1].commit_tag)`
```

**Verification**: Read lines 136-157 of golden/DEFINITIVE_SPEC.md

---

### 2. **DEFINITIVE_SPEC.md - Section 2.2.3: Deadlock Prevention**

**Location**: Lines 234-241

**Issue (A2)**: Need to clarify that commit overlay uses tag-match logic and add RTL references.

**RTL Evidence**:
- `be_code/p1_deadlock_prevention.sv:54-67`

**Change Made**:
```diff
**Stall Action**: If Condition A or B triggers, assert `P1_Stall`. DSP withholds the ISQ write for that instruction, so the corresponding head instruction remains in ISB and is retried on the next cycle. Condition C cancels the stall for LSU predictive wakeup.

- Here, `same_cycle_commit_match(wait_tag)` means that one of the normal same-cycle P4 commit slots is retiring that exact producer tag and therefore exposing the committed value through the explicit P4->P1 commit overlay.
+ Here, `same_cycle_commit_match(wait_tag)` means that one of the normal same-cycle P4 commit slots is retiring that exact producer tag and therefore exposing the committed value through the explicit P4->P1 commit overlay (via the tag-based same-producer match described in Section 2.2.1).
+
+ **RTL implementation**: p1_deadlock_prevention.sv function check_stall():
+ - Condition A: line 54-57 (bypass_valid && tag match)
+ - Condition B: line 60-62 (rob_done_bits[tag] && !commit_payload match)
+ - Condition C: line 65 (agu_early_tag_valid && tag match)
+ - Return logic: line 67 `return (cond_a || cond_b) && !cond_c;`
```

**Verification**: Read lines 234-241 of golden/DEFINITIVE_SPEC.md

---

### 3. **DEFINITIVE_SPEC.md - Section 2.2.4: LSU Predictive Wakeup (MAJOR REWRITE)**

**Location**: Lines 252-269

**Issue (A5)**: Original text was ambiguous/incomplete. RTL shows this is P1 stall exemption, NOT ISQ-only.

**RTL Evidence**:
- `be_code/p1_deadlock_prevention.sv:65`: `cond_c = early_valid && (rs_tag == early_tag);`
- `be_code/p1_deadlock_prevention.sv:67`: `return (cond_a || cond_b) && !cond_c;`
- `be_code/fake_lsu.sv:536-538`: Generation at Load Issue
- `be_code/fake_lsu.sv:403-404`: Single-cycle pulse clear

**Change Made**: Complete section rewrite
```diff
- #### 2.2.4 LSU Predictive Wakeup (agu_early_tag)
- 
- When a Load instruction enters the LSU FU stage (Group 3), the address computation (AGU) is performed internally. At the end of this stage, `agu_early_tag` (4-bit) is sent to P1.
- 
- **Registered timing**: `agu_early_tag` is registered at the LSU FU output (posedge clk). P1 samples it at the next posedge clk. This 1-cycle registered latency ensures STA closure on the long Group 3->P1 timing path.
- 
- **Sequence**:
- 1. Load instruction enters Group 3 LSU FU -> AGU computes address, `agu_early_tag` latched at posedge clk
- 2. Next cycle, P1 sees `agu_early_tag = inst0_tag`. Dependent instruction matches `wait_tag == agu_early_tag` -> **Stall cancelled** (Condition C)
- 3. Dependent instruction enters Issue Queue with `rs_ready = 0`, waits in ISQ
- 4. Load instruction proceeds to L1Dcache, reads data -> pushes real `result_data` + `tag_out` onto Bypass bus
- 5. Dependent instruction in queue latches Bypass data via tag match -> ready for execution
+ #### 2.2.4 LSU Predictive Wakeup (agu_early_tag)
+ 
+ **Mechanism**: `agu_early_tag` implements a **P1 stall exemption** mechanism that allows Load-dependent consumers to dispatch into ISQ before the Load completes, avoiding deadlock while maintaining correct data dependency.
+ 
+ **Generation timing (RTL: fake_lsu.sv line 536-538)**:
+ - Generated when Load enters LSU Issue cycle (`req_valid=1 && is_load`)
+ - Condition: Load must not trigger address range exception
+ - Lifetime: Single-cycle pulse, automatically cleared next cycle (line 403-404)
+ - `agu_early_tag_valid` and `agu_early_tag` are registered signals
+ 
+ **P1 Dispatch Effect (Condition C)**:
+ When a consumer instruction reaches P1 with `wait_tag` matching the current `agu_early_tag`:
+ 1. **Condition A stall is cancelled** (even if bypass_valid matches the tag)
+ 2. **Condition B stall is cancelled** (even if ROB[wait_tag].done==1)
+ 3. Consumer **immediately dispatches into ISQ** with `rs_ready=0`
+ 4. Consumer waits in ISQ for the real data via Bypass[3]
+ 
+ **RTL implementation**: p1_deadlock_prevention.sv line 65:
+ ```systemverilog
+ cond_c = early_valid && (rs_tag == early_tag);
+ return (cond_a || cond_b) && !cond_c;  // Condition C cancels stall
+ ```
+ 
+ **Timing Example**:
+ ```
+ Cycle N:   Load enters LSU Issue
+            → agu_early_tag_valid=1, agu_early_tag=T_load (same cycle)
+            
+ Cycle N:   Dependent consumer arrives at P1
+            → DST_REG[rs].busy=1, tag=T_load
+            → Condition B would trigger, BUT Condition C cancels
+            → Consumer dispatches to ISQ with rs_ready=0, wait_tag=T_load
+            
+ Cycle N+1: agu_early_tag_valid cleared
+            Load proceeds to Stage1 (AGU)
+            
+ Cycle N+2: Load completes Stage2 (WB)
+            → Bypass[3].valid=1, tag=T_load, data=load_result
+            → Consumer wakes up via bypass tag match
+ ```
```

**Verification**: Read lines 252-290 of golden/DEFINITIVE_SPEC.md

---

### 4. **DEFINITIVE_SPEC.md - Section 2.5.1: P4 Commit - DST_REG Conflict Rule**

**Location**: Lines 1008-1010 → expanded to 1008-1015

**Issue (A3)**: Missing RTL evidence for P1 allocation overriding P4 clear.

**RTL Evidence**:
- `be_code/dst_reg.sv:69`: Comment "overrides commit clear"
- `be_code/dst_reg.sv:58-77`: Code structure shows P1 write after P4 clear

**Change Made**:
```diff
**Same-cycle `DST_REG` conflict rule**:
- If a same-cycle younger `P1` allocation write targets the same `DST_REG` entry as an older same-cycle `P4` tag-matched clear, the younger allocation mapping wins for the persistent next-state.
- The older commit still retires architecturally, but it must not erase the newer producer mapping.
+ If a same-cycle younger `P1` allocation write targets the same `DST_REG` entry as an older same-cycle `P4` tag-matched clear, the younger allocation mapping wins for the persistent next-state.
+ The older commit still retires architecturally, but it must not erase the newer producer mapping.
+ **RTL implementation**: dst_reg.sv line 58-77, within always_ff block:
+   - P4 commit clear executes first (line 59-67)
+   - P1 allocation write executes second (line 70-77)
+   - Comment at line 69: "Dispatch: Allocate new tags (overrides commit clear)"
+   - SystemVerilog semantics: later non-blocking assignments to the same signal override earlier ones within the same always_ff block
```

**Verification**: Read lines 1008-1015 of golden/DEFINITIVE_SPEC.md

---

### 5. **DEFINITIVE_SPEC.md - Section 2.5.2: Late Flush Timing**

**Location**: Lines 1072-1079 → expanded to 1072-1096

**Issue (A4)**: Need to clarify combinational vs sequential effects.

**RTL Evidence**:
- `be_code/p4_commit_control.sv:114-279`: always_comb block generates flush
- `be_code/dst_reg.sv:53-56`: always_ff block clears busy bits

**Change Made**:
```diff
**Flush actions** (all combinational, take effect at next `posedge clk`):

+ **Same-cycle combinational effects**:
+ - `Global_Flush_Late` is generated in p4_commit_control.sv within an `always_comb` block (line 114-279)
+ - As a combinational signal, it propagates in the same cycle to:
+   - P1: cancels same-cycle allocation and ISQ write
+   - P3: masks same-cycle bypass valid signals
+   - LSU: cancels pending requests
+ - Younger instructions are architecturally considered "Flushed" in this cycle for timing diagram purposes
+ 
+ **Next-cycle sequential effects**:
+ - DST_REG.busy bits are cleared via the always_ff clock edge
+ - ROB state arrays are cleared via their always_ff logic
+ - These are implementation details that do not delay the architectural Flushed marking
+ 
+ **RTL implementation**:
+ - Flush generation: p4_commit_control.sv line 243-251 (always_comb)
+ - DST_REG clear: dst_reg.sv line 53-56 (always_ff)
+ 
| Signal | Target | Behavior |
|---|---|---|
| `Global_Flush_Late` | P0, P1, P2 | Synchronous clear - sets `valid = 0` for all visible ISB output slots, `Issue_queue` entries, FU pipeline registers, and all multi-cycle FU internal speculative state. Connected as data-path control, **NOT** as async reset pin. |
...
```

**Verification**: Read lines 1072-1096 of golden/DEFINITIVE_SPEC.md

---

## New Files Created

### 6. **RTL_IMPLEMENTATION_NOTES.md** (New File)

**Location**: `golden/RTL_IMPLEMENTATION_NOTES.md`

**Purpose**: Comprehensive RTL evidence documentation including:
- Load instruction latency (A6) - 2-cycle fixed pipeline
- P1 source resolution commit overlay details
- P1 deadlock prevention complete logic
- DST_REG write priority evidence
- Global flush late timing breakdown
- agu_early_tag generation and lifecycle
- Condition C implementation

**Key Sections**:
1. Load Instruction Latency (fake_lsu.sv:527-539)
2. P1 Source Resolution - Commit Overlay (p1_source_resolution.sv:145)
3. P1 Deadlock Prevention (p1_deadlock_prevention.sv:41-68)
4. DST_REG Write Priority (dst_reg.sv:58-77)
5. Global Flush Late Timing (p4_commit_control.sv:114-279)
6. agu_early_tag Generation and Lifecycle (fake_lsu.sv:536-538, 403-404)
7. Condition C Implementation (p1_deadlock_prevention.sv:64-67)
8. Summary table cross-referencing all claims

**Verification**: Read `golden/RTL_IMPLEMENTATION_NOTES.md`

---

## Issues Not Requiring Code Changes

### A7. Naming Drift (IB vs ISB, Flushed vs squash)
- **Status**: Documentation style issue, no technical error
- **Action**: No file changes needed, noted for future consistency

### A8. Source Attribution Drift
- **Status**: Documentation process issue
- **Action**: No file changes needed, RTL_IMPLEMENTATION_NOTES.md provides clear attribution

---

## Verification Checklist

To verify all changes, please review:

1. ✅ **golden/DEFINITIVE_SPEC.md lines 136-157** (A1: Commit overlay two-case logic)
2. ✅ **golden/DEFINITIVE_SPEC.md lines 234-241** (A2: Deadlock prevention RTL refs)
3. ✅ **golden/DEFINITIVE_SPEC.md lines 252-290** (A5: Complete rewrite of agu_early_tag section)
4. ✅ **golden/DEFINITIVE_SPEC.md lines 1008-1015** (A3: DST_REG write priority evidence)
5. ✅ **golden/DEFINITIVE_SPEC.md lines 1072-1096** (A4: Flush timing clarification)
6. ✅ **golden/RTL_IMPLEMENTATION_NOTES.md** (New comprehensive evidence file, covers A6)
7. ✅ **golden/MODIFICATION_SUMMARY.md** (This file)

---

## RTL Evidence Summary Table

| Issue | File Modified | Lines Changed | RTL Evidence Source | Evidence Lines |
|-------|---------------|---------------|---------------------|----------------|
| A1 | DEFINITIVE_SPEC.md | 136-157 | p1_source_resolution.sv | 145 |
| A2 | DEFINITIVE_SPEC.md | 234-241 | p1_deadlock_prevention.sv | 54-67 |
| A3 | DEFINITIVE_SPEC.md | 1008-1015 | dst_reg.sv | 58-77 (esp. 69) |
| A4 | DEFINITIVE_SPEC.md | 1072-1096 | p4_commit_control.sv, dst_reg.sv | 114-279, 53-56 |
| A5 | DEFINITIVE_SPEC.md | 252-290 | p1_deadlock_prevention.sv, fake_lsu.sv | 65, 67, 536-538, 403-404 |
| A6 | RTL_IMPLEMENTATION_NOTES.md | New file | fake_lsu.sv | 527-539 |

---

## Critical Findings

**Most Important Change**: Section 2.2.4 (A5) - agu_early_tag

**Why Critical**:
- Original feedback document claimed "owner discussion lean toward ISQ-only interpretation"
- RTL code **directly contradicts** this: implements P1 stall exemption
- This affects timing diagrams, producer-consumer trees, and deadlock prevention understanding
- Decision: **Follow RTL as ground truth**, completely rewrite section

**Impact**:
- Load-use timing diagrams must show consumer entering ISQ before Load WB
- Condition C is part of P1 logic, not ISQ wakeup logic
- Documentation must reflect "P1 stall exemption" interpretation

---

## Cross-File Consistency

All modifications maintain consistency across:
- Golden spec (DEFINITIVE_SPEC.md)
- RTL implementation (be_code/*.sv)
- New evidence file (RTL_IMPLEMENTATION_NOTES.md)
- This summary (MODIFICATION_SUMMARY.md)

Each claim in documentation now has:
1. Clear statement of behavior
2. RTL file reference
3. Specific line numbers
4. Code snippet or quote where applicable

---

## Next Steps

1. **Verify all changes** by reading the specified line ranges
2. **Check RTL references** match the claimed behavior
3. **Update any timing diagrams** to reflect A5 changes (agu_early_tag as P1 exemption)
4. **Update Interface_SPEC.md** if it duplicates any corrected content
5. **Update any downstream documents** (case matrices, timing cases) referencing these sections

---

End of Modification Summary
