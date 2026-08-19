module FP_ARF #(
    parameter int REG_W = 64,
    parameter int NUM_ENTRIES = 32,
    parameter int IDX_W = 5
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic [REG_W-1:0]     commit_data0,
    input  logic [REG_W-1:0]     commit_data1,
    input  logic                 commit_valid0,
    input  logic                 commit_valid1,
    input  logic                 commit_rd_write_enable0,
    input  logic                 commit_rd_write_enable1,
    input  logic                 commit_rd_is_fp0,
    input  logic                 commit_rd_is_fp1,
    input  logic [IDX_W-1:0]     commit_rd_idx0,
    input  logic [IDX_W-1:0]     commit_rd_idx1,

    input  logic [IDX_W-1:0]     fp_read_idx1,
    input  logic [IDX_W-1:0]     fp_read_idx2,
    input  logic [IDX_W-1:0]     fp_read_idx3,

    output logic [REG_W-1:0]     fp_read_data1,
    output logic [REG_W-1:0]     fp_read_data2,
    output logic [REG_W-1:0]     fp_read_data3
);

    logic [REG_W-1:0] rf [0:NUM_ENTRIES-1];
    logic             write_valid;
    logic [IDX_W-1:0] write_idx;
    logic [REG_W-1:0] write_data;

    function automatic logic [REG_W-1:0] read_rf(input logic [IDX_W-1:0] idx);
        return rf[idx];
    endfunction

    always_comb begin
        if (!rst_n) begin
            fp_read_data1 = '0;
            fp_read_data2 = '0;
            fp_read_data3 = '0;
        end else begin
            fp_read_data1 = read_rf(fp_read_idx1);
            fp_read_data2 = read_rf(fp_read_idx2);
            fp_read_data3 = read_rf(fp_read_idx3);
        end

        write_valid = 1'b0;
        write_idx   = '0;
        write_data  = '0;
        if (commit_valid0 && commit_rd_write_enable0 && commit_rd_is_fp0) begin
            write_valid = 1'b1;
            write_idx   = commit_rd_idx0;
            write_data  = commit_data0;
        end else if (commit_valid1 && commit_rd_write_enable1 && commit_rd_is_fp1) begin
            write_valid = 1'b1;
            write_idx   = commit_rd_idx1;
            write_data  = commit_data1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                rf[i] <= '0;
            end
        end else begin
            if (write_valid) begin
                rf[write_idx] <= write_data;
            end
        end
    end

endmodule
