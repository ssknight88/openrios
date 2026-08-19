module FP_read_address_mux #(
    parameter int IDX_W = 5
) (
    input  logic             is_fp_instruction0,
    input  logic [IDX_W-1:0]  slot0_rs1_idx,
    input  logic [IDX_W-1:0]  slot0_rs2_idx,
    input  logic [IDX_W-1:0]  slot0_rs3_idx,
    input  logic [IDX_W-1:0]  slot1_rs1_idx,
    input  logic [IDX_W-1:0]  slot1_rs2_idx,
    input  logic [IDX_W-1:0]  slot1_rs3_idx,

    output logic [IDX_W-1:0]  fp_read_idx1,
    output logic [IDX_W-1:0]  fp_read_idx2,
    output logic [IDX_W-1:0]  fp_read_idx3
);

    always_comb begin
        if (is_fp_instruction0) begin
            fp_read_idx1 = slot0_rs1_idx;
            fp_read_idx2 = slot0_rs2_idx;
            fp_read_idx3 = slot0_rs3_idx;
        end else begin
            fp_read_idx1 = slot1_rs1_idx;
            fp_read_idx2 = slot1_rs2_idx;
            fp_read_idx3 = slot1_rs3_idx;
        end
    end

endmodule
