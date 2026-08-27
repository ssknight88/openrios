interface ob_if (input logic clk);
  import mock_rtl_pkg::*;

  logic [MOCK_ISSUE_NUM-1:0] rob_alloc_valid;
  rename_rob_t [MOCK_ISSUE_NUM-1:0] rob_alloc_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] rob_alloc_rob_idx;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_PTR_W-1:0] rob_alloc_rob_ptr;

  logic [MOCK_ISSUE_NUM-1:0] rob_commit_valid;
  rob_rename_t [MOCK_ISSUE_NUM-1:0] rob_commit_pld;
  logic [MOCK_ISSUE_NUM-1:0][MOCK_ROB_ADDR_W-1:0] rob_commit_rob_idx;

  logic [MOCK_ROB_CMT_NUM-1:0] exe_rob_wr_vld;
  logic [MOCK_ROB_CMT_NUM-1:0][MOCK_ROB_ADDR_W-1:0] exe_rob_wr_idx;

  logic [MOCK_FLUSH_ALL_DUP-1:0] flush_all;
  logic pflush;
  logic [MOCK_ROB_ADDR_W-1:0] pflush_rob_idx;
  logic redirect_valid;
  logic [MOCK_VPC_W-1:0] redirect_pc;
  longint unsigned dpi_be_phase_seq;
endinterface
