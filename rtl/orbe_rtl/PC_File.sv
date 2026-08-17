module PC_File #(
    parameter int DATA_W = 64,
    parameter int NUM_ENTRIES = 16,
    parameter int IDX_W = 4
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 accept0,
    input  logic                 accept1,
    input  logic [IDX_W-1:0]     self_tag0,
    input  logic [IDX_W-1:0]     self_tag1,
    input  logic [DATA_W-1:0]    pc0,
    input  logic [DATA_W-1:0]    pc1,

    input  logic [IDX_W-1:0]     flush_tag,

    output logic [DATA_W-1:0]    inst_pc
);

    logic [DATA_W-1:0] pc_mem [0:NUM_ENTRIES-1];

    always_comb begin
        inst_pc = pc_mem[flush_tag];
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (accept0) begin
                pc_mem[self_tag0] <= pc0;
            end
            if (accept1) begin
                pc_mem[self_tag1] <= pc1;
            end
        end
    end

endmodule
