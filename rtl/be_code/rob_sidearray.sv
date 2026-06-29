`ifndef ROB_SIDEARRAY_SV
`define ROB_SIDEARRAY_SV

import orca_types::*;

module rob_sidearray (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Allocation (Initialize PC and clear valid bit)
    input  logic [1:0]  alloc_valid,
    input  logic [TAG_W-1:0] alloc_tag_0,
    input  logic [TAG_W-1:0] alloc_tag_1,
    input  logic [1:0][XLEN-1:0] alloc_pc,

    // P3: Writeback (Capture meta if flag set)
    input  logic [3:0]  wb_valid,
    input  result_payload_t [3:0] wb_payload,

    // LSU store drain completion exception metadata
    input  logic        store_done_valid,
    input  logic [TAG_W-1:0] store_done_tag,
    input  logic        store_done_exception,
    input  logic [XLEN-1:0] store_done_cause,

    // P4: Flush Lookup
    input  logic [TAG_W-1:0] flush_tag,
    output sidearray_entry_t flush_meta,

    // Global Flush
    input  logic        clear_metaarray_flushvalid
);

    sidearray_entry_t [ROB_DEPTH-1:0] sidearray;

    // Read Logic
    assign flush_meta = sidearray[flush_tag];

    // Sequential Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < ROB_DEPTH; i++) begin
                sidearray[i] <= '0;
            end
        end else if (clear_metaarray_flushvalid) begin
            for (int i = 0; i < ROB_DEPTH; i++) begin
                sidearray[i].valid <= 1'b0;
            end
        end else begin
            // 1. Allocation: Initialize PC and clear valid bits for new tags
            if (alloc_valid[1]) begin
                sidearray[alloc_tag_0].valid   <= 1'b0;
                sidearray[alloc_tag_0].kind    <= FLUSH_NONE;
                sidearray[alloc_tag_0].inst_pc <= alloc_pc[0];
                sidearray[alloc_tag_0].target_pc <= '0;
                sidearray[alloc_tag_0].exception_cause <= '0;
                sidearray[alloc_tag_1].valid   <= 1'b0;
                sidearray[alloc_tag_1].kind    <= FLUSH_NONE;
                sidearray[alloc_tag_1].inst_pc <= alloc_pc[1];
                sidearray[alloc_tag_1].target_pc <= '0;
                sidearray[alloc_tag_1].exception_cause <= '0;
            end else if (alloc_valid[0]) begin
                sidearray[alloc_tag_0].valid   <= 1'b0;
                sidearray[alloc_tag_0].kind    <= FLUSH_NONE;
                sidearray[alloc_tag_0].inst_pc <= alloc_pc[0];
                sidearray[alloc_tag_0].target_pc <= '0;
                sidearray[alloc_tag_0].exception_cause <= '0;
            end

            // 2. Writeback: Capture metadata on mispredict or exception
            for (int i = 0; i < 4; i++) begin
                if (wb_valid[i]) begin
                    if (wb_payload[i].mispredict_flag || wb_payload[i].exception_flag) begin
                        sidearray[wb_payload[i].tag_out].valid           <= 1'b1;
                        sidearray[wb_payload[i].tag_out].kind            <= wb_payload[i].mispredict_flag ? FLUSH_MISPREDICT : FLUSH_EXCEPTION;
                        if (wb_payload[i].mispredict_flag) begin
                            sidearray[wb_payload[i].tag_out].target_pc       <= wb_payload[i].correct_pc;
                            sidearray[wb_payload[i].tag_out].exception_cause <= '0;
                            sidearray[wb_payload[i].tag_out].exception_tval  <= '0;
                        end else begin
                            sidearray[wb_payload[i].tag_out].target_pc       <= '0;
                            sidearray[wb_payload[i].tag_out].exception_cause <= wb_payload[i].exception_cause;
                            sidearray[wb_payload[i].tag_out].exception_tval  <= wb_payload[i].exception_tval;
                        end
                    end
                end
            end

            if (store_done_valid && store_done_exception) begin
                sidearray[store_done_tag].valid           <= 1'b1;
                sidearray[store_done_tag].kind            <= FLUSH_EXCEPTION;
                sidearray[store_done_tag].target_pc       <= '0;
                sidearray[store_done_tag].exception_cause <= store_done_cause;
                sidearray[store_done_tag].exception_tval  <= '0; // STB drain has no faulting addr exposed here
            end
        end
    end

endmodule

`endif // ROB_SIDEARRAY_SV
