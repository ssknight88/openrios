module Buffer #(
    parameter int DATA_W = 64,
    parameter int NUM_ENTRIES = 16,
    parameter int TAG_W = 4
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 result_valid0,
    input  logic                 result_valid1,
    input  logic                 result_valid2,
    input  logic                 result_valid3,
    input  logic [TAG_W-1:0]     tag_out0,
    input  logic [TAG_W-1:0]     tag_out1,
    input  logic [TAG_W-1:0]     tag_out2,
    input  logic [TAG_W-1:0]     tag_out3,
    input  logic [DATA_W-1:0]    result_data0,
    input  logic [DATA_W-1:0]    result_data1,
    input  logic [DATA_W-1:0]    result_data2,
    input  logic [DATA_W-1:0]    result_data3,

    input  logic [TAG_W-1:0]     head0_tag,
    input  logic [TAG_W-1:0]     head1_tag,

    output logic [DATA_W-1:0]    commit_data0,
    output logic [DATA_W-1:0]    commit_data1
);

    logic [DATA_W-1:0] buffer_mem [0:NUM_ENTRIES-1];

    always_comb begin
        commit_data0 = buffer_mem[head0_tag];
        commit_data1 = buffer_mem[head1_tag];
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (result_valid0) begin
                buffer_mem[tag_out0] <= result_data0;
            end
            if (result_valid1) begin
                buffer_mem[tag_out1] <= result_data1;
            end
            if (result_valid2) begin
                buffer_mem[tag_out2] <= result_data2;
            end
            if (result_valid3) begin
                buffer_mem[tag_out3] <= result_data3;
            end
        end
    end

endmodule
