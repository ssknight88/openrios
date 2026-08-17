module FP_tag_mapping #(
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

    input  logic [IDX_W-1:0]     fp_read_idx1,
    input  logic [IDX_W-1:0]     fp_read_idx2,
    input  logic [IDX_W-1:0]     fp_read_idx3,

    output logic [TAG_W-1:0]     fp_read_tag1,
    output logic                 fp_read_busy1,
    output logic [TAG_W-1:0]     fp_read_tag2,
    output logic                 fp_read_busy2,
    output logic [TAG_W-1:0]     fp_read_tag3,
    output logic                 fp_read_busy3
);

    logic [TAG_W-1:0] tag_q  [0:NUM_ENTRIES-1];
    logic             busy_q [0:NUM_ENTRIES-1];
    logic             alloc_valid;
    logic [IDX_W-1:0] alloc_idx;
    logic [TAG_W-1:0] alloc_tag;
    logic             clear_valid;
    logic [IDX_W-1:0] clear_idx;
    logic [TAG_W-1:0] clear_tag;

    function automatic logic [TAG_W-1:0] read_tag(input logic [IDX_W-1:0] idx);
        return tag_q[idx];
    endfunction

    function automatic logic read_busy(input logic [IDX_W-1:0] idx);
        return busy_q[idx];
    endfunction

    always_comb begin
        if (!rst_n) begin
            fp_read_tag1  = '0;
            fp_read_busy1 = 1'b0;
            fp_read_tag2  = '0;
            fp_read_busy2 = 1'b0;
            fp_read_tag3  = '0;
            fp_read_busy3 = 1'b0;
        end else begin
            fp_read_tag1  = read_tag(fp_read_idx1);
            fp_read_busy1 = read_busy(fp_read_idx1);
            fp_read_tag2  = read_tag(fp_read_idx2);
            fp_read_busy2 = read_busy(fp_read_idx2);
            fp_read_tag3  = read_tag(fp_read_idx3);
            fp_read_busy3 = read_busy(fp_read_idx3);
        end

        alloc_valid = 1'b0;
        alloc_idx   = '0;
        alloc_tag   = '0;
        if (accept0 && alloc_rd_write_enable0 && alloc_rd_is_fp0) begin
            alloc_valid = 1'b1;
            alloc_idx   = alloc_rd_idx0;
            alloc_tag   = self_tag0;
        end else if (accept1 && alloc_rd_write_enable1 && alloc_rd_is_fp1) begin
            alloc_valid = 1'b1;
            alloc_idx   = alloc_rd_idx1;
            alloc_tag   = self_tag1;
        end

        clear_valid = 1'b0;
        clear_idx   = '0;
        clear_tag   = '0;
        if (commit_valid0 && commit_rd_write_enable0 && commit_rd_is_fp0) begin
            clear_valid = 1'b1;
            clear_idx   = commit_rd_idx0;
            clear_tag   = commit_tag0;
        end else if (commit_valid1 && commit_rd_write_enable1 && commit_rd_is_fp1) begin
            clear_valid = 1'b1;
            clear_idx   = commit_rd_idx1;
            clear_tag   = commit_tag1;
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
            if (clear_valid && tag_q[clear_idx] == clear_tag) begin
                busy_q[clear_idx] <= 1'b0;
            end

            if (alloc_valid) begin
                busy_q[alloc_idx] <= 1'b1;
                tag_q[alloc_idx]  <= alloc_tag;
            end
        end
    end

endmodule
