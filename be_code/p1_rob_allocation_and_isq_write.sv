`ifndef P1_ROB_ALLOCATION_AND_ISQ_WRITE_SV
`define P1_ROB_ALLOCATION_AND_ISQ_WRITE_SV

import orca_types::*;
import exe_subop_pkg::*;

module p1_rob_allocation_and_isq_write (
    // Inputs from P1 Dispatch Logic
    input  isb_payload_t slot0_isb,
    input  logic        slot0_can_dispatch,
    input  logic        slot0_stall,
    input  logic [EXE_TYPE_W-1:0] slot0_target_group,
    
    input  isb_payload_t slot1_isb,
    input  logic        slot1_can_dispatch,
    input  logic        slot1_stall,
    input  logic [EXE_TYPE_W-1:0] slot1_target_group,
    input  logic        flush_late,

    // Source Resolve Results
    input  logic        slot0_rs1_ready,
    input  logic [XLEN-1:0] slot0_rs1_data,
    input  logic [TAG_W-1:0] slot0_rs1_tag,
    input  logic        slot0_rs2_ready,
    input  logic [XLEN-1:0] slot0_rs2_data,
    input  logic [TAG_W-1:0] slot0_rs2_tag,
    input  logic        slot0_rs3_ready,
    input  logic [XLEN-1:0] slot0_rs3_data,
    input  logic [TAG_W-1:0] slot0_rs3_tag,

    input  logic        slot1_rs1_ready,
    input  logic [XLEN-1:0] slot1_rs1_data,
    input  logic [TAG_W-1:0] slot1_rs1_tag,
    input  logic        slot1_rs2_ready,
    input  logic [XLEN-1:0] slot1_rs2_data,
    input  logic [TAG_W-1:0] slot1_rs2_tag,
    input  logic        slot1_rs3_ready,
    input  logic [XLEN-1:0] slot1_rs3_data,
    input  logic [TAG_W-1:0] slot1_rs3_tag,

    // ROB Allocation
    input  logic [TAG_W-1:0] rob_tail,
    output logic [1:0]  rob_alloc_valid,
    output logic [1:0]  rob_alloc_is_store,

    // DST_REG Update
    output logic [1:0]  dst_alloc_valid_int,
    output logic [1:0][REG_ADDR_W-1:0] dst_alloc_rd_int,
    output logic [1:0][TAG_W-1:0] dst_alloc_tag_int,

    output logic        dst_alloc_valid_fp,
    output logic [REG_ADDR_W-1:0] dst_alloc_rd_fp,
    output logic [TAG_W-1:0] dst_alloc_tag_fp,

    // ISQ Write (4 groups)
    output logic [3:0]  isq_wr_en,
    output isq_payload_t [3:0] isq_wr_payload
);

    // Internal Tags derived from rob_tail
    logic [TAG_W-1:0] slot0_self_tag;
    logic [TAG_W-1:0] slot1_self_tag;
    assign slot0_self_tag = rob_tail;
    assign slot1_self_tag = rob_tail + 1'b1;

    // Final Dispatch Decisions
    logic slot0_dispatch, slot1_dispatch;
    assign slot0_dispatch = slot0_isb.inst_valid && slot0_can_dispatch && !slot0_stall && !flush_late;
    assign slot1_dispatch = slot1_isb.inst_valid && slot1_can_dispatch && !slot1_stall && slot0_dispatch && !flush_late;

    // ROB Allocation
    assign rob_alloc_valid[0] = slot0_dispatch;
    assign rob_alloc_valid[1] = slot1_dispatch;

    function automatic logic csr_has_write_intent(input isb_payload_t isb);
        if (!isb.is_csr) begin
            return 1'b0;
        end

        unique case (isb.exe_subop)
            CSR_CSRRW, CSR_CSRRWI: begin
                return 1'b1;
            end
            CSR_CSRRS, CSR_CSRRC, CSR_CSRRSI, CSR_CSRRCI: begin
                return (isb.rs1_idx != '0);
            end
            default: begin
                return 1'b0;
            end
        endcase
    endfunction

    // DST_REG Update (INT)
    always_comb begin
        dst_alloc_valid_int = '0;
        dst_alloc_rd_int    = '0;
        dst_alloc_tag_int   = '0;

        if (slot0_dispatch && slot0_isb.use_rd && !slot0_isb.rd_is_fp && (slot0_isb.rd_idx != '0)) begin
            dst_alloc_valid_int[0] = 1'b1;
            dst_alloc_rd_int[0]    = slot0_isb.rd_idx;
            dst_alloc_tag_int[0]   = slot0_self_tag;
        end

        if (slot1_dispatch && slot1_isb.use_rd && !slot1_isb.rd_is_fp && (slot1_isb.rd_idx != '0)) begin
            dst_alloc_valid_int[1] = 1'b1;
            dst_alloc_rd_int[1]    = slot1_isb.rd_idx;
            dst_alloc_tag_int[1]   = slot1_self_tag;
        end
    end

    // DST_REG Update (FP) - Only one write port
    always_comb begin
        dst_alloc_valid_fp = 1'b0;
        dst_alloc_rd_fp    = '0;
        dst_alloc_tag_fp   = '0;

        if (slot0_dispatch && slot0_isb.use_rd && slot0_isb.rd_is_fp) begin
            dst_alloc_valid_fp = 1'b1;
            dst_alloc_rd_fp    = slot0_isb.rd_idx;
            dst_alloc_tag_fp   = slot0_self_tag;
        end else if (slot1_dispatch && slot1_isb.use_rd && slot1_isb.rd_is_fp) begin
            dst_alloc_valid_fp = 1'b1;
            dst_alloc_rd_fp    = slot1_isb.rd_idx;
            dst_alloc_tag_fp   = slot1_self_tag;
        end
    end

    // ISQ Payload Assembly Helper
    function automatic isq_payload_t assemble_isq(
        input isb_payload_t isb,
        input logic [EXE_TYPE_W-1:0] target_group,
        input logic [TAG_W-1:0] self_tag,
        input logic rs1_ready, input [XLEN-1:0] rs1_data, input [TAG_W-1:0] rs1_tag,
        input logic rs2_ready, input [XLEN-1:0] rs2_data, input [TAG_W-1:0] rs2_tag,
        input logic rs3_ready, input [XLEN-1:0] rs3_data, input [TAG_W-1:0] rs3_tag
    );
        isq_payload_t p;
        p.self_rob_tag   = self_tag;
        p.exe_subop      = isb.exe_subop;
        p.rd_idx         = isb.use_rd ? isb.rd_idx : '0;
        p.rd_is_fp       = isb.rd_is_fp;
        p.uses_fp_state  = (isb.exe_type == GROUP_FPU) ||
                           ((isb.exe_type == GROUP_LSU) &&
                            ((isb.use_rd && isb.rd_is_fp) ||
                             (isb.use_rs1 && isb.rs1_is_fp) ||
                             (isb.use_rs2 && isb.rs2_is_fp) ||
                             (isb.use_rs3 && isb.rs3_is_fp)));
        p.rs1_ready      = (isb.is_csr && (isb.exe_subop == CSR_CSRRWI || isb.exe_subop == CSR_CSRRSI || isb.exe_subop == CSR_CSRRCI)) ? 1'b1 : rs1_ready;
        p.rs1_data       = (isb.is_csr && (isb.exe_subop == CSR_CSRRWI || isb.exe_subop == CSR_CSRRSI || isb.exe_subop == CSR_CSRRCI)) ? {{(XLEN-5){1'b0}}, isb.rs1_idx} : rs1_data;
        p.rs1_wait_tag   = rs1_tag;
        p.rs2_ready      = rs2_ready;
        p.rs2_data       = rs2_data;
        p.rs2_wait_tag   = rs2_tag;
        p.rs3_ready      = rs3_ready;
        p.rs3_data       = rs3_data;
        p.rs3_wait_tag   = rs3_tag;
        p.pc             = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pc : '0;
        p.pred_taken     = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pred_taken : 1'b0;
        p.pred_target_pc = (target_group == GROUP_ALU0_BRU_DIV_CSR) ? isb.pred_target_pc : '0;
        p.imm_valid      = isb.imm_valid;
        p.imm_data       = isb.imm_data;
        p.csr_write_intent = csr_has_write_intent(isb);
        p.is_store       = (isb.exe_type == GROUP_LSU) && is_lsu_store(isb.exe_subop);
        p.store_data     = '0; 
        p.store_mask     = '0;
        p.store_size     = isb.store_size;
        return p;
    endfunction

    // ISQ Write Logic
    always_comb begin
        isq_wr_en = '0;
        isq_wr_payload = '0;
        rob_alloc_is_store = '0;

        if (slot0_dispatch) begin
            isq_wr_en[slot0_target_group] = 1'b1;
            isq_wr_payload[slot0_target_group] = assemble_isq(
                slot0_isb, slot0_target_group, slot0_self_tag,
                slot0_rs1_ready, slot0_rs1_data, slot0_rs1_tag,
                slot0_rs2_ready, slot0_rs2_data, slot0_rs2_tag,
                slot0_rs3_ready, slot0_rs3_data, slot0_rs3_tag
            );
            rob_alloc_is_store[0] = (slot0_isb.exe_type == GROUP_LSU) && is_lsu_store(slot0_isb.exe_subop);
        end

        if (slot1_dispatch) begin
            isq_wr_en[slot1_target_group] = 1'b1;
            isq_wr_payload[slot1_target_group] = assemble_isq(
                slot1_isb, slot1_target_group, slot1_self_tag,
                slot1_rs1_ready, slot1_rs1_data, slot1_rs1_tag,
                slot1_rs2_ready, slot1_rs2_data, slot1_rs2_tag,
                slot1_rs3_ready, slot1_rs3_data, slot1_rs3_tag
            );
            rob_alloc_is_store[1] = (slot1_isb.exe_type == GROUP_LSU) && is_lsu_store(slot1_isb.exe_subop);
        end
    end

endmodule

`endif // P1_ROB_ALLOCATION_AND_ISQ_WRITE_SV
