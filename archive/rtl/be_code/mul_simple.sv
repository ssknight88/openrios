`ifndef MUL_SIMPLE_SV
`define MUL_SIMPLE_SV

import orca_types::*;
import exe_subop_pkg::*;

module mul_simple (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               flush_late,
    input  logic               en,
    input  logic [TAG_W-1:0]   self_rob_tag,
    input  logic [XLEN-1:0]    rs1,
    input  logic [XLEN-1:0]    rs2,
    input  logic [EXE_SUBOP_W-1:0] exe_subop,
    input  logic [REG_ADDR_W-1:0]  rd_idx,
    input  logic               rd_is_fp,
    input  logic               ack,

    output result_payload_t    wb_payload,
    output logic               busy
);

    logic [XLEN-1:0] mul_result;
    logic signed [XLEN*2-1:0] full_res_ss;
    logic unsigned [XLEN*2-1:0] full_res_uu;
    logic signed [XLEN*2-1:0] full_res_su;

    logic signed [XLEN-1:0] rs1_s;
    logic signed [XLEN-1:0] rs2_s;
    logic unsigned [XLEN-1:0] rs1_u;
    logic unsigned [XLEN-1:0] rs2_u;

    logic [31:0] rs1_w;
    logic [31:0] rs2_w;

    assign rs1_s = rs1;
    assign rs2_s = rs2;
    assign rs1_u = rs1;
    assign rs2_u = rs2;

    assign rs1_w = rs1[31:0];
    assign rs2_w = rs2[31:0];

    logic               cnt;
    logic               busy_reg;

    logic [TAG_W-1:0]    reg_tag;
    logic [REG_ADDR_W-1:0] reg_rd_idx;
    logic                reg_rd_is_fp;
    logic [XLEN-1:0]     reg_result;

    assign busy = busy_reg;

    assign full_res_ss = rs1_s * rs2_s;
    assign full_res_uu = rs1_u * rs2_u;
    assign full_res_su = rs1_s * $signed({1'b0, rs2_u});

    always_comb begin
        logic [31:0] w_res;
        mul_result = '0;
        w_res = '0;
        case (exe_subop)
            MUL_MUL:    mul_result = full_res_ss[XLEN-1:0];
            MUL_MULH:   mul_result = full_res_ss[XLEN*2-1:XLEN];
            MUL_MULHU:  mul_result = full_res_uu[XLEN*2-1:XLEN];
            MUL_MULHSU: mul_result = full_res_su[XLEN*2-1:XLEN];
            MUL_MULW: begin
                w_res = rs1_w * rs2_w;
                mul_result = {{32{w_res[31]}}, w_res};
            end
            default:    mul_result = '0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 1'b0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_rd_idx  <= '0;
            reg_rd_is_fp<= 1'b0;
            reg_result  <= '0;
            wb_payload  <= '0;
        end else if (flush_late) begin
            cnt         <= 1'b0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_rd_idx  <= '0;
            reg_rd_is_fp<= 1'b0;
            reg_result  <= '0;
            wb_payload  <= '0;
        end else begin
            wb_payload  <= '0;

            if (busy_reg) begin
                if (cnt == 1'b0) begin // Cycle 2: Writeback state
                    wb_payload.result_valid <= 1'b1;
                    wb_payload.tag_out      <= reg_tag;
                    wb_payload.rd_idx       <= reg_rd_idx;
                    wb_payload.is_fp        <= reg_rd_is_fp;
                    wb_payload.result_data  <= reg_result;
                    wb_payload.mispredict_flag <= 1'b0;
                    wb_payload.exception_flag  <= 1'b0;
                    wb_payload.correct_pc      <= '0;
                    wb_payload.exception_cause <= '0;
                    wb_payload.is_csr          <= 1'b0;
                    wb_payload.csr_write_enable<= 1'b0;
                    wb_payload.csr_addr        <= '0;
                    wb_payload.csr_wdata       <= '0;

                    if (ack) begin // Writeback acknowledged!
                        busy_reg   <= 1'b0;
                        wb_payload <= '0;
                    end
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end else if (en) begin
                cnt         <= 1'b1; // Countdown: 1 (Cycle 1), 0 (Cycle 2 writeback)
                busy_reg    <= 1'b1;
                reg_tag     <= self_rob_tag;
                reg_rd_idx  <= rd_idx;
                reg_rd_is_fp<= rd_is_fp;
                reg_result  <= mul_result;
            end
        end
    end

`ifndef SYNTHESIS
    logic flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_late_q <= 1'b0;
        end else begin
            flush_late_q <= flush_late;
            if (flush_late_q && (busy_reg || wb_payload.result_valid)) begin
                $error("[MUL] stale state after flush: busy=%0b wb_valid=%0b tag=%0d",
                       busy_reg, wb_payload.result_valid, wb_payload.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // MUL_SIMPLE_SV
