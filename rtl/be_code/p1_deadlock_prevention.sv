`ifndef P1_DEADLOCK_PREVENTION_SV
`define P1_DEADLOCK_PREVENTION_SV

import orca_types::*;

module p1_deadlock_prevention (
    // Slot 0 Sources
    input  logic        slot0_rs1_ready,
    input  logic [TAG_W-1:0] slot0_rs1_tag,
    input  logic        slot0_rs2_ready,
    input  logic [TAG_W-1:0] slot0_rs2_tag,
    input  logic        slot0_rs3_ready,
    input  logic [TAG_W-1:0] slot0_rs3_tag,

    // Slot 1 Sources
    input  logic        slot1_rs1_ready,
    input  logic [TAG_W-1:0] slot1_rs1_tag,
    input  logic        slot1_rs2_ready,
    input  logic [TAG_W-1:0] slot1_rs2_tag,
    input  logic        slot1_rs3_ready,
    input  logic [TAG_W-1:0] slot1_rs3_tag,

    // Bypass Status (Condition A)
    input  bypass_t [3:0] bypass_bus,

    // ROB Status (Condition B)
    input  logic [ROB_DEPTH-1:0] rob_done_bits,

    // P4 Commit Status (for refining Condition B)
    input  commit_payload_t [1:0] commit_payload,

    // LSU Early Wakeup (Condition C)
    input  logic        agu_early_tag_valid,
    input  logic [TAG_W-1:0] agu_early_tag,

    // Stall Decisions
    output logic        slot0_stall,
    output logic        slot1_stall
);

    function automatic logic check_stall(
        input logic rs_ready,
        input logic [TAG_W-1:0] rs_tag,
        input bypass_t [3:0] b_bus,
        input logic [ROB_DEPTH-1:0] done_bits,
        input commit_payload_t [1:0] c_pay,
        input logic early_valid,
        input logic [TAG_W-1:0] early_tag
    );
        logic cond_a, cond_b, cond_c;
        if (rs_ready) return 1'b0;

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
    endfunction

    always_comb begin
        slot0_stall = check_stall(slot0_rs1_ready, slot0_rs1_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag) ||
                      check_stall(slot0_rs2_ready, slot0_rs2_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag) ||
                      check_stall(slot0_rs3_ready, slot0_rs3_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag);

        slot1_stall = check_stall(slot1_rs1_ready, slot1_rs1_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag) ||
                      check_stall(slot1_rs2_ready, slot1_rs2_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag) ||
                      check_stall(slot1_rs3_ready, slot1_rs3_tag, bypass_bus, rob_done_bits, commit_payload, agu_early_tag_valid, agu_early_tag);
    end

endmodule

`endif // P1_DEADLOCK_PREVENTION_SV
