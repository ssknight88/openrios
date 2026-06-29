`ifndef ALU_SIMPLE_SV
`define ALU_SIMPLE_SV

import orca_types::*;
import exe_subop_pkg::*;

module alu_simple (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               flush_late,
    input  logic               en,
    input  logic [TAG_W-1:0]   self_rob_tag,
    input  logic [XLEN-1:0]    pc,
    input  logic [XLEN-1:0]    rs1,
    input  logic [XLEN-1:0]    rs2,
    input  logic               imm_valid,
    input  logic [XLEN-1:0]    imm_data,
    input  logic               pred_taken,
    input  logic [XLEN-1:0]    pred_target_pc,
    input  logic [EXE_SUBOP_W-1:0] exe_subop,
    input  logic [REG_ADDR_W-1:0]  rd_idx,
    input  logic               rd_is_fp,

    output result_payload_t    wb_payload,
    output logic               busy,
    output logic               wb_is_bru
);

    logic [XLEN-1:0] alu_result;
    logic [XLEN-1:0] branch_target;
    logic [XLEN-1:0] fallthrough_pc;
    logic [XLEN-1:0] correct_pc;
    logic            branch_taken;
    logic            is_bru_op;
    logic            mispredict_flag;
    logic            is_illegal_op;
    logic            is_ecall_op;
    logic            is_mret_op;
    assign is_illegal_op = en && (exe_subop == ALU_ILLEGAL);
    assign is_ecall_op = en && (exe_subop == ALU_ECALL);
    assign is_mret_op  = en && (exe_subop == ALU_MRET);

    assign busy = 1'b0;
    assign fallthrough_pc = pc + 64'd4;

    function automatic logic [63:0] sext32(input logic [31:0] value);
        return {{32{value[31]}}, value};
    endfunction

    always_comb begin
        alu_result = '0;
        case (exe_subop)
            ALU_ADD:   alu_result = rs1 + rs2;
            ALU_ADDI:  alu_result = rs1 + imm_data;
            ALU_SUB:   alu_result = rs1 - rs2;
            ALU_AND:   alu_result = rs1 & rs2;
            ALU_ANDI:  alu_result = rs1 & imm_data;
            ALU_OR:    alu_result = rs1 | rs2;
            ALU_ORI:   alu_result = rs1 | imm_data;
            ALU_XOR:   alu_result = rs1 ^ rs2;
            ALU_XORI:  alu_result = rs1 ^ imm_data;
            ALU_SLL:   alu_result = rs1 << rs2[5:0];
            ALU_SLLI:  alu_result = rs1 << imm_data[5:0];
            ALU_SRL:   alu_result = rs1 >> rs2[5:0];
            ALU_SRLI:  alu_result = rs1 >> imm_data[5:0];
            ALU_SRA:   alu_result = $signed(rs1) >>> rs2[5:0];
            ALU_SRAI:  alu_result = $signed(rs1) >>> imm_data[5:0];
            ALU_SLT:   alu_result = ($signed(rs1) < $signed(rs2)) ? 64'd1 : 64'd0;
            ALU_SLTI:  alu_result = ($signed(rs1) < $signed(imm_data)) ? 64'd1 : 64'd0;
            ALU_SLTU:  alu_result = (rs1 < rs2) ? 64'd1 : 64'd0;
            ALU_SLTIU: alu_result = (rs1 < imm_data) ? 64'd1 : 64'd0;
            ALU_LUI:   alu_result = imm_data;
            ALU_AUIPC: alu_result = pc + imm_data;

            ALU_ADDIW: alu_result = sext32(rs1[31:0] + imm_data[31:0]);
            ALU_ADDW:  alu_result = sext32(rs1[31:0] + rs2[31:0]);
            ALU_SUBW:  alu_result = sext32(rs1[31:0] - rs2[31:0]);
            ALU_SLLIW: alu_result = sext32(rs1[31:0] << imm_data[4:0]);
            ALU_SLLW:  alu_result = sext32(rs1[31:0] << rs2[4:0]);
            ALU_SRLIW: alu_result = sext32(rs1[31:0] >> imm_data[4:0]);
            ALU_SRLW:  alu_result = sext32(rs1[31:0] >> rs2[4:0]);
            ALU_SRAIW: alu_result = sext32($signed(rs1[31:0]) >>> imm_data[4:0]);
            ALU_SRAW:  alu_result = sext32($signed(rs1[31:0]) >>> rs2[4:0]);

            ALU_NOP:   alu_result = '0;
            ALU_ECALL: alu_result = '0;
            ALU_ILLEGAL: alu_result = '0;
            default:   alu_result = '0;
        endcase
    end

    always_comb begin
        is_bru_op = is_g0_bru(exe_subop);
        branch_taken = 1'b0;
        branch_target = fallthrough_pc;

        unique case (exe_subop)
            BRU_JAL: begin
                branch_taken = 1'b1;
                branch_target = pc + imm_data;
            end
            BRU_JALR: begin
                branch_taken = 1'b1;
                branch_target = (rs1 + imm_data) & ~64'd1;
            end
            BRU_BEQ: begin
                branch_taken = (rs1 == rs2);
                branch_target = pc + imm_data;
            end
            BRU_BNE: begin
                branch_taken = (rs1 != rs2);
                branch_target = pc + imm_data;
            end
            BRU_BLT: begin
                branch_taken = ($signed(rs1) < $signed(rs2));
                branch_target = pc + imm_data;
            end
            BRU_BGE: begin
                branch_taken = ($signed(rs1) >= $signed(rs2));
                branch_target = pc + imm_data;
            end
            BRU_BLTU: begin
                branch_taken = (rs1 < rs2);
                branch_target = pc + imm_data;
            end
            BRU_BGEU: begin
                branch_taken = (rs1 >= rs2);
                branch_target = pc + imm_data;
            end
            default: begin
                branch_taken = 1'b0;
                branch_target = fallthrough_pc;
            end
        endcase
    end

    assign correct_pc = branch_taken ? branch_target : fallthrough_pc;
    assign mispredict_flag = is_bru_op &&
                             ((branch_taken != pred_taken) ||
                              (branch_taken && (pred_target_pc != branch_target)));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
            wb_is_bru  <= 1'b0;
        end else if (flush_late) begin
            wb_payload <= '0;
            wb_is_bru  <= 1'b0;
        end else begin
            wb_payload <= '0;
            wb_is_bru  <= 1'b0;

            if (en) begin
                wb_payload.result_valid <= 1'b1;
                wb_payload.tag_out      <= self_rob_tag;
                wb_payload.rd_idx       <= rd_idx;
                wb_payload.is_fp        <= rd_is_fp;
                wb_payload.mispredict_flag <= mispredict_flag;
                wb_payload.correct_pc      <= correct_pc;
                wb_payload.exception_flag  <= is_illegal_op || is_ecall_op;
                wb_payload.exception_cause <= is_illegal_op ? 64'd2 :
                                              is_ecall_op ? 64'd11 : 64'd0;
                wb_payload.is_mret         <= is_mret_op;

                if (is_bru_op) begin
                    wb_is_bru <= 1'b1;
                    wb_payload.result_data <= ((exe_subop == BRU_JAL) || (exe_subop == BRU_JALR)) ? fallthrough_pc : '0;
                end else begin
                    wb_payload.result_data <= alu_result;
                end
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
            if (flush_late_q && (wb_payload.result_valid || wb_is_bru)) begin
                $error("[ALU] stale state after flush: wb_valid=%0b wb_is_bru=%0b tag=%0d",
                       wb_payload.result_valid, wb_is_bru, wb_payload.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule
`endif // ALU_SIMPLE_SV
