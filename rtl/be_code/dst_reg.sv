`ifndef DST_REG_SV
`define DST_REG_SV

import orca_types::*;

module dst_reg #(
    parameter NUM_READ_PORTS = 4,
    parameter NUM_WRITE_PORTS = 2,
    parameter IS_FP = 0
) (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Source Resolution (Read)
    input  logic [NUM_READ_PORTS-1:0][REG_ADDR_W-1:0] rs_idx,
    output logic [NUM_READ_PORTS-1:0]              rs_busy,
    output logic [NUM_READ_PORTS-1:0][TAG_W-1:0]   rs_tag,

    // P1: Dispatch (Write)
    input  logic [NUM_WRITE_PORTS-1:0]             alloc_valid,
    input  logic [NUM_WRITE_PORTS-1:0][REG_ADDR_W-1:0] alloc_rd_idx,
    input  logic [NUM_WRITE_PORTS-1:0][TAG_W-1:0]   alloc_tag,

    // P4: Commit (Clear)
    input  commit_payload_t [1:0] commit_payload,

    // Global Flush
    input  logic                                   clear_all_busy
);

    typedef struct packed {
        logic               busy;
        logic [TAG_W-1:0]   tag;
    } dst_entry_t;

    dst_entry_t dst_table [31:0]; // Index 0 is always x0 (not busy)

    // Read Logic
    genvar i;
    generate
        for (i = 0; i < NUM_READ_PORTS; i++) begin : gen_read_ports
            assign rs_busy[i] = (rs_idx[i] == '0 && !IS_FP) ? 1'b0 : dst_table[rs_idx[i]].busy;
            assign rs_tag[i]  = dst_table[rs_idx[i]].tag;
        end
    endgenerate

    // Sequential Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 32; k++) begin
                dst_table[k] <= '0;
            end
        end else if (clear_all_busy) begin
            for (int k = 0; k < 32; k++) begin
                dst_table[k].busy <= 1'b0;
            end
        end else begin
            // 1. Commit: Clear busy bit if tag matches
            for (int k = 0; k < 2; k++) begin
                if (commit_payload[k].commit_valid && (commit_payload[k].rd_is_fp == IS_FP)) begin
                    if (dst_table[commit_payload[k].rd_idx].busy &&
                        (dst_table[commit_payload[k].rd_idx].tag == commit_payload[k].commit_tag)) begin
                        // Note: Only clear if the instruction committing is the one that set the busy bit
                        dst_table[commit_payload[k].rd_idx].busy <= 1'b0;
                    end
                end
            end

            // 2. Dispatch: Allocate new tags (overrides commit clear)
            for (int k = 0; k < NUM_WRITE_PORTS; k++) begin
                if (alloc_valid[k]) begin
                    if (alloc_rd_idx[k] != '0 || IS_FP) begin
                        dst_table[alloc_rd_idx[k]].busy <= 1'b1;
                        dst_table[alloc_rd_idx[k]].tag  <= alloc_tag[k];
                    end
                end
            end
        end
    end

endmodule

`endif // DST_REG_SV
