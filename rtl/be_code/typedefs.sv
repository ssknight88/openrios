`ifndef TYPEDEFS_SV
`define TYPEDEFS_SV

package orca_types;

    // Parameters
    localparam XLEN = 64;
    localparam FLEN = 64;
    localparam ROB_DEPTH = 16;
    localparam TAG_W = 4;
    localparam REG_ADDR_W = 5;
    localparam EXE_TYPE_W = 2;
    localparam EXE_SUBOP_W = 6;

    // Execution Groups
    typedef enum logic [EXE_TYPE_W-1:0] {
        GROUP_ALU0_BRU_DIV_CSR = 2'b00,
        GROUP_ALU1_MUL         = 2'b01,
        GROUP_FPU              = 2'b10,
        GROUP_LSU              = 2'b11
    } exe_group_e;

    // P0 -> P1: ISB_Payload
    typedef struct packed {
        logic               inst_valid;     // Added for alignment
        logic [XLEN-1:0]    pc;
        logic [EXE_TYPE_W-1:0] exe_type;
        logic [EXE_SUBOP_W-1:0] exe_subop;
        logic               is_csr;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic [REG_ADDR_W-1:0] rs1_idx;
        logic [REG_ADDR_W-1:0] rs2_idx;
        logic [REG_ADDR_W-1:0] rs3_idx;
        logic               use_rd;
        logic               use_rs1;
        logic               use_rs2;
        logic               use_rs3;
        logic               rd_is_fp;
        logic               rs1_is_fp;
        logic               rs2_is_fp;
        logic               rs3_is_fp;
        logic               imm_valid;
        logic [XLEN-1:0]    imm_data;
        logic               pred_taken;
        logic [XLEN-1:0]    pred_target_pc;
        logic [2:0]         store_size;
    } isb_payload_t;

    // P1 -> P2: ISQ_Payload
    typedef struct packed {
        logic [TAG_W-1:0]   self_rob_tag;
        logic [EXE_SUBOP_W-1:0] exe_subop;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic               rd_is_fp;
        logic               uses_fp_state;
        logic               rs1_ready;
        logic               rs2_ready;
        logic               rs3_ready;
        logic [XLEN-1:0]    rs1_data;
        logic [XLEN-1:0]    rs2_data;
        logic [XLEN-1:0]    rs3_data;
        logic [TAG_W-1:0]   rs1_wait_tag;
        logic [TAG_W-1:0]   rs2_wait_tag;
        logic [TAG_W-1:0]   rs3_wait_tag;
        logic [XLEN-1:0]    pc;
        logic               pred_taken;
        logic [XLEN-1:0]    pred_target_pc;
        logic               imm_valid;
        logic [XLEN-1:0]    imm_data;
        logic               csr_write_intent;
        logic               is_store;
        logic [XLEN-1:0]    store_data;
        logic [7:0]         store_mask;
        logic [2:0]         store_size;
    } isq_payload_t;

    // P2 -> external LSU black-box request
    typedef struct packed {
        logic [TAG_W-1:0]   tag;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic               rd_is_fp;
        logic               is_load;
        logic               is_store;
        logic [XLEN-1:0]    base_addr;
        logic               imm_valid;
        logic [XLEN-1:0]    imm_data;
        logic [XLEN-1:0]    store_data;
        logic [7:0]         store_mask;
        logic [2:0]         store_size;
    } lsu_req_t;

    // P3 -> P4 / Bypass: Result_Payload
    typedef struct packed {
        logic               result_valid;   // Added for alignment
        logic [TAG_W-1:0]   tag_out;
        logic [XLEN-1:0]    result_data;
        logic               exception_flag;
        logic               mispredict_flag;
        logic [XLEN-1:0]    correct_pc;
        logic [XLEN-1:0]    exception_cause;
        logic               is_csr;
        logic               csr_write_enable;
        logic [11:0]        csr_addr;
        logic [XLEN-1:0]    csr_wdata;
        logic               is_fp;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic [4:0]         fpu_fflags;     // FP exception flags (NV/DZ/OF/UF/NX), valid for FP ops
        logic [XLEN-1:0]    exception_tval; // faulting value for mtval (e.g. bad load/store address)
        logic               is_mret;        // MRET trap-return marker (resolved at commit)
    } result_payload_t;

    // Bypass Bus Entry (Stripped metadata for alignment)
    typedef struct packed {
        logic               valid;
        logic [TAG_W-1:0]   tag;
        logic [XLEN-1:0]    data;
    } bypass_t;

    // P4 -> ARF: Commit_Payload
    typedef struct packed {
        logic               commit_valid;   // Added for alignment
        logic [TAG_W-1:0]   commit_tag;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic               rd_is_fp;
        logic [XLEN-1:0]    result_data;
    } commit_payload_t;

    // ROB Head Status (P4 commit interface)
    // Matches rob_entry_t field layout so that rob_data[head] can be
    // assigned directly to this struct without per-field mapping.
    typedef struct packed {
        logic               valid;
        logic               done;
        logic               is_store;
        logic               store_buffered;
        logic               store_drain_requested;
        logic               store_done;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic               rd_is_fp;
        logic [XLEN-1:0]    result_data;
        logic               mispredict_flag;
        logic               exception_flag;
        logic               is_csr;
        logic               csr_write_enable;
        logic [4:0]         fpu_fflags;
        logic               is_mret;
    } rob_head_status_t;

    // ROB SideArray Entry
    typedef enum logic [1:0] {
        FLUSH_NONE       = 2'b00,
        FLUSH_MISPREDICT = 2'b01,
        FLUSH_EXCEPTION  = 2'b10,
        FLUSH_MRET       = 2'b11
    } flush_kind_e;



    typedef struct packed {
        logic               valid;
        flush_kind_e        kind;
        logic [XLEN-1:0]    inst_pc;
        logic [XLEN-1:0]    target_pc;
        logic [XLEN-1:0]    exception_cause;
        logic [XLEN-1:0]    exception_tval;
    } sidearray_entry_t;

endpackage

`endif // TYPEDEFS_SV
