`ifndef ARF_SV
`define ARF_SV

import orca_types::*;

module arf #(
    parameter NUM_READ_PORTS = 4,
    parameter NUM_WRITE_PORTS = 2,
    parameter IS_FP = 0,
    parameter REG_WIDTH = IS_FP ? FLEN : XLEN
) (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Source Resolution (Read)
    input  logic [NUM_READ_PORTS-1:0][REG_ADDR_W-1:0] rs_idx,
    output logic [NUM_READ_PORTS-1:0][REG_WIDTH-1:0]    rs_data,

    // P4: Commit (Write)
    input  commit_payload_t [NUM_WRITE_PORTS-1:0] commit_payload
);

    logic [31:0][REG_WIDTH-1:0] regs;

    // Read Logic
    genvar i;
    generate
        for (i = 0; i < NUM_READ_PORTS; i++) begin : gen_read_ports
            assign rs_data[i] = (rs_idx[i] == '0 && !IS_FP) ? '0 : regs[rs_idx[i]];
        end
    endgenerate

    // Sequential Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int k = 0; k < 32; k++) begin
                regs[k] <= '0;
            end
        end else begin
            // commit write
            for (int k = 0; k < NUM_WRITE_PORTS; k++) begin
                if (commit_payload[k].commit_valid && (commit_payload[k].rd_is_fp == IS_FP)) begin
                    if (commit_payload[k].rd_idx != '0 || IS_FP) begin
                        regs[commit_payload[k].rd_idx] <= commit_payload[k].result_data;
                    end
                end
            end
        end
    end

endmodule

`endif // ARF_SV
