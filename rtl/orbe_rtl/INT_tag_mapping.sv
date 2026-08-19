module INT_tag_mapping #(
    parameter int TAG_W = 4,
    parameter int NUM_ENTRIES = 32,
    parameter int IDX_W = 5
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 accept0,
    input  logic                 accept1,
    input  logic                 alloc_rd_write_enable0,
    input  logic                 alloc_rd_write_enable1,
    input  logic                 alloc_rd_is_fp0,
    input  logic                 alloc_rd_is_fp1,
    input  logic [IDX_W-1:0]     alloc_rd_idx0,
    input  logic [IDX_W-1:0]     alloc_rd_idx1,
    input  logic [TAG_W-1:0]     self_tag0,
    input  logic [TAG_W-1:0]     self_tag1,

    input  logic                 commit_valid0,
    input  logic                 commit_valid1,
    input  logic                 commit_rd_write_enable0,
    input  logic                 commit_rd_write_enable1,
    input  logic                 commit_rd_is_fp0,
    input  logic                 commit_rd_is_fp1,
    input  logic [IDX_W-1:0]     commit_rd_idx0,
    input  logic [IDX_W-1:0]     commit_rd_idx1,
    input  logic [TAG_W-1:0]     commit_tag0,
    input  logic [TAG_W-1:0]     commit_tag1,

    input  logic                 global_flush_late,

    input  logic [IDX_W-1:0]     slot0_rs1_idx,
    input  logic [IDX_W-1:0]     slot0_rs2_idx,
    input  logic [IDX_W-1:0]     slot1_rs1_idx,
    input  logic [IDX_W-1:0]     slot1_rs2_idx,

    output logic [TAG_W-1:0]     slot0_rs1_tag,
    output logic                 slot0_rs1_busy,
    output logic [TAG_W-1:0]     slot0_rs2_tag,
    output logic                 slot0_rs2_busy,
    output logic [TAG_W-1:0]     slot1_rs1_tag,
    output logic                 slot1_rs1_busy,
    output logic [TAG_W-1:0]     slot1_rs2_tag,
    output logic                 slot1_rs2_busy
);

    logic [TAG_W-1:0] tag_q  [0:NUM_ENTRIES-1];
    logic             busy_q [0:NUM_ENTRIES-1];

    function automatic logic [TAG_W-1:0] read_tag(input logic [IDX_W-1:0] idx);
        if (idx == '0) begin
            return '0;
        end
        return tag_q[idx];
    endfunction

    function automatic logic read_busy(input logic [IDX_W-1:0] idx);
        if (idx == '0) begin
            return 1'b0;
        end
        return busy_q[idx];
    endfunction

    always_comb begin
        if (!rst_n) begin
            slot0_rs1_tag  = '0;
            slot0_rs1_busy = 1'b0;
            slot0_rs2_tag  = '0;
            slot0_rs2_busy = 1'b0;
            slot1_rs1_tag  = '0;
            slot1_rs1_busy = 1'b0;
            slot1_rs2_tag  = '0;
            slot1_rs2_busy = 1'b0;
        end else begin
            slot0_rs1_tag  = read_tag(slot0_rs1_idx);
            slot0_rs1_busy = read_busy(slot0_rs1_idx);
            slot0_rs2_tag  = read_tag(slot0_rs2_idx);
            slot0_rs2_busy = read_busy(slot0_rs2_idx);
            slot1_rs1_tag  = read_tag(slot1_rs1_idx);
            slot1_rs1_busy = read_busy(slot1_rs1_idx);
            slot1_rs2_tag  = read_tag(slot1_rs2_idx);
            slot1_rs2_busy = read_busy(slot1_rs2_idx);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                tag_q[i]  <= '0;
                busy_q[i] <= 1'b0;
            end
        end else if (global_flush_late) begin
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                busy_q[i] <= 1'b0;
            end
        end else begin
            if (commit_valid0 && commit_rd_write_enable0 && !commit_rd_is_fp0 && commit_rd_idx0 != '0 && tag_q[commit_rd_idx0] == commit_tag0) begin
                busy_q[commit_rd_idx0] <= 1'b0;
            end
            if (commit_valid1 && commit_rd_write_enable1 && !commit_rd_is_fp1 && commit_rd_idx1 != '0 && tag_q[commit_rd_idx1] == commit_tag1) begin
                busy_q[commit_rd_idx1] <= 1'b0;
            end

            if (accept0 && alloc_rd_write_enable0 && !alloc_rd_is_fp0 && alloc_rd_idx0 != '0) begin
                busy_q[alloc_rd_idx0] <= 1'b1;
                tag_q[alloc_rd_idx0]  <= self_tag0;
            end
            if (accept1 && alloc_rd_write_enable1 && !alloc_rd_is_fp1 && alloc_rd_idx1 != '0) begin
                busy_q[alloc_rd_idx1] <= 1'b1;
                tag_q[alloc_rd_idx1]  <= self_tag1;
            end
        end
    end

endmodule
