`timescale 1ns/1ps

`ifdef ORBE_DUT_RTL_V1

// RTL-near observation source for rtl_v1/backend_top.
//
// This module owns the temporary white-box observation points needed by the
// verification environment.  rtl_v1_wrapper maps its stable outputs to ob_if
// and ob_cosim_if; be_agent and COSIM code must not read backend_top internals.
module rtl_v1_obs_probe (
  input logic clk,
  input logic rst_n,

  input logic rtl_alloc_valid [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_alloc_tag [or_be_types_pkg::ISSUE_WIDTH],
  input or_be_types_pkg::ib_payload_t
      rtl_alloc_payload [or_be_types_pkg::ISSUE_WIDTH],

  input logic rtl_exec_valid [or_be_types_pkg::NUM_LANES],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_exec_tag [or_be_types_pkg::NUM_LANES],

  input logic rtl_commit_valid [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::TAG_W-1:0]
      rtl_commit_tag [or_be_types_pkg::ISSUE_WIDTH],
  input logic [or_be_types_pkg::COMMIT_COUNT_W-1:0] rtl_commit_count,
  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_trace_pc [or_be_types_pkg::ISSUE_WIDTH],

  input logic rtl_global_flush,
  input logic rtl_redirect_valid,
  input logic [or_be_types_pkg::XLEN-1:0] rtl_redirect_pc,
  input logic [or_be_types_pkg::RECOVERY_KIND_W-1:0] rtl_redirect_kind,
  input logic [or_be_types_pkg::TAG_W-1:0] rtl_recovery_flush_tag,

  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_int_arf [or_be_types_pkg::NUM_GPR],
  input logic [or_be_types_pkg::XLEN-1:0]
      rtl_fp_arf [or_be_types_pkg::NUM_FPR],

  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_alloc_valid,
  output mock_rtl_pkg::rob_alloc_pld_t
      [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_alloc_pld,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_alloc_tag,

  output logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0] obs_exec_valid,
  output logic [mock_rtl_pkg::MOCK_ROB_CMT_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_exec_tag,

  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0] obs_commit_valid,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0]
      [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_commit_tag,
  output logic [mock_rtl_pkg::MOCK_ISSUE_NUM-1:0][63:0] obs_commit_pc,
  output logic [$clog2(mock_rtl_pkg::MOCK_ISSUE_NUM+1)-1:0]
      obs_commit_count,

  output logic obs_global_flush,
  output logic obs_redirect_valid,
  output logic [mock_rtl_pkg::MOCK_VPC_W-1:0] obs_redirect_pc,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_redirect_kind,
  output logic obs_recovery_valid,
  output orbe_cosim_obs_pkg::orbe_recovery_kind_e obs_recovery_kind,
  output logic [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_recovery_origin_tag,
  output logic [mock_rtl_pkg::MOCK_ROB_ADDR_W-1:0] obs_recovery_squash_tag,
  output logic [63:0] obs_recovery_redirect_pc,

  output logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0]
      obs_int_arf,
  output logic [orbe_cosim_obs_pkg::COSIM_ARF_REG_NUM-1:0][63:0]
      obs_fp_arf,
  output logic obs_csr_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0]
      obs_csr_state_valid,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][11:0]
      obs_csr_state_addr,
  output logic [orbe_cosim_obs_pkg::COSIM_CSR_STATE_NUM-1:0][63:0]
      obs_csr_state,
  output logic obs_csr_event_valid,
  output logic [11:0] obs_csr_event_addr,
  output logic [63:0] obs_csr_event_wdata,
  output logic [63:0] obs_csr_event_rdata
);
  import mock_rtl_pkg::*;
  import orbe_cosim_obs_pkg::*;
  import or_be_types_pkg::*;

  function automatic bit recovery_commits_origin(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT,
      ORBE_RECOVERY_MRET,
      ORBE_RECOVERY_FENCE_I,
      ORBE_RECOVERY_SRET:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  initial begin
    if (MOCK_ISSUE_NUM != ISSUE_WIDTH)
      $fatal(1, "[RTL_V1_OBS] issue width mismatch env=%0d rtl=%0d",
             MOCK_ISSUE_NUM, ISSUE_WIDTH);
    if (MOCK_ROB_CMT_NUM != NUM_LANES)
      $fatal(1, "[RTL_V1_OBS] completion source mismatch env=%0d rtl=%0d",
             MOCK_ROB_CMT_NUM, NUM_LANES);
    if (MOCK_ROB_TAG_W != TAG_W)
      $fatal(1, "[RTL_V1_OBS] tag width mismatch env=%0d rtl=%0d",
             MOCK_ROB_TAG_W, TAG_W);
    if (MOCK_ROB_ADDR_W < TAG_W)
      $fatal(1, "[RTL_V1_OBS] observation ROB index width %0d is narrower than rtl tag width %0d",
             MOCK_ROB_ADDR_W, TAG_W);
    if (COSIM_ARF_REG_NUM != NUM_GPR || COSIM_ARF_REG_NUM != NUM_FPR)
      $fatal(1, "[RTL_V1_OBS] ARF snapshot count mismatch cosim=%0d int=%0d fp=%0d",
             COSIM_ARF_REG_NUM, NUM_GPR, NUM_FPR);
  end

  // Register only the event observation copy.  rtl_v1's commit/recovery
  // outputs are cycle-start combinational requests; be_agent samples at
  // negedge and must see them after the RTL sequential state has consumed
  // them at posedge.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      obs_alloc_valid <= '0;
      obs_alloc_pld <= '{default:'0};
      obs_alloc_tag <= '0;
      obs_exec_valid <= '0;
      obs_exec_tag <= '0;
      obs_commit_valid <= '0;
      obs_commit_tag <= '0;
      obs_commit_pc <= '0;
      obs_commit_count <= '0;
      obs_global_flush <= 1'b0;
      obs_redirect_valid <= 1'b0;
      obs_redirect_pc <= '0;
      obs_redirect_kind <= ORBE_RECOVERY_MISPREDICT;
      obs_recovery_valid <= 1'b0;
      obs_recovery_kind <= ORBE_RECOVERY_MISPREDICT;
      obs_recovery_origin_tag <= '0;
      obs_recovery_squash_tag <= '0;
      obs_recovery_redirect_pc <= '0;
    end else begin
      orbe_recovery_kind_e kind;
      logic [MOCK_ROB_ADDR_W-1:0] recovery_origin;
      logic [MOCK_ROB_ADDR_W-1:0] recovery_squash;

      kind = orbe_recovery_kind_e'(rtl_redirect_kind);
      recovery_origin = '0;
      recovery_origin[TAG_W-1:0] = rtl_recovery_flush_tag;
      recovery_squash = recovery_origin;
      if (recovery_commits_origin(kind))
        recovery_squash[TAG_W-1:0] = rtl_recovery_flush_tag + 1'b1;

      obs_alloc_valid <= '0;
      obs_alloc_pld <= '{default:'0};
      obs_alloc_tag <= '0;
      for (int group = 0; group < ISSUE_WIDTH; group++) begin
        obs_alloc_valid[group] <= rtl_alloc_valid[group];
        obs_alloc_tag[group][TAG_W-1:0] <= rtl_alloc_tag[group];
        obs_alloc_pld[group].pc <= rtl_alloc_payload[group].pc;
        obs_alloc_pld[group].inst_bits <= rtl_alloc_payload[group].inst_bits;
        obs_alloc_pld[group].is_compressed <=
            rtl_alloc_payload[group].is_compressed;
        obs_alloc_pld[group].fetch_excp_vld <=
            rtl_alloc_payload[group].fetch_excp_vld;
        obs_alloc_pld[group].exception_cause <=
            rtl_alloc_payload[group].fetch_excp_cause;
        obs_alloc_pld[group].exception_tval <=
            rtl_alloc_payload[group].fetch_excp_tval;
        obs_alloc_pld[group].is_lsu <= 1'b0;
      end

      obs_exec_valid <= '0;
      obs_exec_tag <= '0;
      for (int source = 0; source < NUM_LANES; source++) begin
        obs_exec_valid[source] <= rtl_exec_valid[source];
        obs_exec_tag[source][TAG_W-1:0] <= rtl_exec_tag[source];
      end

      obs_commit_valid <= '0;
      obs_commit_tag <= '0;
      obs_commit_pc <= '0;
      for (int group = 0; group < ISSUE_WIDTH; group++) begin
        obs_commit_valid[group] <= rtl_commit_valid[group];
        obs_commit_tag[group][TAG_W-1:0] <= rtl_commit_tag[group];
        obs_commit_pc[group] <= rtl_trace_pc[group];
      end
      obs_commit_count <= rtl_commit_count;

      obs_global_flush <= rtl_global_flush;
      obs_redirect_valid <= rtl_redirect_valid;
      obs_redirect_pc <= rtl_redirect_pc;
      obs_redirect_kind <= kind;
      obs_recovery_valid <= rtl_global_flush || rtl_redirect_valid;
      obs_recovery_kind <= kind;
      obs_recovery_origin_tag <= recovery_origin;
      obs_recovery_squash_tag <= recovery_squash;
      obs_recovery_redirect_pc <= rtl_redirect_pc;
    end
  end

  // ARF snapshot is intentionally not registered here.  The COSIM sampler
  // observes it at negedge, after backend_top's ARF flops have updated on the
  // preceding posedge.
  always_comb begin
    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      obs_int_arf[index] = (index == 0) ? '0 : rtl_int_arf[index];
      obs_fp_arf[index] = rtl_fp_arf[index];
    end
  end

  // CSR comparison remains disabled until the compared CSR set is frozen.
  assign obs_csr_valid = 1'b0;
  assign obs_csr_state_valid = '0;
  assign obs_csr_state_addr = '0;
  assign obs_csr_state = '0;
  assign obs_csr_event_valid = 1'b0;
  assign obs_csr_event_addr = '0;
  assign obs_csr_event_wdata = '0;
  assign obs_csr_event_rdata = '0;
endmodule

`endif
