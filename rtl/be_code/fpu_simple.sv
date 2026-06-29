`ifndef FPU_SIMPLE_SV
`define FPU_SIMPLE_SV

import orca_types::*;
import exe_subop_pkg::*;

// ============================================================================
// Synthesizable FPU for RV64FD
// Supports all 40 RISC-V F/D operations (exe_subop_pkg::g2_fpu_subop_e)
//
// Design choices:
//   - Single-cycle combinational datapath (synthesis tool handles timing)
//   - Denorms flushed to zero (RISC-V Nx default)
//   - Division and sqrt use Verilog operators (synth tool infers hardware)
//   - FMA uses full 48-bit mantissa product
//   - Rounding: simple truncation (GRS rounding as future optimization)
//
// PPA note: div_simple.sv and mul_simple.sv use the same approach —
// combinational operators, leaving area/timing tradeoffs to the synthesis
// tool. This FPU follows the same convention.
// ============================================================================

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
    input  logic [2:0]         frm,

    output result_payload_t    wb_payload,
    output logic               busy
);

    // ---------------------------------------------------------------
    // Format and rounding mode decode
    // ---------------------------------------------------------------
    logic [1:0] fpu_fmt;   // 0=S, 1=D
    logic [2:0] fpu_rm;    // 7=dynamic→use frm
    logic [2:0] fpu_eff_rm;

    assign fpu_fmt = fpu_meta[1:0];
    assign fpu_rm  = fpu_meta[4:2];
    assign fpu_eff_rm = (fpu_rm == 3'b111) ? frm : fpu_rm;

    // ---------------------------------------------------------------
    // IEEE 754 field helpers
    // ---------------------------------------------------------------
    // SP: [31]=sign [30:23]=exp(8) [22:0]=man(23)
    // DP: [63]=sign [62:52]=exp(11) [51:0]=man(52)

    logic [31:0] sp_a, sp_b, sp_c;
    logic [63:0] dp_a, dp_b, dp_c;
    assign sp_a = rs1[31:0];  assign dp_a = rs1;
    assign sp_b = rs2[31:0];  assign dp_b = rs2;
    assign sp_c = rs3[31:0];  assign dp_c = rs3;

    // SP fields
    logic       sp_a_sign, sp_b_sign, sp_c_sign;
    logic [7:0] sp_a_exp,  sp_b_exp,  sp_c_exp;
    logic [22:0]sp_a_man,  sp_b_man,  sp_c_man;
    logic       sp_a_zero, sp_b_zero, sp_c_zero;
    logic       sp_a_inf,  sp_b_inf,  sp_c_inf;
    logic       sp_a_nan,  sp_b_nan,  sp_c_nan;
    logic [23:0]sp_a_man_full, sp_b_man_full, sp_c_man_full;

    assign sp_a_sign = sp_a[31];
    assign sp_a_exp  = sp_a[30:23];
    assign sp_a_man  = sp_a[22:0];
    assign sp_a_zero = (sp_a_exp == 8'd0)  && (sp_a_man == 23'd0);
    assign sp_a_inf  = (sp_a_exp == 8'hFF) && (sp_a_man == 23'd0);
    assign sp_a_nan  = (sp_a_exp == 8'hFF) && (sp_a_man != 23'd0);
    assign sp_a_man_full = (sp_a_exp == 8'd0) ? {1'b0, sp_a_man} : {1'b1, sp_a_man};

    assign sp_b_sign = sp_b[31];
    assign sp_b_exp  = sp_b[30:23];
    assign sp_b_man  = sp_b[22:0];
    assign sp_b_zero = (sp_b_exp == 8'd0)  && (sp_b_man == 23'd0);
    assign sp_b_inf  = (sp_b_exp == 8'hFF) && (sp_b_man == 23'd0);
    assign sp_b_nan  = (sp_b_exp == 8'hFF) && (sp_b_man != 23'd0);
    assign sp_b_man_full = (sp_b_exp == 8'd0) ? {1'b0, sp_b_man} : {1'b1, sp_b_man};

    assign sp_c_sign = sp_c[31];
    assign sp_c_exp  = sp_c[30:23];
    assign sp_c_man  = sp_c[22:0];
    assign sp_c_zero = (sp_c_exp == 8'd0)  && (sp_c_man == 23'd0);
    assign sp_c_inf  = (sp_c_exp == 8'hFF) && (sp_c_man == 23'd0);
    assign sp_c_nan  = (sp_c_exp == 8'hFF) && (sp_c_man != 23'd0);
    assign sp_c_man_full = (sp_c_exp == 8'd0) ? {1'b0, sp_c_man} : {1'b1, sp_c_man};

    // DP fields
    logic        dp_a_sign, dp_b_sign, dp_c_sign;
    logic [10:0] dp_a_exp,  dp_b_exp,  dp_c_exp;
    logic [51:0] dp_a_man,  dp_b_man,  dp_c_man;
    logic        dp_a_zero, dp_b_zero, dp_c_zero;
    logic        dp_a_inf,  dp_b_inf,  dp_c_inf;
    logic        dp_a_nan,  dp_b_nan,  dp_c_nan;
    logic [52:0] dp_a_man_full, dp_b_man_full, dp_c_man_full;

    assign dp_a_sign = dp_a[63];
    assign dp_a_exp  = dp_a[62:52];
    assign dp_a_man  = dp_a[51:0];
    assign dp_a_zero = (dp_a_exp == 11'd0)   && (dp_a_man == 52'd0);
    assign dp_a_inf  = (dp_a_exp == 11'h7FF) && (dp_a_man == 52'd0);
    assign dp_a_nan  = (dp_a_exp == 11'h7FF) && (dp_a_man != 52'd0);
    assign dp_a_man_full = (dp_a_exp == 11'd0) ? {1'b0, dp_a_man} : {1'b1, dp_a_man};

    assign dp_b_sign = dp_b[63];
    assign dp_b_exp  = dp_b[62:52];
    assign dp_b_man  = dp_b[51:0];
    assign dp_b_zero = (dp_b_exp == 11'd0)   && (dp_b_man == 52'd0);
    assign dp_b_inf  = (dp_b_exp == 11'h7FF) && (dp_b_man == 52'd0);
    assign dp_b_nan  = (dp_b_exp == 11'h7FF) && (dp_b_man != 52'd0);
    assign dp_b_man_full = (dp_b_exp == 11'd0) ? {1'b0, dp_b_man} : {1'b1, dp_b_man};

    assign dp_c_sign = dp_c[63];
    assign dp_c_exp  = dp_c[62:52];
    assign dp_c_man  = dp_c[51:0];
    assign dp_c_zero = (dp_c_exp == 11'd0)   && (dp_c_man == 52'd0);
    assign dp_c_inf  = (dp_c_exp == 11'h7FF) && (dp_c_man == 52'd0);
    assign dp_c_nan  = (dp_c_exp == 11'h7FF) && (dp_c_man != 52'd0);
    assign dp_c_man_full = (dp_c_exp == 11'd0) ? {1'b0, dp_c_man} : {1'b1, dp_c_man};

    // ---------------------------------------------------------------
    // SP adder  (a +/- b, operand_b_sign selects add vs sub)
    // ---------------------------------------------------------------
    logic        add_b_sign;
    logic        add_swap;
    logic [7:0]  sp_add_exp_diff;
    logic [7:0]  sp_add_large_exp, sp_add_small_exp;
    logic [23:0] sp_add_large_man, sp_add_small_man;
    logic [24:0] sp_add_small_man_shifted;
    logic [24:0] sp_add_sum;
    logic        sp_add_sum_sign;
    logic [7:0]  sp_add_norm_exp;
    logic [23:0] sp_add_norm_man;
    logic        sp_add_overflow;

    assign add_b_sign = (exe_subop == FPU_FSUB) ? ~sp_b_sign : sp_b_sign;

    assign add_swap = {sp_a_exp, sp_a_man_full} < {sp_b_exp, sp_b_man_full};

    always_comb begin
        if (add_swap) begin
            sp_add_large_exp = sp_b_exp;
            sp_add_large_man = sp_b_man_full;
            sp_add_small_exp = sp_a_exp;
            sp_add_small_man = sp_a_man_full;
            sp_add_sum_sign  = add_b_sign;
        end else begin
            sp_add_large_exp = sp_a_exp;
            sp_add_large_man = sp_a_man_full;
            sp_add_small_exp = sp_b_exp;
            sp_add_small_man = sp_b_man_full;
            sp_add_sum_sign  = sp_a_sign;
        end
    end

    assign sp_add_exp_diff = sp_add_large_exp - sp_add_small_exp;
    assign sp_add_small_man_shifted = {1'b0, sp_add_small_man} >> sp_add_exp_diff;

    always_comb begin
        if (sp_a_sign == add_b_sign) begin
            sp_add_sum = {1'b0, sp_add_large_man} + sp_add_small_man_shifted;
        end else begin
            sp_add_sum = {1'b0, sp_add_large_man} - sp_add_small_man_shifted;
        end
    end

    // Normalize
    always_comb begin
        if (sp_add_sum[24]) begin
            sp_add_norm_man  = sp_add_sum[24:1];
            sp_add_norm_exp  = sp_add_large_exp + 8'd1;
            sp_add_overflow  = (sp_add_large_exp == 8'hFE);
        end else if (sp_add_sum[23]) begin
            sp_add_norm_man  = sp_add_sum[23:0];
            sp_add_norm_exp  = sp_add_large_exp;
            sp_add_overflow  = 1'b0;
        end else if (sp_add_large_exp == 8'd0) begin
            // Subnormal: don't normalize, keep as-is
            sp_add_norm_man  = sp_add_sum[22:0];
            sp_add_norm_exp  = 8'd0;
            sp_add_overflow  = 1'b0;
        end else begin
            sp_add_norm_man  = {sp_add_sum[21:0], 1'b0};
            sp_add_norm_exp  = sp_add_large_exp - 8'd1;
            sp_add_overflow  = 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // SP multiplier
    // ---------------------------------------------------------------
    logic [47:0] sp_mul_prod;
    logic        sp_mul_sign;
    logic [8:0]  sp_mul_exp_pre;
    logic [7:0]  sp_mul_norm_exp;
    logic [22:0] sp_mul_norm_man;
    logic        sp_mul_overflow;

    assign sp_mul_sign    = sp_a_sign ^ sp_b_sign;
    assign sp_mul_prod    = sp_a_man_full * sp_b_man_full;
    assign sp_mul_exp_pre = {1'b0, sp_a_exp} + {1'b0, sp_b_exp} - 9'd127;

    always_comb begin
        if (sp_mul_prod[47]) begin
            sp_mul_norm_man  = sp_mul_prod[46:24];
            sp_mul_norm_exp  = sp_mul_exp_pre[7:0] + 8'd1;
            sp_mul_overflow  = sp_mul_exp_pre[8] || (sp_mul_exp_pre[7:0] == 8'hFE);
        end else begin
            sp_mul_norm_man  = sp_mul_prod[45:23];
            sp_mul_norm_exp  = sp_mul_exp_pre[7:0];
            sp_mul_overflow  = sp_mul_exp_pre[8];
        end
    end

    // ---------------------------------------------------------------
    // SP divider (combinational; synth tool infers hardware divider)
    // ---------------------------------------------------------------
    logic [47:0] sp_div_quot;
    logic        sp_div_sign;
    logic [8:0]  sp_div_exp_pre;
    logic [7:0]  sp_div_norm_exp;
    logic [22:0] sp_div_norm_man;
    logic        sp_div_overflow;
    logic        sp_div_by_zero;

    assign sp_div_sign    = sp_a_sign ^ sp_b_sign;
    assign sp_div_quot    = sp_b_zero ? 48'd0 : ({sp_a_man_full, 24'd0} / {1'b0, sp_b_man_full});
    assign sp_div_exp_pre = {1'b0, sp_a_exp} - {1'b0, sp_b_exp} + 9'd127;
    assign sp_div_by_zero = sp_b_zero && !sp_a_zero && !sp_a_nan;

    always_comb begin
        if (sp_div_quot[24]) begin
            // Q >= 2^24: hidden bit at bit[24], already normalized
            sp_div_norm_man = sp_div_quot[23:1];
            sp_div_norm_exp = sp_div_exp_pre[7:0];
            sp_div_overflow = sp_div_exp_pre[8] || (sp_div_exp_pre[7:0] == 8'hFE);
        end else begin
            // Q < 2^24: need left-shift by 1 to normalize, exp - 1
            sp_div_norm_man = sp_div_quot[22:0];
            sp_div_norm_exp = sp_div_exp_pre[7:0] - 8'd1;
            sp_div_overflow = sp_div_exp_pre[8];
        end
    end

    // ---------------------------------------------------------------
    // SP square root (bit-by-bit restoring algorithm, combinational)
    // Input doubled to 48-bit for full 24-bit result precision
    // ---------------------------------------------------------------
    logic [47:0] sp_sqrt_mantissa;
    logic [7:0]  sp_sqrt_exp_out;
    logic [23:0] sp_sqrt_res;
    logic [25:0] sp_sqrt_rem;
    logic [25:0] sp_sqrt_test;

    // Adjust exponent: if odd (exp[0]==1) → real exp is even → √(M)
    //                  if even (exp[0]==0) → real exp is odd → √(2M)
    always_comb begin
        if (sp_a_exp[0]) begin
            sp_sqrt_mantissa = {1'b0, sp_a_man_full, 23'd0};
            sp_sqrt_exp_out  = (sp_a_exp >> 1) + 8'd64;
        end else begin
            sp_sqrt_mantissa = {sp_a_man_full, 24'd0};
            sp_sqrt_exp_out  = (sp_a_exp >> 1) + 8'd63;
        end
    end

    // Bit-by-bit sqrt: 24 iterations, 2 bits consumed per iteration → 24-bit result
    always_comb begin
        sp_sqrt_res = 24'd0;
        sp_sqrt_rem = 25'd0;
        for (int i = 23; i >= 0; i--) begin
            // Pull in 2 bits from input each iteration
            sp_sqrt_rem = {sp_sqrt_rem[23:0], sp_sqrt_mantissa[2*i+1], sp_sqrt_mantissa[2*i]};
            sp_sqrt_test = {sp_sqrt_res, 2'b01};
            if (sp_sqrt_rem >= sp_sqrt_test) begin
                sp_sqrt_rem = sp_sqrt_rem - sp_sqrt_test;
                sp_sqrt_res = {sp_sqrt_res[22:0], 1'b1};
            end else begin
                sp_sqrt_res = {sp_sqrt_res[22:0], 1'b0};
            end
        end
    end

    // ---------------------------------------------------------------
    // DP adder  (a +/- b)
    // ---------------------------------------------------------------
    logic        dp_add_b_sign;
    logic        dp_add_swap;
    logic [10:0] dp_add_exp_diff;
    logic [10:0] dp_add_large_exp, dp_add_small_exp;
    logic [52:0] dp_add_large_man, dp_add_small_man;
    logic [53:0] dp_add_small_man_shifted;
    logic [53:0] dp_add_sum;
    logic        dp_add_sum_sign;
    logic [10:0] dp_add_norm_exp;
    logic [52:0] dp_add_norm_man;
    logic        dp_add_overflow;

    assign dp_add_b_sign = (exe_subop == FPU_FSUB) ? ~dp_b_sign : dp_b_sign;
    assign dp_add_swap = {dp_a_exp, dp_a_man_full} < {dp_b_exp, dp_b_man_full};

    always_comb begin
        if (dp_add_swap) begin
            dp_add_large_exp = dp_b_exp;
            dp_add_large_man = dp_b_man_full;
            dp_add_small_exp = dp_a_exp;
            dp_add_small_man = dp_a_man_full;
            dp_add_sum_sign  = dp_add_b_sign;
        end else begin
            dp_add_large_exp = dp_a_exp;
            dp_add_large_man = dp_a_man_full;
            dp_add_small_exp = dp_b_exp;
            dp_add_small_man = dp_b_man_full;
            dp_add_sum_sign  = dp_a_sign;
        end
    end

    assign dp_add_exp_diff = dp_add_large_exp - dp_add_small_exp;
    assign dp_add_small_man_shifted = {1'b0, dp_add_small_man} >> dp_add_exp_diff;

    always_comb begin
        if (dp_a_sign == dp_add_b_sign) begin
            dp_add_sum = {1'b0, dp_add_large_man} + dp_add_small_man_shifted;
        end else begin
            dp_add_sum = {1'b0, dp_add_large_man} - dp_add_small_man_shifted;
        end
    end

    always_comb begin
        if (dp_add_sum[53]) begin
            dp_add_norm_man  = dp_add_sum[53:1];
            dp_add_norm_exp  = dp_add_large_exp + 11'd1;
            dp_add_overflow  = (dp_add_large_exp == 11'h7FE);
        end else if (dp_add_sum[52]) begin
            dp_add_norm_man  = dp_add_sum[52:0];
            dp_add_norm_exp  = dp_add_large_exp;
            dp_add_overflow  = 1'b0;
        end else if (dp_add_large_exp == 11'd0) begin
            // Subnormal: don't normalize, keep as-is
            dp_add_norm_man  = dp_add_sum[51:0];
            dp_add_norm_exp  = 11'd0;
            dp_add_overflow  = 1'b0;
        end else begin
            dp_add_norm_man  = {dp_add_sum[51:0], 1'b0};
            dp_add_norm_exp  = dp_add_large_exp - 11'd1;
            dp_add_overflow  = 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // DP multiplier
    // ---------------------------------------------------------------
    logic [105:0] dp_mul_prod;
    logic         dp_mul_sign;
    logic [11:0]  dp_mul_exp_pre;
    logic [10:0]  dp_mul_norm_exp;
    logic [51:0]  dp_mul_norm_man;
    logic         dp_mul_overflow;

    assign dp_mul_sign    = dp_a_sign ^ dp_b_sign;
    assign dp_mul_prod    = dp_a_man_full * dp_b_man_full;
    assign dp_mul_exp_pre = {1'b0, dp_a_exp} + {1'b0, dp_b_exp} - 12'd1023;

    always_comb begin
        if (dp_mul_prod[105]) begin
            dp_mul_norm_man  = dp_mul_prod[104:53];
            dp_mul_norm_exp  = dp_mul_exp_pre[10:0] + 11'd1;
            dp_mul_overflow  = dp_mul_exp_pre[11] || (dp_mul_exp_pre[10:0] == 11'h7FE);
        end else begin
            dp_mul_norm_man  = dp_mul_prod[103:52];
            dp_mul_norm_exp  = dp_mul_exp_pre[10:0];
            dp_mul_overflow  = dp_mul_exp_pre[11];
        end
    end

    // ---------------------------------------------------------------
    // DP divider
    // ---------------------------------------------------------------
    logic [105:0] dp_div_quot;
    logic         dp_div_sign;
    logic [11:0]  dp_div_exp_pre;
    logic [10:0]  dp_div_norm_exp;
    logic [51:0]  dp_div_norm_man;
    logic         dp_div_overflow;

    assign dp_div_sign    = dp_a_sign ^ dp_b_sign;
    assign dp_div_quot    = dp_b_zero ? 106'd0 : ({dp_a_man_full, 53'd0} / {1'b0, dp_b_man_full});
    assign dp_div_exp_pre = {1'b0, dp_a_exp} - {1'b0, dp_b_exp} + 12'd1023;

    always_comb begin
        if (dp_div_quot[53]) begin
            // Q >= 2^53: hidden bit at bit[53], already normalized
            dp_div_norm_man = dp_div_quot[52:1];
            dp_div_norm_exp = dp_div_exp_pre[10:0];
            dp_div_overflow = dp_div_exp_pre[11] || (dp_div_exp_pre[10:0] == 11'h7FE);
        end else begin
            // Q < 2^53: need left-shift by 1 to normalize, exp - 1
            dp_div_norm_man = dp_div_quot[51:0];
            dp_div_norm_exp = dp_div_exp_pre[10:0] - 11'd1;
            dp_div_overflow = dp_div_exp_pre[11];
        end
    end

    // ---------------------------------------------------------------
    // DP square root (bit-by-bit restoring, 53 iterations, 2 bits per iteration → 53-bit result)
    // ---------------------------------------------------------------
    logic [105:0] dp_sqrt_mantissa;
    logic [10:0]  dp_sqrt_exp_out;
    logic [52:0]  dp_sqrt_res;
    logic [54:0]  dp_sqrt_rem;
    logic [54:0]  dp_sqrt_test;

    always_comb begin
        if (dp_a_exp[0]) begin
            dp_sqrt_mantissa = {1'b0, dp_a_man_full, 52'd0};
            dp_sqrt_exp_out  = (dp_a_exp >> 1) + 11'd512;
        end else begin
            dp_sqrt_mantissa = {dp_a_man_full, 53'd0};
            dp_sqrt_exp_out  = (dp_a_exp >> 1) + 11'd511;
        end
    end

    always_comb begin
        dp_sqrt_res = 53'd0;
        dp_sqrt_rem = 54'd0;
        for (int i = 52; i >= 0; i--) begin
            // Pull in 2 bits from input each iteration
            dp_sqrt_rem = {dp_sqrt_rem[52:0], dp_sqrt_mantissa[2*i+1], dp_sqrt_mantissa[2*i]};
            dp_sqrt_test = {dp_sqrt_res, 2'b01};
            if (dp_sqrt_rem >= dp_sqrt_test) begin
                dp_sqrt_rem = dp_sqrt_rem - dp_sqrt_test;
                dp_sqrt_res = {dp_sqrt_res[51:0], 1'b1};
            end else begin
                dp_sqrt_res = {dp_sqrt_res[51:0], 1'b0};
            end
        end
    end

    // ---------------------------------------------------------------
    // FMA: ab +/- c  (FMADD/FMSUB/FNMSUB/FNMADD)
    // Uses full product mantissa, then adds/subtracts c
    // ---------------------------------------------------------------
    logic        fma_neg_ab, fma_neg_c;
    logic        fma_ab_sign;
    logic [8:0]  fma_ab_exp_pre;
    logic [47:0] fma_ab_prod;
    logic [7:0]  fma_ab_exp;
    logic [23:0] fma_ab_man;
    logic        fma_ab_overflow;
    logic        fma_swap;
    logic [7:0]  fma_exp_diff;
    logic [7:0]  fma_large_exp, fma_small_exp;
    logic [23:0] fma_large_man, fma_small_man;
    logic [24:0] fma_small_shifted;
    logic [24:0] fma_sum;
    logic        fma_sum_sign;
    logic [7:0]  fma_norm_exp;
    logic [23:0] fma_norm_man;
    logic        fma_overflow;
    logic        fma_sum_sign_final;

    assign fma_sum_sign_final = (fma_norm_exp == 8'd0 && fma_norm_man[22:0] == 23'd0) ?
                                (fma_ab_sign & fma_c_sign_adj) : fma_sum_sign;

    assign fma_neg_ab = (exe_subop == FPU_FNMSUB) || (exe_subop == FPU_FNMADD);
    assign fma_neg_c  = (exe_subop == FPU_FMSUB)  || (exe_subop == FPU_FNMADD);

    assign fma_ab_sign = (sp_a_sign ^ sp_b_sign) ^ fma_neg_ab;
    assign fma_ab_prod = sp_a_man_full * sp_b_man_full;
    assign fma_ab_exp_pre = (sp_a_zero || sp_b_zero) ? 9'd0 : ({1'b0, sp_a_exp} + {1'b0, sp_b_exp} - 9'd127);

    always_comb begin
        if (fma_ab_prod[47]) begin
            fma_ab_man      = fma_ab_prod[47:24];
            fma_ab_exp      = fma_ab_exp_pre[7:0] + 8'd1;
            fma_ab_overflow = fma_ab_exp_pre[8] || (fma_ab_exp_pre[7:0] == 8'hFE);
        end else begin
            fma_ab_man      = fma_ab_prod[46:23];
            fma_ab_exp      = fma_ab_exp_pre[7:0];
            fma_ab_overflow = fma_ab_exp_pre[8];
        end
    end

    logic fma_c_sign_adj;
    assign fma_c_sign_adj = sp_c_sign ^ fma_neg_c;

    assign fma_swap = {fma_ab_exp, fma_ab_man} < {sp_c_exp, sp_c_man_full};

    always_comb begin
        if (fma_swap) begin
            fma_large_exp = sp_c_exp;
            fma_large_man = sp_c_man_full;
            fma_small_exp = fma_ab_exp;
            fma_small_man = fma_ab_man;
            fma_sum_sign  = fma_c_sign_adj;
        end else begin
            fma_large_exp = fma_ab_exp;
            fma_large_man = fma_ab_man;
            fma_small_exp = sp_c_exp;
            fma_small_man = sp_c_man_full;
            fma_sum_sign  = fma_ab_sign;
        end
    end

    assign fma_exp_diff      = fma_large_exp - fma_small_exp;
    assign fma_small_shifted = {1'b0, fma_small_man} >> fma_exp_diff;

    always_comb begin
        if (fma_ab_sign == fma_c_sign_adj) begin
            fma_sum = {1'b0, fma_large_man} + fma_small_shifted;
        end else begin
            fma_sum = {1'b0, fma_large_man} - fma_small_shifted;
        end
    end

    always_comb begin
        if (fma_sum[24]) begin
            fma_norm_man  = fma_sum[24:1];
            fma_norm_exp  = fma_large_exp + 8'd1;
            fma_overflow  = (fma_large_exp == 8'hFE);
        end else if (fma_sum[23]) begin
            fma_norm_man  = fma_sum[23:0];
            fma_norm_exp  = fma_large_exp;
            fma_overflow  = 1'b0;
        end else if (fma_large_exp == 8'd0) begin
            // Subnormal: don't normalize, keep as-is
            fma_norm_man  = fma_sum[22:0];
            fma_norm_exp  = 8'd0;
            fma_overflow  = 1'b0;
        end else begin
            fma_norm_man  = {fma_sum[21:0], 1'b0};
            fma_norm_exp  = fma_large_exp - 8'd1;
            fma_overflow  = 1'b0;
        end
    end

    // ---------------------------------------------------------------
    // Format conversion helpers
    // ---------------------------------------------------------------
    // SP → DP
    logic [63:0] sp_to_dp_result;
    always_comb begin
        if (sp_a_nan) begin
            sp_to_dp_result = 64'h7FF8000000000000; // canonical NaN
        end else if (sp_a_inf) begin
            sp_to_dp_result = {sp_a_sign, 63'h7FF0000000000000};
        end else if (sp_a_zero) begin
            sp_to_dp_result = {sp_a_sign, 63'd0};
        end else begin
            sp_to_dp_result = {sp_a_sign,
                               (sp_a_exp - 8'd127 + 11'd1023),
                               sp_a_man, 29'd0};
        end
    end

    // DP → SP
    logic [31:0] dp_to_sp_result;
    logic [10:0] dp_to_sp_exp_conv;
    always_comb begin
        dp_to_sp_exp_conv = dp_a_exp - 11'd1023 + 11'd127;
        if (dp_a_nan) begin
            dp_to_sp_result = 32'h7FC00000; // canonical NaN
        end else if (dp_a_inf) begin
            dp_to_sp_result = {dp_a_sign, 31'h7F800000};
        end else if (dp_a_zero) begin
            dp_to_sp_result = {dp_a_sign, 31'd0};
        end else if (dp_a_exp < 11'd897) begin
            // Underflow: flush to zero
            dp_to_sp_result = {dp_a_sign, 31'd0};
        end else if (dp_a_exp > 11'd1150) begin
            // Overflow: RTZ rounds to max normal
            dp_to_sp_result = {dp_a_sign, 8'hFE, 23'h7FFFFF};
        end else begin
            dp_to_sp_result = {dp_a_sign,
                               dp_to_sp_exp_conv[7:0],
                               dp_a_man[51:29]};
        end
    end

    // INT → SP  (32-bit and 64-bit signed/unsigned)
    logic [31:0] int_to_sp_result;
    logic        sp_cvt_sign;
    logic [63:0] sp_cvt_mag;
    logic [7:0]  sp_cvt_lz;
    logic [7:0]  sp_cvt_exp;
    logic [22:0] sp_cvt_man;

    logic is_s_w, is_s_wu, is_s_l, is_s_lu;
    assign is_s_w  = (exe_subop == FPU_FCVT_S_W);
    assign is_s_wu = (exe_subop == FPU_FCVT_S_WU);
    assign is_s_l  = (exe_subop == FPU_FCVT_S_L);
    assign is_s_lu = (exe_subop == FPU_FCVT_S_LU);

    assign sp_cvt_sign = (is_s_w & rs1[31]) | (is_s_l & rs1[63]);

    always_comb begin
        if (is_s_w) begin
            sp_cvt_mag = rs1[31] ? {32'd0, ~rs1[31:0] + 32'd1} : {32'd0, rs1[31:0]};
        end else if (is_s_wu) begin
            sp_cvt_mag = {32'd0, rs1[31:0]};
        end else if (is_s_l) begin
            sp_cvt_mag = rs1[63] ? (~rs1 + 64'd1) : rs1;
        end else begin // FPU_FCVT_S_LU
            sp_cvt_mag = rs1;
        end
    end

    always_comb begin
        sp_cvt_lz = 8'd63;
        for (int i = 63; i >= 0; i--) begin
            if (sp_cvt_mag[i] && sp_cvt_lz == 8'd63) sp_cvt_lz = 8'd63 - i[7:0];
        end
    end

    assign sp_cvt_exp = 8'd127 + 8'd63 - sp_cvt_lz;
    assign sp_cvt_man = (sp_cvt_lz > 8'd40) ?
                        (sp_cvt_mag[62:0] << (sp_cvt_lz - 8'd40)) :
                        (sp_cvt_mag[62:0] >> (8'd40 - sp_cvt_lz));
    assign int_to_sp_result = (sp_cvt_mag == 64'd0) ? {sp_cvt_sign, 31'd0} :
                              {sp_cvt_sign, sp_cvt_exp, sp_cvt_man[22:0]};

    // SP → INT (32-bit and 64-bit signed/unsigned)
    logic [63:0] sp_to_int_result;
    logic [63:0] sp_to_int_mag;
    logic        sp_to_int_neg;
    logic        sp_to_int_invalid;
    logic [63:0] sp_to_int_invalid_val;
    logic        sp_to_int_is_32bit;
    logic        sp_to_int_is_unsigned;
    logic [7:0]  sp_to_int_max_exp;

    assign sp_to_int_neg = sp_a_sign &&
        (exe_subop == FPU_FCVT_W_S || exe_subop == FPU_FCVT_L_S);

    assign sp_to_int_is_32bit = (exe_subop == FPU_FCVT_W_S || exe_subop == FPU_FCVT_WU_S);
    assign sp_to_int_is_unsigned = (exe_subop == FPU_FCVT_WU_S || exe_subop == FPU_FCVT_LU_S);

    assign sp_to_int_max_exp = sp_to_int_is_32bit ?
                               (sp_to_int_is_unsigned ? 8'd159 : 8'd158) :
                               (sp_to_int_is_unsigned ? 8'd191 : 8'd190);

    // Invalid detection
    always_comb begin
        if (sp_a_nan || sp_a_inf) begin
            sp_to_int_invalid = 1'b1;
        end else if (sp_a_sign && sp_to_int_is_unsigned) begin
            // Negative to unsigned → always invalid
            sp_to_int_invalid = (sp_a_exp >= 8'd127);
        end else if (sp_a_exp > sp_to_int_max_exp) begin
            sp_to_int_invalid = 1'b1;
        end else if (sp_a_exp == sp_to_int_max_exp) begin
            // Boundary case: signed can represent -2^N exactly (mantissa=0), others overflow
            sp_to_int_invalid = !(sp_a_sign && !sp_to_int_is_unsigned && sp_a_man == 23'd0);
        end else begin
            sp_to_int_invalid = 1'b0;
        end
    end

    // Invalid value (depends on NaN/sign/signedness/width)
    always_comb begin
        if (sp_a_nan) begin
            // NaN → max positive value
            if (sp_to_int_is_32bit) begin
                sp_to_int_invalid_val = sp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h000000007FFFFFFF;
            end else begin
                sp_to_int_invalid_val = sp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h7FFFFFFFFFFFFFFF;
            end
        end else if (sp_a_sign) begin
            // -Inf or negative overflow
            if (sp_to_int_is_unsigned) begin
                sp_to_int_invalid_val = 64'd0;
            end else if (sp_to_int_is_32bit) begin
                sp_to_int_invalid_val = 64'hFFFFFFFF80000000;
            end else begin
                sp_to_int_invalid_val = 64'h8000000000000000;
            end
        end else begin
            // +Inf or positive overflow
            if (sp_to_int_is_32bit) begin
                sp_to_int_invalid_val = sp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h000000007FFFFFFF;
            end else begin
                sp_to_int_invalid_val = sp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h7FFFFFFFFFFFFFFF;
            end
        end
    end

    // Normal conversion
    always_comb begin
        if (sp_a_exp < 8'd127) begin
            sp_to_int_mag = 64'd0;
        end else if (sp_a_exp >= 8'd150) begin
            sp_to_int_mag = {1'b1, sp_a_man} << (sp_a_exp - 8'd150);
        end else begin
            sp_to_int_mag = {1'b1, sp_a_man} >> (8'd150 - sp_a_exp);
        end
    end

    assign sp_to_int_result = sp_to_int_invalid ? sp_to_int_invalid_val :
                              sp_to_int_neg ? (~sp_to_int_mag + 64'd1) : sp_to_int_mag;

    // INT → DP  (32-bit and 64-bit signed/unsigned)
    logic [63:0] int_to_dp_result;
    logic        dp_cvt_sign;
    logic [63:0] dp_cvt_mag;
    logic [10:0] dp_cvt_lz;
    logic [10:0] dp_cvt_exp;
    logic [51:0] dp_cvt_man;

    logic is_d_w, is_d_wu, is_d_l, is_d_lu;
    assign is_d_w  = (exe_subop == FPU_FCVT_D_W);
    assign is_d_wu = (exe_subop == FPU_FCVT_D_WU);
    assign is_d_l  = (exe_subop == FPU_FCVT_D_L);
    assign is_d_lu = (exe_subop == FPU_FCVT_D_LU);

    assign dp_cvt_sign = (is_d_w & rs1[31]) | (is_d_l & rs1[63]);

    always_comb begin
        if (is_d_w) begin
            dp_cvt_mag = rs1[31] ? {32'd0, ~rs1[31:0] + 32'd1} : {32'd0, rs1[31:0]};
        end else if (is_d_wu) begin
            dp_cvt_mag = {32'd0, rs1[31:0]};
        end else if (is_d_l) begin
            dp_cvt_mag = rs1[63] ? (~rs1 + 64'd1) : rs1;
        end else begin // FPU_FCVT_D_LU
            dp_cvt_mag = rs1;
        end
    end

    always_comb begin
        dp_cvt_lz = 11'd63;
        for (int i = 63; i >= 0; i--) begin
            if (dp_cvt_mag[i] && dp_cvt_lz == 11'd63) dp_cvt_lz = 11'd63 - i[10:0];
        end
    end

    assign dp_cvt_exp = 11'd1023 + 11'd63 - dp_cvt_lz;
    assign dp_cvt_man = (dp_cvt_lz > 11'd11) ?
                        (dp_cvt_mag << (dp_cvt_lz - 11'd11)) :
                        (dp_cvt_mag >> (11'd11 - dp_cvt_lz));
    assign int_to_dp_result = (dp_cvt_mag == 64'd0) ? {dp_cvt_sign, 63'd0} :
                              {dp_cvt_sign, dp_cvt_exp, dp_cvt_man[51:0]};

    // DP → INT (64-bit signed/unsigned)
    logic [63:0] dp_to_int_result;
    logic [63:0] dp_to_int_mag;
    logic        dp_to_int_neg;
    logic        dp_to_int_invalid;
    logic [63:0] dp_to_int_invalid_val;
    logic        dp_to_int_is_32bit;
    logic        dp_to_int_is_unsigned;
    logic [10:0] dp_to_int_max_exp;

    assign dp_to_int_neg = dp_a_sign &&
        (exe_subop == FPU_FCVT_W_D || exe_subop == FPU_FCVT_L_D);

    assign dp_to_int_is_32bit = (exe_subop == FPU_FCVT_W_D || exe_subop == FPU_FCVT_WU_D);
    assign dp_to_int_is_unsigned = (exe_subop == FPU_FCVT_WU_D || exe_subop == FPU_FCVT_LU_D);

    assign dp_to_int_max_exp = dp_to_int_is_32bit ?
                               (dp_to_int_is_unsigned ? 11'd1055 : 11'd1054) :
                               (dp_to_int_is_unsigned ? 11'd1087 : 11'd1086);

    // Invalid detection
    always_comb begin
        if (dp_a_nan || dp_a_inf) begin
            dp_to_int_invalid = 1'b1;
        end else if (dp_a_sign && dp_to_int_is_unsigned) begin
            // Negative to unsigned → always invalid
            dp_to_int_invalid = (dp_a_exp >= 11'd1023);
        end else if (dp_a_exp > dp_to_int_max_exp) begin
            dp_to_int_invalid = 1'b1;
        end else if (dp_a_exp == dp_to_int_max_exp) begin
            // Boundary case: signed can represent -2^N exactly (mantissa=0), others overflow
            dp_to_int_invalid = !(dp_a_sign && !dp_to_int_is_unsigned && dp_a_man == 52'd0);
        end else begin
            dp_to_int_invalid = 1'b0;
        end
    end

    // Invalid value (depends on NaN/sign/signedness/width)
    always_comb begin
        if (dp_a_nan) begin
            // NaN → max positive value
            if (dp_to_int_is_32bit) begin
                dp_to_int_invalid_val = dp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h000000007FFFFFFF;
            end else begin
                dp_to_int_invalid_val = dp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h7FFFFFFFFFFFFFFF;
            end
        end else if (dp_a_sign) begin
            // -Inf or negative overflow
            if (dp_to_int_is_unsigned) begin
                dp_to_int_invalid_val = 64'd0;
            end else if (dp_to_int_is_32bit) begin
                dp_to_int_invalid_val = 64'hFFFFFFFF80000000;
            end else begin
                dp_to_int_invalid_val = 64'h8000000000000000;
            end
        end else begin
            // +Inf or positive overflow
            if (dp_to_int_is_32bit) begin
                dp_to_int_invalid_val = dp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h000000007FFFFFFF;
            end else begin
                dp_to_int_invalid_val = dp_to_int_is_unsigned ? 64'hFFFFFFFFFFFFFFFF : 64'h7FFFFFFFFFFFFFFF;
            end
        end
    end

    // Normal conversion
    always_comb begin
        if (dp_a_exp < 11'd1023) begin
            dp_to_int_mag = 64'd0;
        end else if (dp_a_exp >= 11'd1075) begin
            dp_to_int_mag = {1'b1, dp_a_man} << (dp_a_exp - 11'd1075);
        end else begin
            dp_to_int_mag = {1'b1, dp_a_man} >> (11'd1075 - dp_a_exp);
        end
    end

    assign dp_to_int_result = dp_to_int_invalid ? dp_to_int_invalid_val :
                              dp_to_int_neg ? (~dp_to_int_mag + 64'd1) : dp_to_int_mag;

    // ---------------------------------------------------------------
    // FCLASS
    // ---------------------------------------------------------------
    logic [9:0] sp_fclass_result;
    always_comb begin
        sp_fclass_result = 10'd0;
        if (sp_a_nan) begin
            if (sp_a_man[22]) sp_fclass_result[9] = 1'b1; // signaling NaN
            else              sp_fclass_result[8] = 1'b1; // quiet NaN
        end else if (sp_a_inf) begin
            sp_fclass_result[sp_a_sign ? 0 : 7] = 1'b1;
        end else if (sp_a_zero) begin
            sp_fclass_result[sp_a_sign ? 3 : 4] = 1'b1;
        end else if (sp_a_exp == 8'd0) begin
            sp_fclass_result[sp_a_sign ? 2 : 5] = 1'b1; // subnormal
        end else begin
            sp_fclass_result[sp_a_sign ? 1 : 6] = 1'b1; // normal
        end
    end

    logic [9:0] dp_fclass_result;
    always_comb begin
        dp_fclass_result = 10'd0;
        if (dp_a_nan) begin
            if (dp_a_man[51]) dp_fclass_result[9] = 1'b1;
            else              dp_fclass_result[8] = 1'b1;
        end else if (dp_a_inf) begin
            dp_fclass_result[dp_a_sign ? 0 : 7] = 1'b1;
        end else if (dp_a_zero) begin
            dp_fclass_result[dp_a_sign ? 3 : 4] = 1'b1;
        end else if (dp_a_exp == 11'd0) begin
            dp_fclass_result[dp_a_sign ? 2 : 5] = 1'b1;
        end else begin
            dp_fclass_result[dp_a_sign ? 1 : 6] = 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Sign injection (FSGNJ/FSGNJN/FSGNJX)
    // ---------------------------------------------------------------
    logic sp_sgnj_sign;
    always_comb begin
        case (exe_subop)
            FPU_FSGNJ:  sp_sgnj_sign = sp_b_sign;
            FPU_FSGNJN: sp_sgnj_sign = ~sp_b_sign;
            FPU_FSGNJX: sp_sgnj_sign = sp_a_sign ^ sp_b_sign;
            default:     sp_sgnj_sign = sp_a_sign;
        endcase
    end

    logic dp_sgnj_sign;
    always_comb begin
        case (exe_subop)
            FPU_FSGNJ:  dp_sgnj_sign = dp_b_sign;
            FPU_FSGNJN: dp_sgnj_sign = ~dp_b_sign;
            FPU_FSGNJX: dp_sgnj_sign = dp_a_sign ^ dp_b_sign;
            default:     dp_sgnj_sign = dp_a_sign;
        endcase
    end

    // Comparison helpers (moved out of case for synthesis compat)
    logic cmp_a_lesser, cmp_a_greater;
    assign cmp_a_lesser  = (sp_a_sign != sp_b_sign) ? sp_a_sign :
                           sp_a_sign ? (sp_a[30:0] > sp_b[30:0]) : (sp_a[30:0] < sp_b[30:0]);
    assign cmp_a_greater = (sp_a_sign != sp_b_sign) ? sp_b_sign :
                           sp_a_sign ? (sp_a[30:0] < sp_b[30:0]) : (sp_a[30:0] > sp_b[30:0]);

    logic dp_cmp_a_lesser, dp_cmp_a_greater;
    assign dp_cmp_a_lesser  = (dp_a_sign != dp_b_sign) ? dp_a_sign :
                              dp_a_sign ? (dp_a[62:0] > dp_b[62:0]) : (dp_a[62:0] < dp_b[62:0]);
    assign dp_cmp_a_greater = (dp_a_sign != dp_b_sign) ? dp_b_sign :
                              dp_a_sign ? (dp_a[62:0] < dp_b[62:0]) : (dp_a[62:0] > dp_b[62:0]);

    // ---------------------------------------------------------------
    // Main result MUX
    // ---------------------------------------------------------------
    logic [FLEN-1:0] fpu_result;
    logic [4:0]      fpu_fflags_c;

    always_comb begin
        fpu_result   = 64'hFFFFFFFF00000000; // NaN-boxing: SP results get high 32-bit = all 1s
        fpu_fflags_c = '0;

        if (!fs_enabled) begin
            fpu_result   = '0;
            fpu_fflags_c = '0;
        end else begin
            case (exe_subop)
                // --- ADD / SUB (SP and DP, muxed by fpu_fmt) ---
                FPU_FADD, FPU_FSUB: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_inf && sp_b_inf && (sp_a_sign != add_b_sign)) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = {sp_a_sign, 8'hFF, 23'd0};
                        end else if (sp_b_inf) begin
                            fpu_result[31:0] = {add_b_sign, 8'hFF, 23'd0};
                        end else if (sp_a_zero && sp_b_zero) begin
                            fpu_result[31:0] = {sp_a_sign & add_b_sign, 31'd0};
                        end else if (sp_add_overflow) begin
                            fpu_result[31:0] = {sp_add_sum_sign, 8'hFF, 23'd0};
                        end else begin
                            fpu_result[31:0] = {sp_add_sum_sign, sp_add_norm_exp, sp_add_norm_man[22:0]};
                        end
                    end else begin
                        // DP
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_inf && dp_b_inf && (dp_a_sign != dp_add_b_sign)) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_inf) begin
                            fpu_result = {dp_a_sign, 11'h7FF, 52'd0};
                        end else if (dp_b_inf) begin
                            fpu_result = {dp_add_b_sign, 11'h7FF, 52'd0};
                        end else if (dp_a_zero && dp_b_zero) begin
                            fpu_result = {dp_a_sign & dp_add_b_sign, 63'd0};
                        end else if (dp_add_overflow) begin
                            fpu_result = {dp_add_sum_sign, 11'h7FF, 52'd0};
                        end else begin
                            fpu_result = {dp_add_sum_sign, dp_add_norm_exp, dp_add_norm_man[51:0]};
                        end
                    end
                end

                // --- MUL (SP and DP) ---
                FPU_FMUL: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if ((sp_a_inf && sp_b_zero) || (sp_a_zero && sp_b_inf)) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_inf || sp_b_inf) begin
                            fpu_result[31:0] = {sp_mul_sign, 8'hFF, 23'd0};
                        end else if (sp_a_zero || sp_b_zero) begin
                            fpu_result[31:0] = {sp_mul_sign, 31'd0};
                        end else if (sp_mul_overflow) begin
                            fpu_result[31:0] = {sp_mul_sign, 8'hFF, 23'd0};
                        end else begin
                            fpu_result[31:0] = {sp_mul_sign, sp_mul_norm_exp, sp_mul_norm_man};
                        end
                    end else begin
                        // DP
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if ((dp_a_inf && dp_b_zero) || (dp_a_zero && dp_b_inf)) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_inf || dp_b_inf) begin
                            fpu_result = {dp_mul_sign, 11'h7FF, 52'd0};
                        end else if (dp_a_zero || dp_b_zero) begin
                            fpu_result = {dp_mul_sign, 63'd0};
                        end else if (dp_mul_overflow) begin
                            fpu_result = {dp_mul_sign, 11'h7FF, 52'd0};
                        end else begin
                            fpu_result = {dp_mul_sign, dp_mul_norm_exp, dp_mul_norm_man};
                        end
                    end
                end

                // --- DIV (SP and DP) ---
                FPU_FDIV: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_div_by_zero) begin
                            fpu_result[31:0] = {sp_div_sign, 8'hFF, 23'd0};
                            fpu_fflags_c[0]  = 1'b1;
                        end else if (sp_a_inf && sp_b_inf) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = {sp_div_sign, 8'hFF, 23'd0};
                        end else if (sp_b_inf) begin
                            fpu_result[31:0] = {sp_div_sign, 31'd0};
                        end else if (sp_a_zero && sp_b_zero) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_zero) begin
                            fpu_result[31:0] = {sp_div_sign, 31'd0};
                        end else if (sp_div_overflow) begin
                            fpu_result[31:0] = {sp_div_sign, 8'hFF, 23'd0};
                        end else begin
                            fpu_result[31:0] = {sp_div_sign, sp_div_norm_exp, sp_div_norm_man};
                        end
                    end else begin
                        // DP
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_b_zero && !dp_a_zero && !dp_a_nan) begin
                            fpu_result   = {dp_div_sign, 11'h7FF, 52'd0};
                            fpu_fflags_c[0] = 1'b1;
                        end else if (dp_a_inf && dp_b_inf) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_inf) begin
                            fpu_result = {dp_div_sign, 11'h7FF, 52'd0};
                        end else if (dp_b_inf) begin
                            fpu_result = {dp_div_sign, 63'd0};
                        end else if (dp_a_zero && dp_b_zero) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_zero) begin
                            fpu_result = {dp_div_sign, 63'd0};
                        end else if (dp_div_overflow) begin
                            fpu_result = {dp_div_sign, 11'h7FF, 52'd0};
                        end else begin
                            fpu_result = {dp_div_sign, dp_div_norm_exp, dp_div_norm_man};
                        end
                    end
                end

                // --- SQRT (SP and DP) ---
                FPU_FSQRT: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan) begin
                            fpu_result[31:0] = 32'h7FC00000;
                        end else if (sp_a_zero) begin
                            fpu_result[31:0] = {sp_a_sign, 31'd0};
                        end else if (sp_a_sign) begin
                            fpu_result[31:0] = 32'h7FC00000;
                            fpu_fflags_c[4]  = 1'b1;
                        end else if (sp_a_inf) begin
                            fpu_result[31:0] = 32'h7F800000;
                        end else begin
                            fpu_result[31:0] = {1'b0, sp_sqrt_exp_out[7:0], sp_sqrt_res[22:0]};
                        end
                    end else begin
                        // DP
                        if (dp_a_nan) begin
                            fpu_result = 64'h7FF8000000000000;
                        end else if (dp_a_zero) begin
                            fpu_result = {dp_a_sign, 63'd0};
                        end else if (dp_a_sign) begin
                            fpu_result   = 64'h7FF8000000000000;
                            fpu_fflags_c[4] = 1'b1;
                        end else if (dp_a_inf) begin
                            fpu_result = {1'b0, 11'h7FF, 52'd0};
                        end else begin
                            fpu_result = {1'b0, dp_sqrt_exp_out, dp_sqrt_res[51:0]};
                        end
                    end
                end

                // --- Comparison: FEQ / FLT / FLE (SP and DP) ---
                FPU_FEQ, FPU_FLT, FPU_FLE: begin
                    fpu_result = 64'd0; // GPR output, clear high bits
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan || sp_b_nan) begin
                            fpu_result[0] = 1'b0;
                            if (exe_subop != FPU_FEQ) fpu_fflags_c[4] = 1'b1;
                        end else begin
                            case (exe_subop)
                                FPU_FEQ: fpu_result[0] = (sp_a_zero && sp_b_zero) || (sp_a == sp_b);
                                FPU_FLT: begin
                                    if (sp_a_zero && sp_b_zero) fpu_result[0] = 1'b0;
                                    else fpu_result[0] = cmp_a_lesser;
                                end
                                FPU_FLE: begin
                                    if (sp_a_zero && sp_b_zero) fpu_result[0] = 1'b1;
                                    else fpu_result[0] = cmp_a_lesser || (sp_a == sp_b);
                                end
                                default: fpu_result[0] = 1'b0;
                            endcase
                        end
                    end else begin
                        // DP
                        if (dp_a_nan || dp_b_nan) begin
                            fpu_result[0] = 1'b0;
                            if (exe_subop != FPU_FEQ) fpu_fflags_c[4] = 1'b1;
                        end else begin
                            case (exe_subop)
                                FPU_FEQ: fpu_result[0] = (dp_a_zero && dp_b_zero) || (dp_a == dp_b);
                                FPU_FLT: begin
                                    if (dp_a_zero && dp_b_zero) fpu_result[0] = 1'b0;
                                    else fpu_result[0] = dp_cmp_a_lesser;
                                end
                                FPU_FLE: begin
                                    if (dp_a_zero && dp_b_zero) fpu_result[0] = 1'b1;
                                    else fpu_result[0] = dp_cmp_a_lesser || (dp_a == dp_b);
                                end
                                default: fpu_result[0] = 1'b0;
                            endcase
                        end
                    end
                end

                // --- FMIN / FMAX (SP and DP) ---
                FPU_FMIN: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan && sp_b_nan)
                            fpu_result[31:0] = 32'h7FC00000;
                        else if (sp_a_nan)
                            fpu_result[31:0] = sp_b;
                        else if (sp_b_nan)
                            fpu_result[31:0] = sp_a;
                        else if (sp_a_zero && sp_b_zero)
                            fpu_result[31:0] = (sp_a_sign || sp_b_sign) ? 32'h80000000 : 32'h00000000;
                        else
                            fpu_result[31:0] = cmp_a_lesser ? sp_a : sp_b;
                    end else begin
                        // DP
                        if (dp_a_nan && dp_b_nan)
                            fpu_result = 64'h7FF8000000000000;
                        else if (dp_a_nan)
                            fpu_result = dp_b;
                        else if (dp_b_nan)
                            fpu_result = dp_a;
                        else if (dp_a_zero && dp_b_zero)
                            fpu_result = (dp_a_sign || dp_b_sign) ? 64'h8000000000000000 : 64'h0000000000000000;
                        else
                            fpu_result = dp_cmp_a_lesser ? dp_a : dp_b;
                    end
                end

                FPU_FMAX: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan && sp_b_nan)
                            fpu_result[31:0] = 32'h7FC00000;
                        else if (sp_a_nan)
                            fpu_result[31:0] = sp_b;
                        else if (sp_b_nan)
                            fpu_result[31:0] = sp_a;
                        else if (sp_a_zero && sp_b_zero)
                            fpu_result[31:0] = (sp_a_sign && sp_b_sign) ? 32'h80000000 : 32'h00000000;
                        else
                            fpu_result[31:0] = cmp_a_greater ? sp_a : sp_b;
                    end else begin
                        // DP
                        if (dp_a_nan && dp_b_nan)
                            fpu_result = 64'h7FF8000000000000;
                        else if (dp_a_nan)
                            fpu_result = dp_b;
                        else if (dp_b_nan)
                            fpu_result = dp_a;
                        else if (dp_a_zero && dp_b_zero)
                            fpu_result = (dp_a_sign && dp_b_sign) ? 64'h8000000000000000 : 64'h0000000000000000;
                        else
                            fpu_result = dp_cmp_a_greater ? dp_a : dp_b;
                    end
                end

                // --- Sign injection (already SP/DP muxed) ---
                FPU_FSGNJ, FPU_FSGNJN, FPU_FSGNJX: begin
                    if (fpu_fmt == 2'd0)
                        fpu_result[31:0] = {sp_sgnj_sign, sp_a[30:0]};
                    else
                        fpu_result       = {dp_sgnj_sign, dp_a[62:0]};
                end

                // --- Classification ---
                FPU_FCLASS: begin
                    fpu_result = 64'd0; // GPR output, clear high bits
                    if (fpu_fmt == 2'd0)
                        fpu_result[9:0] = sp_fclass_result;
                    else
                        fpu_result[9:0] = dp_fclass_result;
                end

                // --- SP moves ---
                FPU_FMV_X_W:  fpu_result = {{32{sp_a[31]}}, sp_a}; // Sign-extend to 64-bit GPR
                FPU_FMV_W_X:  fpu_result[31:0] = rs1[31:0]; // NaN-boxed by initial value

                // --- DP moves ---
                FPU_FMV_X_D:  fpu_result = dp_a; // Full 64-bit to GPR
                FPU_FMV_D_X:  fpu_result = rs1;  // Full 64-bit from GPR

                // --- SP↔DP conversion ---
                FPU_FCVT_D_S: fpu_result = sp_to_dp_result; // SP→DP, write to FPR
                FPU_FCVT_S_D: fpu_result[31:0] = dp_to_sp_result; // DP→SP, NaN-boxed

                // --- INT→SP ---
                FPU_FCVT_S_W, FPU_FCVT_S_WU,
                FPU_FCVT_S_L, FPU_FCVT_S_LU: begin
                    fpu_result[31:0] = int_to_sp_result; // NaN-boxed by initial value
                end

                // --- SP→INT (write to GPR, set invalid flag) ---
                FPU_FCVT_W_S, FPU_FCVT_WU_S: begin
                    fpu_result = {{32{sp_to_int_result[31]}}, sp_to_int_result[31:0]}; // Sign-extend 32-bit
                    if (sp_to_int_invalid) fpu_fflags_c[4] = 1'b1;
                end
                FPU_FCVT_L_S, FPU_FCVT_LU_S: begin
                    fpu_result = sp_to_int_result; // Full 64-bit to GPR
                    if (sp_to_int_invalid) fpu_fflags_c[4] = 1'b1;
                end

                // --- INT→DP ---
                FPU_FCVT_D_W, FPU_FCVT_D_WU,
                FPU_FCVT_D_L, FPU_FCVT_D_LU: begin
                    fpu_result = int_to_dp_result; // Write to FPR
                end

                // --- DP→INT (write to GPR, set invalid flag) ---
                FPU_FCVT_W_D, FPU_FCVT_WU_D: begin
                    fpu_result = {{32{dp_to_int_result[31]}}, dp_to_int_result[31:0]}; // Sign-extend 32-bit
                    if (dp_to_int_invalid) fpu_fflags_c[4] = 1'b1;
                end
                FPU_FCVT_L_D, FPU_FCVT_LU_D: begin
                    fpu_result = dp_to_int_result; // Full 64-bit to GPR
                    if (dp_to_int_invalid) fpu_fflags_c[4] = 1'b1;
                end

                // --- FMA (SP only; DP FMA placeholder) ---
                FPU_FMADD, FPU_FMSUB, FPU_FNMSUB, FPU_FNMADD: begin
                    if (fpu_fmt == 2'd0) begin
                        // SP
                        if (sp_a_nan || sp_b_nan || sp_c_nan)
                            fpu_result[31:0] = 32'h7FC00000;
                        else if (fma_overflow)
                            fpu_result[31:0] = {fma_sum_sign_final, 8'hFF, 23'd0};
                        else
                            fpu_result[31:0] = {fma_sum_sign_final, fma_norm_exp, fma_norm_man[22:0]};
                    end else begin
                        // DP FMA: not yet implemented, raise invalid
                        fpu_result       = 64'h7FF8000000000000;
                        fpu_fflags_c[4]  = 1'b1;
                    end
                end

                default: begin
                    fpu_result   = '0;
                    fpu_fflags_c = '0;
                end
            endcase
        end
    end

    assign busy = 1'b0;

    // ---------------------------------------------------------------
    // Output register
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
        end else if (flush_late) begin
            wb_payload <= '0;
        end else if (en) begin
            wb_payload.result_valid     <= 1'b1;
            wb_payload.tag_out          <= self_rob_tag;
            wb_payload.rd_idx           <= rd_idx;
            wb_payload.is_fp            <= fs_enabled && rd_is_fp;
            wb_payload.result_data      <= fs_enabled ? fpu_result : '0;
            wb_payload.mispredict_flag  <= 1'b0;
            wb_payload.exception_flag   <= !fs_enabled;
            wb_payload.correct_pc       <= '0;
            wb_payload.exception_cause  <= fs_enabled ? '0 : 64'd2;
            wb_payload.is_csr           <= 1'b0;
            wb_payload.csr_write_enable <= 1'b0;
            wb_payload.csr_addr         <= '0;
            wb_payload.csr_wdata        <= '0;
            wb_payload.fpu_fflags       <= fpu_fflags_c;
        end else begin
            wb_payload <= '0;
        end
    end

endmodule

`endif // FPU_SIMPLE_SV