`ifndef FPU_SIMPLE_SV
`define FPU_SIMPLE_SV

import orca_types::*;
import exe_subop_pkg::*;

module fpu_simple (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               flush_late,
    input  logic               en,
    input  logic [TAG_W-1:0]   self_rob_tag,
    input  logic [FLEN-1:0]    rs1,
    input  logic [FLEN-1:0]    rs2,
    input  logic [FLEN-1:0]    rs3,
    input  logic [EXE_SUBOP_W-1:0] exe_subop,
    input  logic [XLEN-1:0]    fpu_meta,
    input  logic [REG_ADDR_W-1:0]  rd_idx,
    input  logic               rd_is_fp,
    input  logic               fs_enabled,
    input  logic [2:0]         frm,            // architectural fcsr.frm, used when rm field == dynamic

    output result_payload_t    wb_payload,
    output logic               busy
);

`ifndef SYNTHESIS
    import "DPI-C" function longint dpi_fpu_exec(
        input int subop,
        input longint rs1,
        input longint rs2,
        input longint rs3,
        input int fmt,
        input int rm,
        output int fflags
    );
`endif

    logic [1:0] fpu_fmt;
    logic [2:0] fpu_rm;
    logic [2:0] fpu_eff_rm;
    logic [FLEN-1:0] fpu_result;
    logic [4:0] fpu_fflags_c;

    assign fpu_fmt = fpu_meta[1:0];
    assign fpu_rm  = fpu_meta[4:2];
    // Dynamic rounding (rm == 3'b111) resolves to the architectural fcsr.frm.
    assign fpu_eff_rm = (fpu_rm == 3'b111) ? frm : fpu_rm;

`ifndef SYNTHESIS
    always_comb begin
        int fflags_raw;
        fpu_result   = '0;
        fflags_raw   = 0;
        fpu_fflags_c = '0;
        if (fs_enabled) begin
            fpu_result = dpi_fpu_exec(
                int'(exe_subop),
                longint'(rs1),
                longint'(rs2),
                longint'(rs3),
                int'(fpu_fmt),
                int'(fpu_eff_rm),
                fflags_raw
            );
            fpu_fflags_c = fflags_raw[4:0];
        end
    end
`else
    always_comb begin
        fpu_result   = '0;
        fpu_fflags_c = '0;
    end
`endif
    assign busy = 1'b0;

`ifndef SYNTHESIS
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
        end else if (flush_late) begin
            wb_payload <= '0;
        end else begin
            wb_payload <= '0;
            if (en) begin
                wb_payload.result_valid      <= 1'b1;
                wb_payload.tag_out           <= self_rob_tag;
                wb_payload.rd_idx            <= rd_idx;
                wb_payload.is_fp             <= fs_enabled && rd_is_fp;
                wb_payload.result_data       <= fs_enabled ? fpu_result : '0;
                wb_payload.mispredict_flag   <= 1'b0;
                wb_payload.exception_flag    <= !fs_enabled;
                wb_payload.correct_pc        <= '0;
                wb_payload.exception_cause   <= fs_enabled ? '0 : 64'd2;
                wb_payload.is_csr            <= 1'b0;
                wb_payload.csr_write_enable  <= 1'b0;
                wb_payload.csr_addr          <= '0;
                wb_payload.csr_wdata         <= '0;
                wb_payload.fpu_fflags        <= fpu_fflags_c; // accrued at commit into fcsr.fflags
            end
        end
    end
`else
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
        end else if (flush_late) begin
            wb_payload <= '0;
        end else begin
            wb_payload <= '0;
            if (en) begin
                wb_payload.result_valid      <= 1'b1;
                wb_payload.tag_out           <= self_rob_tag;
                wb_payload.rd_idx            <= rd_idx;
                wb_payload.is_fp             <= fs_enabled && rd_is_fp;
                wb_payload.result_data       <= '0;
                wb_payload.mispredict_flag   <= 1'b0;
                wb_payload.exception_flag    <= 1'b1;
                wb_payload.correct_pc        <= '0;
                wb_payload.exception_cause   <= 64'd2;
                wb_payload.is_csr            <= 1'b0;
                wb_payload.csr_write_enable  <= 1'b0;
                wb_payload.csr_addr          <= '0;
                wb_payload.csr_wdata         <= '0;
                wb_payload.fpu_fflags        <= '0;
            end
        end
    end
`endif

`ifndef SYNTHESIS
    logic flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_late_q <= 1'b0;
        end else begin
            flush_late_q <= flush_late;
            if (flush_late_q && wb_payload.result_valid) begin
                $error("[FPU] stale writeback after flush: wb_valid=%0b tag=%0d",
                       wb_payload.result_valid, wb_payload.tag_out);
                $stop;
            end
        end
    end
`endif

endmodule

`endif // FPU_SIMPLE_SV
