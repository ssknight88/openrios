`ifndef EXE_SUBOP_PKG_SV
`define EXE_SUBOP_PKG_SV

package exe_subop_pkg;

    // Backend-visible exe_subop is group-local.
    // Shared integer ALU subops may be steered to either Group 0 or Group 1.
    // Group-private subops are interpreted only inside their owning group.
    localparam int BACKEND_EXE_SUBOP_W = 6;
    typedef logic [BACKEND_EXE_SUBOP_W-1:0] backend_exe_subop_t;

    typedef enum logic [3:0] {
        FENCE              = 4'h0,
        FENCEI             = 4'h1,
        SFENCE_ASID        = 4'h2,
        SFENCE_VPN         = 4'h3,
        SFENCE_ASID_VPN    = 4'h4,
        SFENCE_ALL         = 4'h5,
        HFENCEV_ASID       = 4'h6,
        HFENCEV_VPN        = 4'h7,
        HFENCEV_ASID_VPN   = 4'h8,
        HFENCEV_ALL        = 4'h9,
        HFENCEGV_VMID      = 4'hA,
        HFENCEGV_VPN       = 4'hB,
        HFENCEGV_VMID_VPN  = 4'hC,
        HFENCEGV_ALL       = 4'hD
    } fence_type_e;

    // Shared ALU sub-op space.
    // Used by Group 0 ALU0 and Group 1 ALU1.
    typedef enum logic [5:0] {
        ALU_ADDI   = 6'd0,
        ALU_SLTI   = 6'd1,
        ALU_SLTIU  = 6'd2,
        ALU_ANDI   = 6'd3,
        ALU_ORI    = 6'd4,
        ALU_XORI   = 6'd5,
        ALU_SLLI   = 6'd6,
        ALU_SRLI   = 6'd7,
        ALU_SRAI   = 6'd8,
        ALU_LUI    = 6'd9,
        ALU_AUIPC  = 6'd10,

        ALU_ADD    = 6'd11,
        ALU_SUB    = 6'd12,
        ALU_SLTU   = 6'd13,
        ALU_AND    = 6'd14,
        ALU_OR     = 6'd15,
        ALU_XOR    = 6'd16,
        ALU_SLL    = 6'd17,
        ALU_SRL    = 6'd18,
        ALU_SLT    = 6'd19,
        ALU_SRA    = 6'd20,
        ALU_NOP    = 6'd21,

        ALU_ADDIW  = 6'd22,
        ALU_SLLIW  = 6'd23,
        ALU_SRLIW  = 6'd24,
        ALU_SRAIW  = 6'd25,
        ALU_ADDW   = 6'd26,
        ALU_SLLW   = 6'd27,
        ALU_SRLW   = 6'd28,
        ALU_SUBW   = 6'd29,
        ALU_SRAW   = 6'd30,

        ALU_CNEZ   = 6'd31,
        ALU_CEQZ   = 6'd32,
        ALU_ECALL  = 6'd59,
        ALU_MRET   = 6'd60,
        ALU_ILLEGAL = 6'd63
    } alu_subop_e;

    // Group 0 only: values 33..57
    typedef enum logic [5:0] {
        BRU_JAL    = 6'd33,
        BRU_JALR   = 6'd34,
        BRU_BEQ    = 6'd35,
        BRU_BNE    = 6'd36,
        BRU_BLT    = 6'd37,
        BRU_BLTU   = 6'd38,
        BRU_BGE    = 6'd39,
        BRU_BGEU   = 6'd40
    } g0_bru_subop_e;

    typedef enum logic [5:0] {
        DIV_DIV    = 6'd41,
        DIV_DIVU   = 6'd42,
        DIV_REM    = 6'd43,
        DIV_REMU   = 6'd44,
        DIV_DIVW   = 6'd45,
        DIV_DIVUW  = 6'd46,
        DIV_REMW   = 6'd47,
        DIV_REMUW  = 6'd48,
        DIV_DIV_EXC = 6'd58
    } g0_div_subop_e;

    typedef enum logic [5:0] {
        CSR_CSRRW    = 6'd49,
        CSR_CSRRS    = 6'd50,
        CSR_CSRRC    = 6'd51,
        CSR_CSRRWI   = 6'd52,
        CSR_CSRRSI   = 6'd53,
        CSR_CSRRCI   = 6'd54,
        CSR_VSETVLI  = 6'd55,
        CSR_VSETIVLI = 6'd56,
        CSR_VSETVL   = 6'd57
    } g0_csr_subop_e;

    // Group 1 only: ALU uses shared ALU values, MUL occupies 33..37.
    typedef enum logic [5:0] {
        MUL_MUL      = 6'd33,
        MUL_MULH     = 6'd34,
        MUL_MULHU    = 6'd35,
        MUL_MULHSU   = 6'd36,
        MUL_MULW     = 6'd37
    } g1_mul_subop_e;

    // Group 2 only: FPU occupies 0..39.
    typedef enum logic [5:0] {
        FPU_FADD      = 6'd0,
        FPU_FSUB      = 6'd1,
        FPU_FMUL      = 6'd2,
        FPU_FDIV      = 6'd3,
        FPU_FSQRT     = 6'd4,
        FPU_FMIN      = 6'd5,
        FPU_FMAX      = 6'd6,
        FPU_FSGNJ     = 6'd7,
        FPU_FSGNJN    = 6'd8,
        FPU_FSGNJX    = 6'd9,
        FPU_FEQ       = 6'd10,
        FPU_FLT       = 6'd11,
        FPU_FLE       = 6'd12,
        FPU_FCLASS    = 6'd13,
        FPU_FMV_X_W   = 6'd14,
        FPU_FMV_W_X   = 6'd15,
        FPU_FCVT_W_S  = 6'd16,
        FPU_FCVT_WU_S = 6'd17,
        FPU_FCVT_L_S  = 6'd18,
        FPU_FCVT_LU_S = 6'd19,
        FPU_FCVT_S_W  = 6'd20,
        FPU_FCVT_S_WU = 6'd21,
        FPU_FCVT_S_L  = 6'd22,
        FPU_FCVT_S_LU = 6'd23,
        FPU_FCVT_D_S  = 6'd24,
        FPU_FCVT_S_D  = 6'd25,
        FPU_FCVT_W_D  = 6'd26,
        FPU_FCVT_WU_D = 6'd27,
        FPU_FCVT_L_D  = 6'd28,
        FPU_FCVT_LU_D = 6'd29,
        FPU_FCVT_D_W  = 6'd30,
        FPU_FCVT_D_WU = 6'd31,
        FPU_FCVT_D_L  = 6'd32,
        FPU_FCVT_D_LU = 6'd33,
        FPU_FMADD     = 6'd34,
        FPU_FMSUB     = 6'd35,
        FPU_FNMSUB    = 6'd36,
        FPU_FNMADD    = 6'd37,
        FPU_FMV_X_D   = 6'd38,
        FPU_FMV_D_X   = 6'd39
    } g2_fpu_subop_e;

    // Group 3 only: current backend only needs load/store distinction.
    localparam backend_exe_subop_t LSU_LOAD  = 6'd0;
    localparam backend_exe_subop_t LSU_STORE = 6'd1;

    function automatic logic is_g0_alu0(backend_exe_subop_t s);
        return s inside {
            ALU_ADDI, ALU_SLTI, ALU_SLTIU, ALU_ANDI, ALU_ORI, ALU_XORI,
            ALU_SLLI, ALU_SRLI, ALU_SRAI, ALU_LUI, ALU_AUIPC,
            ALU_ADD, ALU_SUB, ALU_SLTU, ALU_AND, ALU_OR, ALU_XOR,
            ALU_SLL, ALU_SRL, ALU_SLT, ALU_SRA, ALU_NOP,
            ALU_ADDIW, ALU_SLLIW, ALU_SRLIW, ALU_SRAIW,
            ALU_ADDW, ALU_SLLW, ALU_SRLW, ALU_SUBW, ALU_SRAW,
            ALU_CNEZ, ALU_CEQZ, ALU_ECALL, ALU_MRET, ALU_ILLEGAL
        };
    endfunction

    function automatic logic is_shared_alu(backend_exe_subop_t s);
        return is_g0_alu0(s) && (s != ALU_AUIPC);
    endfunction

    function automatic logic is_g0_bru(backend_exe_subop_t s);
        return s inside {BRU_JAL, BRU_JALR, BRU_BEQ, BRU_BNE, BRU_BLT, BRU_BLTU, BRU_BGE, BRU_BGEU};
    endfunction

    function automatic logic is_g0_div(backend_exe_subop_t s);
        return s inside {DIV_DIV, DIV_DIVU, DIV_REM, DIV_REMU, DIV_DIVW, DIV_DIVUW, DIV_REMW, DIV_REMUW, DIV_DIV_EXC};
    endfunction

    function automatic logic is_g0_csr(backend_exe_subop_t s);
        return s inside {CSR_CSRRW, CSR_CSRRS, CSR_CSRRC, CSR_CSRRWI, CSR_CSRRSI, CSR_CSRRCI, CSR_VSETVLI, CSR_VSETIVLI, CSR_VSETVL};
    endfunction

    function automatic logic is_g1_alu1(backend_exe_subop_t s);
        return is_g0_alu0(s) && (s != ALU_AUIPC);
    endfunction

    function automatic logic is_g1_mul(backend_exe_subop_t s);
        return s inside {MUL_MUL, MUL_MULH, MUL_MULHU, MUL_MULHSU, MUL_MULW};
    endfunction

    function automatic logic is_g2_fpu(backend_exe_subop_t s);
        return s inside {
            FPU_FADD, FPU_FSUB, FPU_FMUL, FPU_FDIV, FPU_FSQRT, FPU_FMIN, FPU_FMAX,
            FPU_FSGNJ, FPU_FSGNJN, FPU_FSGNJX, FPU_FEQ, FPU_FLT, FPU_FLE, FPU_FCLASS,
            FPU_FMV_X_W, FPU_FMV_W_X, FPU_FCVT_W_S, FPU_FCVT_WU_S, FPU_FCVT_L_S, FPU_FCVT_LU_S,
            FPU_FCVT_S_W, FPU_FCVT_S_WU, FPU_FCVT_S_L, FPU_FCVT_S_LU, FPU_FCVT_D_S, FPU_FCVT_S_D,
            FPU_FCVT_W_D, FPU_FCVT_WU_D, FPU_FCVT_L_D, FPU_FCVT_LU_D, FPU_FCVT_D_W, FPU_FCVT_D_WU,
            FPU_FCVT_D_L, FPU_FCVT_D_LU, FPU_FMADD, FPU_FMSUB, FPU_FNMSUB, FPU_FNMADD,
            FPU_FMV_X_D, FPU_FMV_D_X
        };
    endfunction

    function automatic logic is_g3_lsu(backend_exe_subop_t s);
        return (s == LSU_LOAD) || (s == LSU_STORE);
    endfunction

    function automatic logic is_lsu_store(backend_exe_subop_t s);
        return s == LSU_STORE;
    endfunction

    function automatic logic is_lsu_load(backend_exe_subop_t s);
        return s == LSU_LOAD;
    endfunction

endpackage

`endif // EXE_SUBOP_PKG_SV
