# RTL Implementation Notes

This document records critical RTL implementation details that supplement the DEFINITIVE_SPEC.md with concrete evidence from the actual SystemVerilog code.

Last updated: 2026-07-01

---

## Load Instruction Latency

**Fixed 2-cycle execution path for L1D hit case:**

**RTL Evidence**: fake_lsu.sv line 527-539

```systemverilog
// Issue -> Stage 1 (AGU cycle)
stage1_valid <= req_valid;
if (req_valid) begin
    stage1_payload <= req_payload;
    stage1_addr <= new_req_addr;
    ...
end

// Stage 1 -> Stage 2 (L1D/WB cycle)  
stage2_valid <= stage1_valid;
if (stage1_valid) begin
    stage2_wb.result_valid <= 1'b1;
    stage2_wb.tag_out <= stage1_payload.tag;
    ...
```

**Timing breakdown:**
```
Cycle N:   Issue (req_valid=1) → Load enters LSU pipeline
Cycle N+1: Stage1 (AGU) → stage1_valid=1, address computed
Cycle N+2: Stage2 (WB) → stage2_valid=1, result on bypass
```

**Execution stages:**
- SL1 = AGU (address generation unit)
- SL2 = L1D access + Writeback

**FU Latency Table Entry:**
- Load (L1D hit): **2 execution cycles** (fixed, deterministic)
- WB request cycle = SL cycle + 2

**Cache miss / replay behavior:**
- Not modeled in current fake_lsu.sv
- Any variable-latency memory behavior must be modeled as a separate LSU miss/replay timing class
- Current model only represents the fast path

**Load backpressure:**
- Configurable via `cfg_load_backpressure_cycles` (fake_lsu.sv line 416-436)
- Used for testing, not architectural timing

---

## P1 Source Resolution - Commit Overlay

**Two-condition OR logic for commit overlay visibility:**

**RTL Evidence**: p1_source_resolution.sv line 145

```systemverilog
(!current_busy || current_tag == c_pay[1].commit_tag)
```

This implements:
1. **rd-based architectural overlay**: `!current_busy` (DST_REG[rs].busy == 0)
2. **tag-based same-producer match**: `current_tag == commit_tag` (exact producer committing)

**When busy==1 case applies:**
- Consumer at P1 reads DST_REG[rs] and finds busy=1, tag=T_producer
- Same cycle, producer T_producer is committing at P4
- Commit overlay function detects: `current_tag (from DST_REG) == commit_tag (from P4)`
- Returns ready=1, data=commit_data
- This suppresses Condition B stall for this exact producer

**Full commit overlay logic**: p1_source_resolution.sv function check_commit_match() line 133-158

---

## P1 Deadlock Prevention

**Three conditions evaluated per source operand:**

**RTL Evidence**: p1_deadlock_prevention.sv function check_stall() line 41-68

```systemverilog
// Condition A: Bypass Broadcast Overlap
cond_a = (b_bus[0].valid && (rs_tag == b_bus[0].tag)) ||
         (b_bus[1].valid && (rs_tag == b_bus[1].tag)) ||
         (b_bus[2].valid && (rs_tag == b_bus[2].tag)) ||
         (b_bus[3].valid && (rs_tag == b_bus[3].tag));

// Condition B: Data Stuck in ROB (but not if committing now)
cond_b = done_bits[rs_tag] && 
         !((c_pay[0].commit_valid && (rs_tag == c_pay[0].commit_tag)) || 
           (c_pay[1].commit_valid && (rs_tag == c_pay[1].commit_tag)));

// Condition C: LSU Early Wakeup Exemption (Cancel Stall)
cond_c = early_valid && (rs_tag == early_tag);

return (cond_a || cond_b) && !cond_c;
```

**Key behavior:**
- Condition A or B triggers stall
- Condition C cancels both A and B
- If rs_ready=1, no stall check needed (line 51)

**Per-slot stall aggregation**: line 70-77
- Any source operand stall → slot stalls
- slot0_stall = rs1_stall || rs2_stall || rs3_stall
- slot1_stall = rs1_stall || rs2_stall || rs3_stall

---

## DST_REG Write Priority

**P1 allocation overrides P4 commit clear in same cycle:**

**RTL Evidence**: dst_reg.sv line 58-77, always_ff block

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ...
    end else if (clear_all_busy) begin
        ...
    end else begin
        // 1. Commit: Clear busy bit if tag matches
        for (int k = 0; k < 2; k++) begin
            if (commit_payload[k].commit_valid ...) begin
                dst_table[commit_payload[k].rd_idx].busy <= 1'b0;
            end
        end
        
        // 2. Dispatch: Allocate new tags (overrides commit clear)  ← KEY COMMENT
        for (int k = 0; k < NUM_WRITE_PORTS; k++) begin
            if (alloc_valid[k]) begin
                dst_table[alloc_rd_idx[k]].busy <= 1'b1;
                dst_table[alloc_rd_idx[k]].tag  <= alloc_tag[k];
            end
        end
    end
end
```

**Write ordering within always_ff:**
1. P4 commit clear executes first (line 59-67)
2. P1 allocation write executes second (line 70-77)
3. SystemVerilog non-blocking assignment semantics: later assignments to same signal override earlier ones
4. Result: younger allocation wins for next-cycle state

**Comment confirmation**: Line 69 explicitly states "overrides commit clear"

---

## Global Flush Late Timing

**Combinational signal generation, sequential state clearing:**

**RTL Evidence**: p4_commit_control.sv line 114-279 (always_comb)

```systemverilog
always_comb begin
    // Default outputs
    global_flush_late = 1'b0;
    ...
    
    if (flush_selected_this_cycle) begin
        global_flush_late = 1'b1;  // ← Combinational assignment
        reset_rob_pointers = 1'b1;
        clear_all_busy = 1'b1;
        ...
    end
```

**Same-cycle propagation:**
- `global_flush_late` is combinational (generated in always_comb)
- Propagates to P1, P3, LSU in same cycle
- Cancels P1 allocation, masks P3 bypass, cancels LSU pending

**Next-cycle effects:**
- DST_REG clear happens at clock edge
- RTL Evidence: dst_reg.sv line 53-56 (always_ff)

```systemverilog
always_ff @(posedge clk) begin
    ...
    else if (clear_all_busy) begin  // ← Sequential detection
        for (int k = 0; k < 32; k++) begin
            dst_table[k].busy <= 1'b0;  // ← Next-cycle clear
```

**Architectural vs Implementation:**
- Architectural "Flushed" marking: same cycle (for timing diagrams)
- Physical state clearing: next cycle (implementation detail)

---

## agu_early_tag Generation and Lifecycle

**Single-cycle pulse, generated at Load Issue:**

**RTL Evidence**: fake_lsu.sv line 536-538 (generation)

```systemverilog
if (req_payload.is_load && !addr_range_exception(new_req_addr, req_size_bytes)) begin
    agu_early_tag_valid_r <= 1'b1;  // ← Registered at Load Issue
    agu_early_tag_r <= req_payload.tag;
end
```

**Automatic clear next cycle**: fake_lsu.sv line 403-404

```systemverilog
else begin
    agu_early_tag_valid_r <= 1'b0;  // ← Single-cycle pulse
    agu_early_tag_r <= '0;
```

**Flush behavior**: fake_lsu.sv line 381-382
```systemverilog
if (flush_late) begin
    agu_early_tag_valid_r <= 1'b0;  // ← Cleared on flush
    agu_early_tag_r <= '0;
```

**Lifecycle summary:**
- Generated: Load Issue cycle (req_valid && is_load && !exception)
- Lifetime: Single cycle
- Cleared: Automatically next cycle, or immediately on flush

---

## Condition C Implementation

**agu_early_tag cancels P1 stall (both Condition A and B):**

**RTL Evidence**: p1_deadlock_prevention.sv line 64-67

```systemverilog
// Condition C: LSU Early Wakeup Exemption (Cancel Stall)
cond_c = early_valid && (rs_tag == early_tag);

return (cond_a || cond_b) && !cond_c;  // ← !cond_c cancels stall
```

**Interpretation:**
- This is NOT "ISQ-only early wakeup"
- This IS "P1 stall exemption"
- Consumer can dispatch into ISQ before Load WB
- Consumer still waits for data via Bypass[3] in ISQ

**Signal flow:**
```
fake_lsu.sv (agu_early_tag_valid, agu_early_tag)
    ↓
backend_top.sv (port connection line 322-323)
    ↓
p1_deadlock_prevention.sv (input line 33-34, used in check_stall line 65)
    ↓
Condition C logic: cancels (cond_a || cond_b)
```

---

## Summary of RTL-Verified Facts

| Topic | Golden Spec Claim | RTL Implementation | File:Line |
|-------|-------------------|---------------------|-----------|
| Commit overlay | Only describes busy==0 case | Implements `!busy OR tag_match` | p1_source_resolution.sv:145 |
| Condition A behavior | P1 stall on bypass overlap | Confirmed: cond_a triggers stall | p1_deadlock_prevention.sv:54-57 |
| DST_REG write priority | P1 alloc wins over P4 clear | Confirmed: comment + code order | dst_reg.sv:69-77 |
| Flush timing | "Combinational, next-cycle effect" | Confirmed: always_comb → always_ff | p4_commit_control.sv:114-251 |
| agu_early_tag scope | Ambiguous in some docs | **P1 stall exemption**, NOT ISQ-only | p1_deadlock_prevention.sv:65 |
| Load latency | Not explicitly stated | Fixed 2-cycle (stage1 → stage2) | fake_lsu.sv:527-539 |

---

## Cross-References to DEFINITIVE_SPEC.md

- **Section 2.2.1**: P1 Source Resolution - commit overlay (updated with tag-match case)
- **Section 2.2.3**: Deadlock Prevention - Condition A, B, C (updated with RTL references)
- **Section 2.2.4**: LSU Predictive Wakeup - agu_early_tag (fully rewritten based on RTL)
- **Section 2.5.1**: P4 Commit - DST_REG conflict rule (updated with RTL evidence)
- **Section 2.5.2**: Late Flush - timing clarification (updated with combinational vs sequential distinction)

---

End of RTL Implementation Notes
