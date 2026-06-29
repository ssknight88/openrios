`ifndef P3_INTRA_GROUP_ARBITER_SV
`define P3_INTRA_GROUP_ARBITER_SV

import orca_types::*;

module p3_intra_group_arbiter (
    // Group 0 FU Results
    input  result_payload_t alu0_payload,
    input  result_payload_t div_payload,
    input  result_payload_t bru_payload,
    input  result_payload_t csr_payload,

    // Group 1 FU Results
    input  result_payload_t alu1_payload,
    input  result_payload_t mul_payload,

    // Group 2/3 (Direct)
    input  result_payload_t fpu_payload,
    input  result_payload_t lsu_payload,

    // Arbitration Winners (4 groups)
    output result_payload_t [3:0] group_wb_payload,

    // Feedback to FUs (Winner/Hold)
    output logic        alu0_ack,
    output logic        div_ack,
    output logic        bru_ack,
    output logic        csr_ack,
    output logic        alu1_ack,
    output logic        mul_ack
);

    // Group 0 Arbitration: ALU0 > BRU > CSR > DIV
    always_comb begin
        alu0_ack = 1'b0;
        div_ack  = 1'b0;
        bru_ack  = 1'b0;
        csr_ack  = 1'b0;
        group_wb_payload[0] = '0;

        if (alu0_payload.result_valid) begin
            alu0_ack = 1'b1;
            group_wb_payload[0] = alu0_payload;
        end else if (bru_payload.result_valid) begin
            bru_ack = 1'b1;
            group_wb_payload[0] = bru_payload;
        end else if (csr_payload.result_valid) begin
            csr_ack = 1'b1;
            group_wb_payload[0] = csr_payload;
        end else if (div_payload.result_valid) begin
            div_ack = 1'b1;
            group_wb_payload[0] = div_payload;
        end
    end

    // Group 1 Arbitration: ALU1 > MUL
    always_comb begin
        alu1_ack = 1'b0;
        mul_ack  = 1'b0;
        group_wb_payload[1] = '0;

        if (alu1_payload.result_valid) begin
            alu1_ack = 1'b1;
            group_wb_payload[1] = alu1_payload;
        end else if (mul_payload.result_valid) begin
            mul_ack = 1'b1;
            group_wb_payload[1] = mul_payload;
        end
    end

    // Group 2 (FPU)
    assign group_wb_payload[2] = fpu_payload;

    // Group 3 (LSU)
    assign group_wb_payload[3] = lsu_payload;

endmodule

`endif // P3_INTRA_GROUP_ARBITER_SV
