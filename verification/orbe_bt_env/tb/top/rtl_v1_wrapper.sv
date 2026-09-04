`timescale 1ns/1ps

`ifdef ORBE_DUT_RTL_V1

module rtl_v1_wrapper (
  input logic clk,
  input logic rst_n,
  orbe_fe_if fe,
  or_be_lsu_if lsu,
  ob_if ob,
  ob_cosim_if #(
    .ISSUE_NUM(mock_rtl_pkg::MOCK_ISSUE_NUM),
    .ROB_ADDR_W(mock_rtl_pkg::MOCK_ROB_ADDR_W)
  ) ob_cosim
);
  import mock_rtl_pkg::*;
  import orbe_cosim_obs_pkg::*;
  import or_be_lsu_protocol_pkg::*;
  import or_be_types_pkg::*;
  import fe_be_protocol_pkg::*;

  logic [ISSUE_WIDTH-1:0] rtl_fe_valid;
  fe_be_instr_pld_t rtl_fe_instr_pld [ISSUE_WIDTH];
  logic [ISSUE_WIDTH-1:0] rtl_fe_ready;
  logic [ISSUE_WIDTH-1:0] rtl_accepted_slot;

  logic rtl_redirect_valid;
  logic [XLEN-1:0] rtl_redirect_pc;
  logic [RECOVERY_KIND_W-1:0] rtl_redirect_kind;
  logic rtl_frontend_icache_invalidate;
  logic rtl_predictor_update_valid;
  logic [XLEN-1:0] rtl_predictor_update_branch_pc;
  logic rtl_predictor_update_actual_taken;
  logic [XLEN-1:0] rtl_predictor_update_actual_target;
  cf_class_e rtl_predictor_update_cf_class;

  logic rtl_be_lsu_issue_valid;
  be_lsu_issue_pld_t rtl_be_lsu_issue_pld;
  logic rtl_be_lsu_store_wakeup_valid;
  logic [TAG_W-1:0] rtl_be_lsu_store_wakeup_tag;
  logic rtl_global_flush;
  logic rtl_lsu_be_writeback_valid;

  logic rtl_alloc_valid [ISSUE_WIDTH];
  logic [TAG_W-1:0] rtl_alloc_tag [ISSUE_WIDTH];
  logic rtl_exec_valid [NUM_LANES];
  logic [TAG_W-1:0] rtl_exec_tag [NUM_LANES];
  logic rtl_commit_valid [ISSUE_WIDTH];
  logic [TAG_W-1:0] rtl_commit_tag [ISSUE_WIDTH];
  logic [REG_ADDR_W-1:0] rtl_commit_rd_idx [ISSUE_WIDTH];
  logic rtl_commit_rd_is_fp [ISSUE_WIDTH];
  logic rtl_commit_rd_write_enable [ISSUE_WIDTH];
  logic [FFLAGS_W-1:0] rtl_commit_fflags [ISSUE_WIDTH];
  logic [COMMIT_COUNT_W-1:0] rtl_commit_count;
  logic [XLEN-1:0] rtl_commit_data [ISSUE_WIDTH];
  logic [XLEN-1:0] rtl_trace_pc [ISSUE_WIDTH];

  logic [MOCK_ISSUE_NUM-1:0] obs_alloc_valid;
  rob_alloc_pld_t [MOCK_ISSUE_NUM-1:0] obs_alloc_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] obs_alloc_tag;

  logic [MOCK_ROB_CMT_NUM-1:0] obs_exec_valid;
  logic [MOCK_ROB_CMT_NUM-1:0][MOCK_ROB_ADDR_W-1:0] obs_exec_tag;

  logic [MOCK_ISSUE_NUM-1:0] obs_commit_valid;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] obs_commit_tag;
  logic [MOCK_ISSUE_NUM-1:0][63:0] obs_commit_pc;
  logic [$clog2(MOCK_ISSUE_NUM+1)-1:0] obs_commit_count;

  logic obs_global_flush;
  logic obs_redirect_valid;
  logic [MOCK_VPC_W-1:0] obs_redirect_pc;
  orbe_recovery_kind_e obs_redirect_kind;
  logic obs_recovery_valid;
  orbe_recovery_kind_e obs_recovery_kind;
  logic [MOCK_ROB_ADDR_W-1:0] obs_recovery_origin_tag;
  logic [MOCK_ROB_ADDR_W-1:0] obs_recovery_squash_tag;
  logic [63:0] obs_recovery_redirect_pc;

  logic [COSIM_ARF_REG_NUM-1:0][63:0] obs_int_arf;
  logic [COSIM_ARF_REG_NUM-1:0][63:0] obs_fp_arf;
  logic obs_csr_valid;
  logic [COSIM_CSR_STATE_NUM-1:0] obs_csr_state_valid;
  logic [COSIM_CSR_STATE_NUM-1:0][11:0] obs_csr_state_addr;
  logic [COSIM_CSR_STATE_NUM-1:0][63:0] obs_csr_state;
  logic obs_csr_event_valid;
  logic [11:0] obs_csr_event_addr;
  logic [63:0] obs_csr_event_wdata;
  logic [63:0] obs_csr_event_rdata;

  always_comb begin
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      rtl_fe_valid[group] = fe.fe_be_instr_valid[group];
      rtl_fe_instr_pld[group] = '0;
      rtl_fe_instr_pld[group].pc = fe.fe_be_instr_pld[group].pc;
      rtl_fe_instr_pld[group].inst_bits = fe.fe_be_instr_pld[group].inst_bits;
      rtl_fe_instr_pld[group].is_compressed =
          fe.fe_be_instr_pld[group].is_compressed;
      rtl_fe_instr_pld[group].pred_taken =
          fe.fe_be_instr_pld[group].pred_taken;
      rtl_fe_instr_pld[group].pred_target_pc =
          fe.fe_be_instr_pld[group].pred_target_pc;
      rtl_fe_instr_pld[group].fetch_excp_vld =
          fe.fe_be_instr_pld[group].fetch_excp_vld;
      rtl_fe_instr_pld[group].fetch_excp_cause =
          fe.fe_be_instr_pld[group].exception_cause;
      rtl_fe_instr_pld[group].fetch_excp_tval =
          fe.fe_be_instr_pld[group].exception_tval;
      fe.be_fe_instr_ready[group] = rtl_fe_ready[group];
    end
  end

  always_comb begin
    orbe_recovery_kind_e kind;

    kind = orbe_recovery_kind_e'(rtl_redirect_kind);
    fe.be_fe_redirect_valid = rtl_redirect_valid;
    fe.be_fe_redirect_pld = '0;
    fe.be_fe_redirect_pld.redirect_pc = rtl_redirect_pc;
    fe.be_fe_redirect_pld.interrupt_valid =
        rtl_redirect_valid && (kind == ORBE_RECOVERY_INTERRUPT);
    fe.be_fe_redirect_pld.trap_valid =
        rtl_redirect_valid &&
        ((kind == ORBE_RECOVERY_EXCEPTION) ||
         (kind == ORBE_RECOVERY_MRET) ||
         (kind == ORBE_RECOVERY_SRET));
  end

  assign lsu.be_lsu_issue_valid = rtl_be_lsu_issue_valid;
  assign lsu.be_lsu_issue_pld = rtl_be_lsu_issue_pld;
  assign lsu.be_lsu_store_wakeup_valid = rtl_be_lsu_store_wakeup_valid;
  assign lsu.global_flush_late = rtl_global_flush;
  assign lsu.be_lsu_entry_ready = rst_n && !rtl_global_flush;
  assign rtl_lsu_be_writeback_valid =
      lsu.lsu_be_done_valid || lsu.lsu_be_exception_valid;

  always_comb begin
    ob.alloc_valid = '0;
    ob.alloc_pld = '{default:'0};
    ob.alloc_tag = '0;
    ob.rob_alloc_valid = '0;
    ob.rob_alloc_pld = '{default:'0};
    ob.rob_alloc_rob_idx = '0;
    ob.rob_alloc_rob_ptr = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob.alloc_valid[group] = obs_alloc_valid[group];
      ob.alloc_tag[group] = obs_alloc_tag[group];
      ob.alloc_pld[group] = obs_alloc_pld[group];

      ob.rob_alloc_valid[group] = ob.alloc_valid[group];
      ob.rob_alloc_pld[group] = ob.alloc_pld[group];
      ob.rob_alloc_rob_idx[group] = ob.alloc_tag[group];
      ob.rob_alloc_rob_ptr[group][TAG_W-1:0] =
          obs_alloc_tag[group][TAG_W-1:0];
    end

    ob.exec_valid = '0;
    ob.exec_tag = '0;
    ob.exe_rob_wr_vld = '0;
    ob.exe_rob_wr_idx = '0;
    for (int source = 0; source < NUM_LANES; source++) begin
      ob.exec_valid[source] = obs_exec_valid[source];
      ob.exec_tag[source] = obs_exec_tag[source];
      ob.exe_rob_wr_vld[source] = ob.exec_valid[source];
      ob.exe_rob_wr_idx[source] = ob.exec_tag[source];
    end

    ob.commit_valid = '0;
    ob.commit_tag = '0;
    ob.commit_pc = '0;
    ob.rob_commit_valid = '0;
    ob.rob_commit_pld = '{default:'0};
    ob.rob_commit_rob_idx = '0;
    for (int group = 0; group < ISSUE_WIDTH; group++) begin
      ob.commit_valid[group] = obs_commit_valid[group];
      ob.commit_tag[group] = obs_commit_tag[group];
      ob.commit_pc[group] = obs_commit_pc[group];
      ob.rob_commit_valid[group] = ob.commit_valid[group];
      ob.rob_commit_pld[group].pc = ob.commit_pc[group];
      ob.rob_commit_pld[group].rob_idx = ob.commit_tag[group];
      ob.rob_commit_rob_idx[group] = ob.commit_tag[group];
    end
    ob.commit_count = obs_commit_count;

    ob.global_flush = obs_global_flush;
    ob.redirect_valid = obs_redirect_valid;
    ob.redirect_pc = obs_redirect_pc;
    ob.redirect_kind = obs_redirect_kind;
    ob.recovery_valid = obs_recovery_valid;
    ob.recovery_kind = obs_recovery_kind;
    ob.recovery_origin_tag = obs_recovery_origin_tag;
    ob.recovery_squash_tag = obs_recovery_squash_tag;
    ob.recovery_redirect_pc = obs_recovery_redirect_pc;

    ob.flush_all = '0;
    if (ob.recovery_valid &&
        ((obs_recovery_kind == ORBE_RECOVERY_EXCEPTION) ||
         (obs_recovery_kind == ORBE_RECOVERY_INTERRUPT)))
      ob.flush_all = '1;
    ob.pflush = ob.recovery_valid && (ob.flush_all == '0);
    ob.pflush_rob_idx = obs_recovery_origin_tag;
  end

  assign ob_cosim.commit_valid = obs_commit_valid;
  assign ob_cosim.commit_rob_idx = obs_commit_tag;
  assign ob_cosim.commit_pc = obs_commit_pc;
  assign ob_cosim.int_arf = obs_int_arf;
  assign ob_cosim.fp_arf = obs_fp_arf;
  assign ob_cosim.csr_valid = obs_csr_valid;
  assign ob_cosim.csr_state_valid = obs_csr_state_valid;
  assign ob_cosim.csr_state_addr = obs_csr_state_addr;
  assign ob_cosim.csr_state = obs_csr_state;
  assign ob_cosim.csr_event_valid = obs_csr_event_valid;
  assign ob_cosim.csr_event_addr = obs_csr_event_addr;
  assign ob_cosim.csr_event_wdata = obs_csr_event_wdata;
  assign ob_cosim.csr_event_rdata = obs_csr_event_rdata;

  backend_top u_backend (
    .clk(clk),
    .rst_n(rst_n),
    .fe_valid(rtl_fe_valid),
    .fe_instr_pld(rtl_fe_instr_pld),
    .fe_ready(rtl_fe_ready),
    .accepted_slot(rtl_accepted_slot),
    .redirect_valid(rtl_redirect_valid),
    .redirect_pc(rtl_redirect_pc),
    .redirect_kind(rtl_redirect_kind),
    .frontend_icache_invalidate(rtl_frontend_icache_invalidate),
    .predictor_update_valid(rtl_predictor_update_valid),
    .predictor_update_branch_pc(rtl_predictor_update_branch_pc),
    .predictor_update_actual_taken(rtl_predictor_update_actual_taken),
    .predictor_update_actual_target(rtl_predictor_update_actual_target),
    .predictor_update_cf_class(rtl_predictor_update_cf_class),
    .be_lsu_issue_valid(rtl_be_lsu_issue_valid),
    .be_lsu_issue_pld(rtl_be_lsu_issue_pld),
    .be_lsu_store_wakeup_valid(rtl_be_lsu_store_wakeup_valid),
    .be_lsu_store_wakeup_tag(rtl_be_lsu_store_wakeup_tag),
    .global_flush(rtl_global_flush),
    .lsu_be_issue_ready(lsu.lsu_be_issue_ready),
    .lsu_be_writeback_valid(rtl_lsu_be_writeback_valid),
    .lsu_be_writeback_pld(lsu.lsu_be_writeback_pld),
    .lsu_be_bypass_valid(lsu.lsu_be_bypass_valid),
    .lsu_be_bypass_pld(lsu.lsu_be_bypass_pld),
    .mip_meip(1'b0),
    .mip_mtip(1'b0),
    .mip_msip(1'b0),
    .alloc_valid(rtl_alloc_valid),
    .alloc_tag(rtl_alloc_tag),
    .exec_valid(rtl_exec_valid),
    .exec_tag(rtl_exec_tag),
    .commit_valid(rtl_commit_valid),
    .commit_tag(rtl_commit_tag),
    .commit_rd_idx(rtl_commit_rd_idx),
    .commit_rd_is_fp(rtl_commit_rd_is_fp),
    .commit_rd_write_enable(rtl_commit_rd_write_enable),
    .commit_fflags(rtl_commit_fflags),
    .commit_count(rtl_commit_count),
    .commit_data(rtl_commit_data),
    .trace_pc(rtl_trace_pc)
  );

  rtl_v1_obs_probe u_obs_probe (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .rtl_alloc_valid       (rtl_alloc_valid),
    .rtl_alloc_tag         (rtl_alloc_tag),
    .rtl_alloc_payload     (u_backend.head_IB_Payload),
    .rtl_exec_valid        (rtl_exec_valid),
    .rtl_exec_tag          (rtl_exec_tag),
    .rtl_commit_valid      (rtl_commit_valid),
    .rtl_commit_tag        (rtl_commit_tag),
    .rtl_commit_count      (rtl_commit_count),
    .rtl_trace_pc          (rtl_trace_pc),
    .rtl_global_flush      (rtl_global_flush),
    .rtl_redirect_valid    (rtl_redirect_valid),
    .rtl_redirect_pc       (rtl_redirect_pc),
    .rtl_redirect_kind     (rtl_redirect_kind),
    .rtl_recovery_flush_tag(u_backend.scb_flush_tag),
    .rtl_int_arf           (u_backend.u_INT_ARF.entry_arf),
    .rtl_fp_arf            (u_backend.u_FP_ARF.entry_arf),
    .obs_alloc_valid       (obs_alloc_valid),
    .obs_alloc_pld         (obs_alloc_pld),
    .obs_alloc_tag         (obs_alloc_tag),
    .obs_exec_valid        (obs_exec_valid),
    .obs_exec_tag          (obs_exec_tag),
    .obs_commit_valid      (obs_commit_valid),
    .obs_commit_tag        (obs_commit_tag),
    .obs_commit_pc         (obs_commit_pc),
    .obs_commit_count      (obs_commit_count),
    .obs_global_flush      (obs_global_flush),
    .obs_redirect_valid    (obs_redirect_valid),
    .obs_redirect_pc       (obs_redirect_pc),
    .obs_redirect_kind     (obs_redirect_kind),
    .obs_recovery_valid    (obs_recovery_valid),
    .obs_recovery_kind     (obs_recovery_kind),
    .obs_recovery_origin_tag(obs_recovery_origin_tag),
    .obs_recovery_squash_tag(obs_recovery_squash_tag),
    .obs_recovery_redirect_pc(obs_recovery_redirect_pc),
    .obs_int_arf           (obs_int_arf),
    .obs_fp_arf            (obs_fp_arf),
    .obs_csr_valid         (obs_csr_valid),
    .obs_csr_state_valid   (obs_csr_state_valid),
    .obs_csr_state_addr    (obs_csr_state_addr),
    .obs_csr_state         (obs_csr_state),
    .obs_csr_event_valid   (obs_csr_event_valid),
    .obs_csr_event_addr    (obs_csr_event_addr),
    .obs_csr_event_wdata   (obs_csr_event_wdata),
    .obs_csr_event_rdata   (obs_csr_event_rdata)
  );

endmodule

`endif
