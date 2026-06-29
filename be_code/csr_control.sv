`ifndef CSR_CONTROL_SV
`define CSR_CONTROL_SV

import orca_types::*;

module csr_control (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Dispatch (Set In-flight)
    input  logic        p1_csr_valid,
    input  logic [TAG_W-1:0] p1_csr_tag,
    output logic        csr_inflight_valid,
    output logic [TAG_W-1:0] csr_inflight_tag,

    // P3: Completion (Set Pending)
    input  logic        p3_csr_wb_valid,
    input  result_payload_t p3_csr_payload,
    output logic        csr_pend_valid,
    output logic [TAG_W-1:0] csr_pend_tag,
    output logic [11:0] csr_pend_addr,
    output logic [XLEN-1:0] csr_pend_wdata,

    // P4: Commit (Clear)
    input  logic        p4_csr_retire,
    
    // Global Flush
    input  logic        clear_csr_trackers
);

    // In-flight Tracker
    logic               inflight_v;
    logic [TAG_W-1:0]   inflight_tag;
    assign csr_inflight_valid = inflight_v;
    assign csr_inflight_tag   = inflight_tag;

    // Pending Buffer (CSR_PEND_BUF)
    logic               pend_v;
    logic [TAG_W-1:0]   pend_tag;
    logic [11:0]        pend_addr;
    logic [XLEN-1:0]    pend_wdata;
    assign csr_pend_valid = pend_v;
    assign csr_pend_tag   = pend_tag;
    assign csr_pend_addr  = pend_addr;
    assign csr_pend_wdata = pend_wdata;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inflight_v   <= 1'b0;
            inflight_tag <= '0;
            pend_v       <= 1'b0;
            pend_tag     <= '0;
            pend_addr    <= '0;
            pend_wdata   <= '0;
        end else if (clear_csr_trackers) begin
            inflight_v <= 1'b0;
            pend_v     <= 1'b0;
        end else begin
            // 1. Dispatch: Set in-flight
            if (p1_csr_valid) begin
                inflight_v   <= 1'b1;
                inflight_tag <= p1_csr_tag;
            end

            // 2. Completion: Set pending (from P3 result)
            if (p3_csr_wb_valid && p3_csr_payload.csr_write_enable && !p3_csr_payload.exception_flag) begin
                pend_v     <= 1'b1;
                pend_tag   <= p3_csr_payload.tag_out;
                pend_addr  <= p3_csr_payload.csr_addr;
                pend_wdata <= p3_csr_payload.csr_wdata;
            end

            // 3. Commit: Clear both (serialization complete)
            if (p4_csr_retire) begin
                inflight_v <= 1'b0;
                pend_v     <= 1'b0;
            end
        end
    end

endmodule

`endif // CSR_CONTROL_SV
