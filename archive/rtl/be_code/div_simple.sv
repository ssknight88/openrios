`ifndef DIV_SIMPLE_SV
`define DIV_SIMPLE_SV

import orca_types::*;
import exe_subop_pkg::*;

module div_simple (
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

    logic [XLEN-1:0] div_result;

    logic signed [XLEN-1:0] rs1_s;
    logic signed [XLEN-1:0] rs2_s;
    logic unsigned [XLEN-1:0] rs1_u;
    logic unsigned [XLEN-1:0] rs2_u;

    logic [31:0] rs1_w;
    logic [31:0] rs2_w;
    logic signed [31:0] rs1_w_s;
    logic signed [31:0] rs2_w_s;

    assign rs1_s = rs1;
    assign rs2_s = rs2;
    assign rs1_u = rs1;
    assign rs2_u = rs2;

    assign rs1_w = rs1[31:0];
    assign rs2_w = rs2[31:0];
    assign rs1_w_s = rs1[31:0];
    assign rs2_w_s = rs2[31:0];

    logic [1:0] cnt;
    logic       busy_reg;

    logic [TAG_W-1:0]    reg_tag;
    logic [REG_ADDR_W-1:0] reg_rd_idx;
    logic                reg_rd_is_fp;
    logic [XLEN-1:0]     reg_result;
    logic                reg_exception;
    logic [XLEN-1:0]     reg_exception_cause;

    assign busy = busy_reg;

    logic is_div_op;
    logic div_by_zero;
    always_comb begin
        is_div_op = en && (exe_subop == DIV_DIV_EXC);
        div_by_zero = is_div_op && (rs2 == 64'h0);
    end

    always_comb begin
        logic [31:0] w_res;
        div_result = '0;
        w_res = '0;
        case (exe_subop)
            DIV_DIV, DIV_DIV_EXC: begin
                if (rs2 == 0) div_result = '1;
                else if (rs1_s == {1'b1, {(XLEN-1){1'b0}}} && rs2_s == -1) div_result = rs1_s;
                else div_result = rs1_s / rs2_s;
            end
            DIV_DIVU: begin
                if (rs2 == 0) div_result = '1;
                else div_result = rs1_u / rs2_u;
            end
            DIV_REM: begin
                if (rs2 == 0) div_result = rs1;
                else if (rs1_s == {1'b1, {(XLEN-1){1'b0}}} && rs2_s == -1) div_result = '0;
                else div_result = rs1_s % rs2_s;
            end
            DIV_REMU: begin
                if (rs2 == 0) div_result = rs1;
                else div_result = rs1_u % rs2_u;
            end
            DIV_DIVW: begin
                if (rs2_w == 0) w_res = '1;
                else if (rs1_w_s == 32'h80000000 && rs2_w_s == -1) w_res = rs1_w_s;
                else w_res = rs1_w_s / rs2_w_s;
                div_result = {{32{w_res[31]}}, w_res};
            end
            DIV_DIVUW: begin
                if (rs2_w == 0) w_res = '1;
                else w_res = rs1_w / rs2_w;
                div_result = {{32{w_res[31]}}, w_res};
            end
            DIV_REMW: begin
                if (rs2_w == 0) w_res = rs1_w;
                else if (rs1_w_s == 32'h80000000 && rs2_w_s == -1) w_res = '0;
                else w_res = rs1_w_s % rs2_w_s;
                div_result = {{32{w_res[31]}}, w_res};
            end
            DIV_REMUW: begin
                if (rs2_w == 0) w_res = rs1_w;
                else w_res = rs1_w % rs2_w;
                div_result = {{32{w_res[31]}}, w_res};
            end
            default: div_result = '0;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= 2'd0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_rd_idx  <= '0;
            reg_rd_is_fp<= 1'b0;
            reg_result  <= '0;
            reg_exception <= 1'b0;
            reg_exception_cause <= '0;
            wb_payload  <= '0;
        end else if (flush_late) begin
            cnt         <= 2'd0;
            busy_reg    <= 1'b0;
            reg_tag     <= '0;
            reg_rd_idx  <= '0;
            reg_rd_is_fp<= 1'b0;
            reg_result  <= '0;
            reg_exception <= 1'b0;
            reg_exception_cause <= '0;
            wb_payload  <= '0;
        end else begin
            wb_payload  <= '0;

            if (busy_reg) begin
                if (cnt == 2'd0) begin // Cycle 3: Writeback state
                    wb_payload.result_valid <= 1'b1;
                    wb_payload.tag_out      <= reg_tag;
                    wb_payload.rd_idx       <= reg_rd_idx;
                    wb_payload.is_fp        <= reg_rd_is_fp;
                    wb_payload.result_data  <= reg_result;
                    wb_payload.mispredict_flag <= 1'b0;
                    wb_payload.exception_flag  <= reg_exception;
                    wb_payload.correct_pc      <= '0;
                    wb_payload.exception_cause <= reg_exception_cause;
                    wb_payload.is_csr          <= 1'b0;
                    wb_payload.csr_write_enable<= 1'b0;
                    wb_payload.csr_addr        <= '0;
                    wb_payload.csr_wdata       <= '0;

                    if (ack) begin // Writeback acknowledged!
                        busy_reg   <= 1'b0;
                        wb_payload <= '0;
                    end
                end else begin
                    cnt <= cnt - 2'd1;
                end
            end else if (en) begin
                cnt         <= 2'd2; // Countdown: 2 (Cycle 1), 1 (Cycle 2), 0 (Cycle 3 writeback)
                busy_reg    <= 1'b1;
                reg_tag     <= self_rob_tag;
                reg_rd_idx  <= rd_idx;
                reg_rd_is_fp<= rd_is_fp;
                reg_result  <= div_result;
                reg_exception <= div_by_zero;
                reg_exception_cause <= div_by_zero ? 64'd15 : 64'd0;
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
                $error("[DIV] stale state after flush: busy=%0b wb_valid=%0b tag=%0d",
                       busy_reg, wb_payload.result_valid, wb_payload.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // DIV_SIMPLE_SV
