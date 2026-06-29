`ifndef P2_FU_INPUT_MUX_SV
`define P2_FU_INPUT_MUX_SV

import orca_types::*;

module p2_fu_input_mux (
    input  isq_payload_t isq_payload,
    input  bypass_t [3:0] bypass_bus,

    output logic [XLEN-1:0] rs1_source,
    output logic [XLEN-1:0] rs2_source,
    output logic [XLEN-1:0] rs3_source
);

    function automatic logic [XLEN-1:0] select_operand(
        input logic ready,
        input [XLEN-1:0] data,
        input [TAG_W-1:0] wait_tag,
        input bypass_t [3:0] b_bus
    );
        if (ready) return data;
        
        // Check bypass match
        for (int i = 0; i < 4; i++) begin
            if (b_bus[i].valid && (wait_tag == b_bus[i].tag)) begin
                return b_bus[i].data;
            end
        end

        return '0; // Should not happen if issue logic is correct
    endfunction

    assign rs1_source = select_operand(isq_payload.rs1_ready, isq_payload.rs1_data, isq_payload.rs1_wait_tag, bypass_bus);
    assign rs2_source = select_operand(isq_payload.rs2_ready, isq_payload.rs2_data, isq_payload.rs2_wait_tag, bypass_bus);
    assign rs3_source = select_operand(isq_payload.rs3_ready, isq_payload.rs3_data, isq_payload.rs3_wait_tag, bypass_bus);

endmodule

`endif // P2_FU_INPUT_MUX_SV
