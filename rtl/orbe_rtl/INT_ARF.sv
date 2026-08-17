module INT_ARF #(
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

    input  logic [IDX_W-1:0]     slot0_rs1_idx,
    input  logic [IDX_W-1:0]     slot0_rs2_idx,
    input  logic [IDX_W-1:0]     slot1_rs1_idx,
    input  logic [IDX_W-1:0]     slot1_rs2_idx,

    output logic [REG_W-1:0]     slot0_rs1_data,
    output logic [REG_W-1:0]     slot0_rs2_data,
    output logic [REG_W-1:0]     slot1_rs1_data,
    output logic [REG_W-1:0]     slot1_rs2_data
);

    logic [REG_W-1:0] rf [0:NUM_ENTRIES-1];

    function automatic logic [REG_W-1:0] read_rf(input logic [IDX_W-1:0] idx);
        if (idx == '0) begin
            return '0;
        end
        return rf[idx];
    endfunction

    always_comb begin
        slot0_rs1_data = read_rf(slot0_rs1_idx);
        slot0_rs2_data = read_rf(slot0_rs2_idx);
        slot1_rs1_data = read_rf(slot1_rs1_idx);
        slot1_rs2_data = read_rf(slot1_rs2_idx);
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (commit_valid0 && commit_rd_write_enable0 && !commit_rd_is_fp0 && commit_rd_idx0 != '0) begin
                rf[commit_rd_idx0] <= commit_data0;
            end
            if (commit_valid1 && commit_rd_write_enable1 && !commit_rd_is_fp1 && commit_rd_idx1 != '0) begin
                rf[commit_rd_idx1] <= commit_data1;
            end
        end
    end

endmodule
