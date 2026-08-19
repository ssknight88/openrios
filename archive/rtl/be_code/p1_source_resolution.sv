`ifndef P1_SOURCE_RESOLUTION_SV
`define P1_SOURCE_RESOLUTION_SV

import orca_types::*;

module p1_source_resolution (
    // Slot 0 Inputs (from ISB)
    input  isb_payload_t slot0_isb,
    
    // Slot 1 Inputs (from ISB)
    input  isb_payload_t slot1_isb,

    // DST_REG / ARF Interface (INT)
    output logic [3:0][REG_ADDR_W-1:0] int_dst_raddr,
    input  logic [3:0]                 int_dst_rbusy,
    input  logic [3:0][TAG_W-1:0]      int_dst_rtag,
    output logic [3:0][REG_ADDR_W-1:0] int_arf_raddr,
    input  logic [3:0][XLEN-1:0]       int_arf_rdata,

    // DST_REG / ARF Interface (FP)
    output logic [2:0][REG_ADDR_W-1:0] fp_dst_raddr,
    input  logic [2:0]                 fp_dst_rbusy,
    input  logic [2:0][TAG_W-1:0]      fp_dst_rtag,
    output logic [2:0][REG_ADDR_W-1:0] fp_arf_raddr,
    input  logic [2:0][XLEN-1:0]       fp_arf_rdata,

    // Slot 0 Resolve Results
    output logic        slot0_rs1_ready,
    output logic [XLEN-1:0] slot0_rs1_data,
    output logic [TAG_W-1:0] slot0_rs1_tag,
    output logic        slot0_rs2_ready,
    output logic [XLEN-1:0] slot0_rs2_data,
    output logic [TAG_W-1:0] slot0_rs2_tag,
    output logic        slot0_rs3_ready,
    output logic [XLEN-1:0] slot0_rs3_data,
    output logic [TAG_W-1:0] slot0_rs3_tag,

    // Same-Cycle Overlay (from P1 ROB Allocation)
    input  logic        slot0_overlay_valid,
    input  logic [TAG_W-1:0] slot0_alloc_tag,

    // Slot 1 Resolve Results
    output logic        slot1_rs1_ready,
    output logic [XLEN-1:0] slot1_rs1_data,
    output logic [TAG_W-1:0] slot1_rs1_tag,
    output logic        slot1_rs2_ready,
    output logic [XLEN-1:0] slot1_rs2_data,
    output logic [TAG_W-1:0] slot1_rs2_tag,
    output logic        slot1_rs3_ready,
    output logic [XLEN-1:0] slot1_rs3_data,
    output logic [TAG_W-1:0] slot1_rs3_tag,

    // P4 Commit Overlay
    input  commit_payload_t [1:0] commit_payload
);

    localparam int FP_SRC_S0_RS1 = 0;
    localparam int FP_SRC_S0_RS2 = 1;
    localparam int FP_SRC_S0_RS3 = 2;
    localparam int FP_SRC_S1_RS1 = 3;
    localparam int FP_SRC_S1_RS2 = 4;
    localparam int FP_SRC_S1_RS3 = 5;

    logic [5:0] fp_src_has_port;
    logic [5:0][1:0] fp_src_port;
    integer fp_port_idx;

    // Slot 0 Port Mapping
    assign int_dst_raddr[0] = slot0_isb.rs1_idx;
    assign int_dst_raddr[1] = slot0_isb.rs2_idx;
    assign int_arf_raddr[0] = slot0_isb.rs1_idx;
    assign int_arf_raddr[1] = slot0_isb.rs2_idx;

    // Slot 1 Port Mapping
    assign int_dst_raddr[2] = slot1_isb.rs1_idx;
    assign int_dst_raddr[3] = slot1_isb.rs2_idx;
    assign int_arf_raddr[2] = slot1_isb.rs1_idx;
    assign int_arf_raddr[3] = slot1_isb.rs2_idx;

    // FP port mapping is dynamic: the design guarantees at most 3 FP sources/cycle.
    always_comb begin
        fp_dst_raddr   = '0;
        fp_arf_raddr   = '0;
        fp_src_has_port = '0;
        fp_src_port     = '0;
        fp_port_idx     = 0;

        if (slot0_isb.use_rs1 && slot0_isb.rs1_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot0_isb.rs1_idx;
            fp_arf_raddr[fp_port_idx]      = slot0_isb.rs1_idx;
            fp_src_has_port[FP_SRC_S0_RS1] = 1'b1;
            fp_src_port[FP_SRC_S0_RS1]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
        if (slot0_isb.use_rs2 && slot0_isb.rs2_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot0_isb.rs2_idx;
            fp_arf_raddr[fp_port_idx]      = slot0_isb.rs2_idx;
            fp_src_has_port[FP_SRC_S0_RS2] = 1'b1;
            fp_src_port[FP_SRC_S0_RS2]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
        if (slot0_isb.use_rs3 && slot0_isb.rs3_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot0_isb.rs3_idx;
            fp_arf_raddr[fp_port_idx]      = slot0_isb.rs3_idx;
            fp_src_has_port[FP_SRC_S0_RS3] = 1'b1;
            fp_src_port[FP_SRC_S0_RS3]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
        if (slot1_isb.use_rs1 && slot1_isb.rs1_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot1_isb.rs1_idx;
            fp_arf_raddr[fp_port_idx]      = slot1_isb.rs1_idx;
            fp_src_has_port[FP_SRC_S1_RS1] = 1'b1;
            fp_src_port[FP_SRC_S1_RS1]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
        if (slot1_isb.use_rs2 && slot1_isb.rs2_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot1_isb.rs2_idx;
            fp_arf_raddr[fp_port_idx]      = slot1_isb.rs2_idx;
            fp_src_has_port[FP_SRC_S1_RS2] = 1'b1;
            fp_src_port[FP_SRC_S1_RS2]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
        if (slot1_isb.use_rs3 && slot1_isb.rs3_is_fp && (fp_port_idx < 3)) begin
            fp_dst_raddr[fp_port_idx]      = slot1_isb.rs3_idx;
            fp_arf_raddr[fp_port_idx]      = slot1_isb.rs3_idx;
            fp_src_has_port[FP_SRC_S1_RS3] = 1'b1;
            fp_src_port[FP_SRC_S1_RS3]     = fp_port_idx[1:0];
            fp_port_idx++;
        end
    end

    // Commit Overlay Helper Logic
    function automatic logic check_commit_match(
        input logic [REG_ADDR_W-1:0] rs_idx,
        input logic rs_is_fp,
        input logic current_busy,
        input logic [TAG_W-1:0] current_tag,
        input commit_payload_t [1:0] c_pay,
        output logic [XLEN-1:0] data
    );
        if (c_pay[1].commit_valid &&
            rs_idx == c_pay[1].rd_idx &&
            rs_is_fp == c_pay[1].rd_is_fp &&
            (rs_idx != '0 || rs_is_fp) &&
            (!current_busy || current_tag == c_pay[1].commit_tag)) begin
            data = c_pay[1].result_data;
            return 1'b1;
        end else if (c_pay[0].commit_valid &&
                     rs_idx == c_pay[0].rd_idx &&
                     rs_is_fp == c_pay[0].rd_is_fp &&
                     (rs_idx != '0 || rs_is_fp) &&
                     (!current_busy || current_tag == c_pay[0].commit_tag)) begin
            data = c_pay[0].result_data;
            return 1'b1;
        end
        data = '0;
        return 1'b0;
    endfunction

    // Slot 0 Resolution
    logic [XLEN-1:0] s0_rs1_cdata, s0_rs2_cdata, s0_rs3_cdata;
    logic s0_rs1_cmatch, s0_rs2_cmatch, s0_rs3_cmatch;

    always_comb begin
        s0_rs1_cmatch = check_commit_match(
            slot0_isb.rs1_idx,
            slot0_isb.rs1_is_fp,
            slot0_isb.rs1_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS1]] : int_dst_rbusy[0],
            slot0_isb.rs1_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS1]] : int_dst_rtag[0],
            commit_payload,
            s0_rs1_cdata
        );
        s0_rs2_cmatch = check_commit_match(
            slot0_isb.rs2_idx,
            slot0_isb.rs2_is_fp,
            slot0_isb.rs2_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS2]] : int_dst_rbusy[1],
            slot0_isb.rs2_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS2]] : int_dst_rtag[1],
            commit_payload,
            s0_rs2_cdata
        );
        s0_rs3_cmatch = check_commit_match(
            slot0_isb.rs3_idx,
            slot0_isb.rs3_is_fp,
            slot0_isb.rs3_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS3]] : 1'b0,
            slot0_isb.rs3_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS3]] : '0,
            commit_payload,
            s0_rs3_cdata
        );

        // RS1
        if (!slot0_isb.use_rs1) begin
            slot0_rs1_ready = 1'b1;
            slot0_rs1_data  = '0;
            slot0_rs1_tag   = '0;
        end else if (s0_rs1_cmatch) begin
            slot0_rs1_ready = 1'b1;
            slot0_rs1_data  = s0_rs1_cdata;
            slot0_rs1_tag   = '0;
        end else if (slot0_isb.rs1_is_fp) begin
            if (fp_src_has_port[FP_SRC_S0_RS1]) begin
                slot0_rs1_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS1]];
                slot0_rs1_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS1]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S0_RS1]];
                slot0_rs1_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS1]] ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS1]] : '0;
            end else begin
                slot0_rs1_ready = 1'b0;
                slot0_rs1_data  = '0;
                slot0_rs1_tag   = '0;
            end
        end else begin
            slot0_rs1_ready = (slot0_isb.rs1_idx == '0) ? 1'b1 : !int_dst_rbusy[0];
            slot0_rs1_data  = (slot0_isb.rs1_idx == '0 || !int_dst_rbusy[0]) ? int_arf_rdata[0] : '0;
            slot0_rs1_tag   = (slot0_isb.rs1_idx == '0 || !int_dst_rbusy[0]) ? '0 : int_dst_rtag[0];
        end

        // RS2
        if (!slot0_isb.use_rs2) begin
            slot0_rs2_ready = 1'b1;
            slot0_rs2_data  = '0;
            slot0_rs2_tag   = '0;
        end else if (s0_rs2_cmatch) begin
            slot0_rs2_ready = 1'b1;
            slot0_rs2_data  = s0_rs2_cdata;
            slot0_rs2_tag   = '0;
        end else if (slot0_isb.rs2_is_fp) begin
            if (fp_src_has_port[FP_SRC_S0_RS2]) begin
                slot0_rs2_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS2]];
                slot0_rs2_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS2]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S0_RS2]];
                slot0_rs2_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS2]] ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS2]] : '0;
            end else begin
                slot0_rs2_ready = 1'b0;
                slot0_rs2_data  = '0;
                slot0_rs2_tag   = '0;
            end
        end else begin
            slot0_rs2_ready = (slot0_isb.rs2_idx == '0) ? 1'b1 : !int_dst_rbusy[1];
            slot0_rs2_data  = (slot0_isb.rs2_idx == '0 || !int_dst_rbusy[1]) ? int_arf_rdata[1] : '0;
            slot0_rs2_tag   = (slot0_isb.rs2_idx == '0 || !int_dst_rbusy[1]) ? '0 : int_dst_rtag[1];
        end

        // RS3
        if (!slot0_isb.use_rs3) begin
            slot0_rs3_ready = 1'b1;
            slot0_rs3_data  = '0;
            slot0_rs3_tag   = '0;
        end else if (s0_rs3_cmatch) begin
            slot0_rs3_ready = 1'b1;
            slot0_rs3_data  = s0_rs3_cdata;
            slot0_rs3_tag   = '0;
        end else if (slot0_isb.rs3_is_fp) begin
            if (fp_src_has_port[FP_SRC_S0_RS3]) begin
                slot0_rs3_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS3]];
                slot0_rs3_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS3]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S0_RS3]];
                slot0_rs3_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S0_RS3]] ? fp_dst_rtag[fp_src_port[FP_SRC_S0_RS3]] : '0;
            end else begin
                slot0_rs3_ready = 1'b0;
                slot0_rs3_data  = '0;
                slot0_rs3_tag   = '0;
            end
        end else begin
            slot0_rs3_ready = 1'b1; 
            slot0_rs3_data  = '0;
            slot0_rs3_tag   = '0;
        end
    end

    // Slot 1 Resolution
    logic [XLEN-1:0] s1_rs1_cdata, s1_rs2_cdata, s1_rs3_cdata;
    logic s1_rs1_cmatch, s1_rs2_cmatch, s1_rs3_cmatch;

    always_comb begin
        s1_rs1_cmatch = check_commit_match(
            slot1_isb.rs1_idx,
            slot1_isb.rs1_is_fp,
            slot1_isb.rs1_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS1]] : int_dst_rbusy[2],
            slot1_isb.rs1_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS1]] : int_dst_rtag[2],
            commit_payload,
            s1_rs1_cdata
        );
        s1_rs2_cmatch = check_commit_match(
            slot1_isb.rs2_idx,
            slot1_isb.rs2_is_fp,
            slot1_isb.rs2_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS2]] : int_dst_rbusy[3],
            slot1_isb.rs2_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS2]] : int_dst_rtag[3],
            commit_payload,
            s1_rs2_cdata
        );
        s1_rs3_cmatch = check_commit_match(
            slot1_isb.rs3_idx,
            slot1_isb.rs3_is_fp,
            slot1_isb.rs3_is_fp ? fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS3]] : 1'b0,
            slot1_isb.rs3_is_fp ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS3]] : '0,
            commit_payload,
            s1_rs3_cdata
        );

        // RS1
        if (!slot1_isb.use_rs1) begin
            slot1_rs1_ready = 1'b1;
            slot1_rs1_data  = '0;
            slot1_rs1_tag   = '0;
        end else if (slot0_overlay_valid && slot0_isb.use_rd && 
                   (slot1_isb.rs1_idx == slot0_isb.rd_idx) && 
                   (slot1_isb.rs1_is_fp == slot0_isb.rd_is_fp) &&
                   (slot1_isb.rs1_idx != '0 || slot1_isb.rs1_is_fp)) begin
            slot1_rs1_ready = 1'b0;
            slot1_rs1_data  = '0;
            slot1_rs1_tag   = slot0_alloc_tag;
        end else if (s1_rs1_cmatch) begin
            slot1_rs1_ready = 1'b1;
            slot1_rs1_data  = s1_rs1_cdata;
            slot1_rs1_tag   = '0;
        end else if (slot1_isb.rs1_is_fp) begin
            if (fp_src_has_port[FP_SRC_S1_RS1]) begin
                slot1_rs1_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS1]];
                slot1_rs1_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS1]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S1_RS1]];
                slot1_rs1_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS1]] ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS1]] : '0;
            end else begin
                slot1_rs1_ready = 1'b0;
                slot1_rs1_data  = '0;
                slot1_rs1_tag   = '0;
            end
        end else begin
            slot1_rs1_ready = (slot1_isb.rs1_idx == '0) ? 1'b1 : !int_dst_rbusy[2];
            slot1_rs1_data  = (slot1_isb.rs1_idx == '0 || !int_dst_rbusy[2]) ? int_arf_rdata[2] : '0;
            slot1_rs1_tag   = (slot1_isb.rs1_idx == '0 || !int_dst_rbusy[2]) ? '0 : int_dst_rtag[2];
        end

        // RS2
        if (!slot1_isb.use_rs2) begin
            slot1_rs2_ready = 1'b1;
            slot1_rs2_data  = '0;
            slot1_rs2_tag   = '0;
        end else if (slot0_overlay_valid && slot0_isb.use_rd && 
                   (slot1_isb.rs2_idx == slot0_isb.rd_idx) && 
                   (slot1_isb.rs2_is_fp == slot0_isb.rd_is_fp) &&
                   (slot1_isb.rs2_idx != '0 || slot1_isb.rs2_is_fp)) begin
            slot1_rs2_ready = 1'b0;
            slot1_rs2_data  = '0;
            slot1_rs2_tag   = slot0_alloc_tag;
        end else if (s1_rs2_cmatch) begin
            slot1_rs2_ready = 1'b1;
            slot1_rs2_data  = s1_rs2_cdata;
            slot1_rs2_tag   = '0;
        end else if (slot1_isb.rs2_is_fp) begin
            if (fp_src_has_port[FP_SRC_S1_RS2]) begin
                slot1_rs2_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS2]];
                slot1_rs2_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS2]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S1_RS2]];
                slot1_rs2_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS2]] ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS2]] : '0;
            end else begin
                slot1_rs2_ready = 1'b0;
                slot1_rs2_data  = '0;
                slot1_rs2_tag   = '0;
            end
        end else begin
            slot1_rs2_ready = (slot1_isb.rs2_idx == '0) ? 1'b1 : !int_dst_rbusy[3];
            slot1_rs2_data  = (slot1_isb.rs2_idx == '0 || !int_dst_rbusy[3]) ? int_arf_rdata[3] : '0;
            slot1_rs2_tag   = (slot1_isb.rs2_idx == '0 || !int_dst_rbusy[3]) ? '0 : int_dst_rtag[3];
        end

        // RS3
        if (!slot1_isb.use_rs3) begin
            slot1_rs3_ready = 1'b1;
            slot1_rs3_data  = '0;
            slot1_rs3_tag   = '0;
        end else if (slot0_overlay_valid && slot0_isb.use_rd && 
                   (slot1_isb.rs3_idx == slot0_isb.rd_idx) && 
                   (slot1_isb.rs3_is_fp == slot0_isb.rd_is_fp) &&
                   (slot1_isb.rs3_idx != '0 || slot1_isb.rs3_is_fp)) begin
            slot1_rs3_ready = 1'b0;
            slot1_rs3_data  = '0;
            slot1_rs3_tag   = slot0_alloc_tag;
        end else if (s1_rs3_cmatch) begin
            slot1_rs3_ready = 1'b1;
            slot1_rs3_data  = s1_rs3_cdata;
            slot1_rs3_tag   = '0;
        end else if (slot1_isb.rs3_is_fp) begin
            if (fp_src_has_port[FP_SRC_S1_RS3]) begin
                slot1_rs3_ready = !fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS3]];
                slot1_rs3_data  = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS3]] ? '0 : fp_arf_rdata[fp_src_port[FP_SRC_S1_RS3]];
                slot1_rs3_tag   = fp_dst_rbusy[fp_src_port[FP_SRC_S1_RS3]] ? fp_dst_rtag[fp_src_port[FP_SRC_S1_RS3]] : '0;
            end else begin
                slot1_rs3_ready = 1'b0;
                slot1_rs3_data  = '0;
                slot1_rs3_tag   = '0;
            end
        end else begin
            slot1_rs3_ready = 1'b1;
            slot1_rs3_data  = '0;
            slot1_rs3_tag   = '0;
        end
    end

endmodule

`endif // P1_SOURCE_RESOLUTION_SV
