`ifndef P1_ADMISSION_AND_BACKPRESSURE_SV
`define P1_ADMISSION_AND_BACKPRESSURE_SV

import orca_types::*;
import exe_subop_pkg::*;

module p1_admission_and_backpressure (
    // Slot 0 Inputs
    input  isb_payload_t slot0_isb,
    
    // Slot 1 Inputs
    input  isb_payload_t slot1_isb,

    // Backend Status
    input  logic        rob_full,
    input  logic        rob_empty,
    input  logic        rob_can_alloc_1,
    input  logic        rob_can_alloc_2,
    input  logic [3:0]  isq_valid, // Occupancy of each ISQ
    input  logic [3:0]  isq_issue_en, // Same-cycle issue for refill
    input  logic        csr_inflight_valid,

    // Admission Decisions
    output logic        slot0_can_dispatch,
    output logic        slot1_can_dispatch,
    output logic [EXE_TYPE_W-1:0] slot0_target_group,
    output logic [EXE_TYPE_W-1:0] slot1_target_group,

    // Legacy pre-stall dequeue estimate
    output logic [1:0]  isb_dequeue_cnt
);

    // Group Availability Helper (Refill Rule)
    function automatic logic is_group_free(input logic valid, input logic issue);
        return !valid || issue;
    endfunction

    function automatic logic [2:0] fp_src_count(input isb_payload_t isb);
        return {2'b0, isb.use_rs1 && isb.rs1_is_fp} +
               {2'b0, isb.use_rs2 && isb.rs2_is_fp} +
               {2'b0, isb.use_rs3 && isb.rs3_is_fp};
    endfunction

    logic g0_free, g1_free, g2_free, g3_free;

    assign g0_free = is_group_free(isq_valid[GROUP_ALU0_BRU_DIV_CSR], isq_issue_en[GROUP_ALU0_BRU_DIV_CSR]);
    assign g1_free = is_group_free(isq_valid[GROUP_ALU1_MUL],         isq_issue_en[GROUP_ALU1_MUL]);
    assign g2_free = is_group_free(isq_valid[GROUP_FPU],              isq_issue_en[GROUP_FPU]);
    assign g3_free = is_group_free(isq_valid[GROUP_LSU],              isq_issue_en[GROUP_LSU]);

    // Slot 0 Admission
    always_comb begin
        slot0_can_dispatch = 1'b0;
        slot0_target_group = GROUP_ALU0_BRU_DIV_CSR;

        if (slot0_isb.inst_valid && !rob_full && rob_can_alloc_1 && !csr_inflight_valid) begin
            // CSR rule
            if (slot0_isb.is_csr) begin
                slot0_target_group = GROUP_ALU0_BRU_DIV_CSR;
                if (rob_empty && g0_free) begin
                    slot0_can_dispatch = 1'b1;
                end
            end else if (slot0_isb.exe_type == GROUP_FPU) begin
                slot0_target_group = GROUP_FPU;
                slot0_can_dispatch = g2_free;
            end else if (slot0_isb.exe_type == GROUP_LSU) begin
                slot0_target_group = GROUP_LSU;
                slot0_can_dispatch = g3_free;
            end else if (is_shared_alu(slot0_isb.exe_subop)) begin
                if (g0_free) begin
                    slot0_target_group = GROUP_ALU0_BRU_DIV_CSR;
                    slot0_can_dispatch = 1'b1;
                end else if (g1_free) begin
                    slot0_target_group = GROUP_ALU1_MUL;
                    slot0_can_dispatch = 1'b1;
                end
            end else if ((is_g0_bru(slot0_isb.exe_subop) || is_g0_div(slot0_isb.exe_subop) || is_g0_csr(slot0_isb.exe_subop) || (slot0_isb.exe_subop == ALU_AUIPC)) && slot0_isb.exe_type == GROUP_ALU0_BRU_DIV_CSR) begin
                slot0_target_group = GROUP_ALU0_BRU_DIV_CSR;
                slot0_can_dispatch = g0_free;
            end else if (is_g1_mul(slot0_isb.exe_subop) && slot0_isb.exe_type == GROUP_ALU1_MUL) begin
                slot0_target_group = GROUP_ALU1_MUL;
                slot0_can_dispatch = g1_free;
            end else begin
                slot0_can_dispatch = 1'b0;
            end
        end
    end

    // Slot 1 Admission
    always_comb begin
        logic g0_free_after_slot0;
        logic g1_free_after_slot0;
        logic g2_free_after_slot0;
        logic g3_free_after_slot0;
        logic fp_limit_hit;
        logic fp_src_limit_hit;

        // Default values to prevent latches
        g0_free_after_slot0 = 1'b0;
        g1_free_after_slot0 = 1'b0;
        g2_free_after_slot0 = 1'b0;
        g3_free_after_slot0 = 1'b0;
        fp_limit_hit = 1'b0;
        fp_src_limit_hit = 1'b0;
        slot1_can_dispatch = 1'b0;
        slot1_target_group = GROUP_ALU0_BRU_DIV_CSR;

        if (slot1_isb.inst_valid && slot0_can_dispatch && rob_can_alloc_2) begin
            // CSR rule: slot1 cannot be CSR, and cannot dispatch if slot0 is CSR
            if (slot1_isb.is_csr || slot0_isb.is_csr) begin
                slot1_can_dispatch = 1'b0;
            end else begin
                g0_free_after_slot0 = g0_free && (slot0_target_group != GROUP_ALU0_BRU_DIV_CSR);
                g1_free_after_slot0 = g1_free && (slot0_target_group != GROUP_ALU1_MUL);
                g2_free_after_slot0 = g2_free && (slot0_target_group != GROUP_FPU);
                g3_free_after_slot0 = g3_free && (slot0_target_group != GROUP_LSU);

                // FP write port limit: at most one FP rename per cycle
                fp_limit_hit = slot0_isb.use_rd && slot0_isb.rd_is_fp && 
                               slot1_isb.use_rd && slot1_isb.rd_is_fp;
                fp_src_limit_hit = (fp_src_count(slot0_isb) + fp_src_count(slot1_isb)) > 3'd3;

                if (!fp_limit_hit && !fp_src_limit_hit) begin
                    if (slot1_isb.exe_type == GROUP_FPU) begin
                        slot1_target_group = GROUP_FPU;
                        slot1_can_dispatch = g2_free_after_slot0;
                    end else if (slot1_isb.exe_type == GROUP_LSU) begin
                        slot1_target_group = GROUP_LSU;
                        slot1_can_dispatch = g3_free_after_slot0;
                    end else if (is_shared_alu(slot1_isb.exe_subop)) begin
                        if (g0_free_after_slot0) begin
                            slot1_target_group = GROUP_ALU0_BRU_DIV_CSR;
                            slot1_can_dispatch = 1'b1;
                        end else if (g1_free_after_slot0) begin
                            slot1_target_group = GROUP_ALU1_MUL;
                            slot1_can_dispatch = 1'b1;
                        end
                    end else if ((is_g0_bru(slot1_isb.exe_subop) || is_g0_div(slot1_isb.exe_subop) || is_g0_csr(slot1_isb.exe_subop) || (slot1_isb.exe_subop == ALU_AUIPC)) && slot1_isb.exe_type == GROUP_ALU0_BRU_DIV_CSR) begin
                        slot1_target_group = GROUP_ALU0_BRU_DIV_CSR;
                        slot1_can_dispatch = g0_free_after_slot0;
                    end else if (is_g1_mul(slot1_isb.exe_subop) && slot1_isb.exe_type == GROUP_ALU1_MUL) begin
                        slot1_target_group = GROUP_ALU1_MUL;
                        slot1_can_dispatch = g1_free_after_slot0;
                    end
                end
            end
        end
    end

    // Dequeue Logic
    assign isb_dequeue_cnt = slot1_can_dispatch ? 2'd2 : (slot0_can_dispatch ? 2'd1 : 2'd0);

endmodule

`endif // P1_ADMISSION_AND_BACKPRESSURE_SV
