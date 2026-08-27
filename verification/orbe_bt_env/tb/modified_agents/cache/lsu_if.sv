// Mock-side BE <-> LSU bus.
//
// Signal names, payload types and semantics follow the frozen OR-BE LSU
// protocol package in this repository.
interface or_be_lsu_if (input logic clk);
  // Keep the boundary independent from TB-private packages so this interface
  // can be delivered with other verification environments.
  import or_be_lsu_protocol_pkg::*;

  logic rst_n;
  logic global_flush_late;
  logic be_lsu_issue_valid;
  be_lsu_issue_pld_t be_lsu_issue_pld;

  // Acceptance is qualified by the class of the request being offered: the
  // read side is a fixed pipeline and never stalls, so only a store-side
  // request can be refused, and only while the store buffer is full.  The
  // qualification has to be combinational -- at a driving edge the class of
  // the next request is unknown -- so only full/not-full is registered.
  logic lsu_store_buffer_full;
  logic lsu_be_issue_ready;

  assign lsu_be_issue_ready =
      rst_n && !(req_property_is_store_side(be_lsu_issue_pld.req_property) &&
                 lsu_store_buffer_full);

  logic be_lsu_entry_ready;

  // The LSU registers its results, but a flush is only known combinationally
  // (the BE derives it from the redirect it raises during the same cycle), so
  // a registered agent cannot withdraw a result it drove on the previous edge.
  // Qualify the presented lines here instead: nothing is presented on a flush
  // cycle, which is what the contract requires and what the reference agent
  // states.  The agent keeps driving its own registers, so its hold-until-
  // accepted logic is unaffected.
  logic lsu_be_done_valid_q;
  logic lsu_be_exception_valid_q;
  logic lsu_be_bypass_valid_q;

  logic lsu_be_done_valid;
  logic lsu_be_exception_valid;
  logic lsu_be_bypass_valid;

  assign lsu_be_done_valid      = lsu_be_done_valid_q      && !global_flush_late;
  assign lsu_be_exception_valid = lsu_be_exception_valid_q && !global_flush_late;
  assign lsu_be_bypass_valid    = lsu_be_bypass_valid_q    && !global_flush_late;

  lsu_be_done_pld_t lsu_be_done_pld;
  lsu_be_exception_pld_t lsu_be_exception_pld;
  // Result broadcast; rides the normal completion of a read-side request,
  // carries no ready and is never repeated.
  lsu_be_done_pld_t lsu_be_bypass_pld;

  logic be_lsu_store_wakeup_valid;

  // ---------------------------------------------------------------------
  // Protocol rules enforced at the mock-side OR-BE LSU boundary.
  // ---------------------------------------------------------------------
`ifndef SYNTHESIS
  logic early_store_wakeup_pending;
  logic issue_unresolved_plain_store;

  assign issue_unresolved_plain_store = be_lsu_issue_valid &&
                                        lsu_be_issue_ready &&
                                        be_lsu_issue_pld.req_property.is_store &&
                                        !be_lsu_issue_pld.st_br_resolve;

  // Same-cycle wakeup plus issue consumes directly; it never occupies the
  // single pre-issue authorization slot.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || global_flush_late) begin
      early_store_wakeup_pending <= 1'b0;
    end else begin
      case ({be_lsu_store_wakeup_valid, issue_unresolved_plain_store})
        2'b10: early_store_wakeup_pending <= 1'b1;
        2'b01: early_store_wakeup_pending <= 1'b0;
        2'b11: early_store_wakeup_pending <= 1'b0;
        default: early_store_wakeup_pending <= early_store_wakeup_pending;
      endcase
    end
  end

  property p_issue_property_matches_subop;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid |->
        req_property_matches_subop(be_lsu_issue_pld.req_property,
                                   be_lsu_issue_pld.exe_subop);
  endproperty
  assert property (p_issue_property_matches_subop);

  property p_issue_plain_store_matches_legacy_bit;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid |->
        (be_lsu_issue_pld.is_store == be_lsu_issue_pld.req_property.is_store);
  endproperty
  assert property (p_issue_plain_store_matches_legacy_bit);

  property p_plain_store_st_br_resolve_is_known;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid && be_lsu_issue_pld.req_property.is_store |->
        (be_lsu_issue_pld.st_br_resolve inside {1'b0, 1'b1});
  endproperty
  assert property (p_plain_store_st_br_resolve_is_known);

  property p_st_br_resolve_zero_for_non_plain_store;
    @(posedge clk) disable iff (!rst_n)
      be_lsu_issue_valid && !be_lsu_issue_pld.req_property.is_store |->
        (be_lsu_issue_pld.st_br_resolve == 1'b0);
  endproperty
  assert property (p_st_br_resolve_zero_for_non_plain_store);

  property p_terminal_channels_mutually_exclusive;
    @(posedge clk) disable iff (!rst_n)
      !(lsu_be_done_valid && lsu_be_exception_valid);
  endproperty
  assert property (p_terminal_channels_mutually_exclusive);

  // A strict "at most one early store wakeup" property is not checked at this
  // interface.  The boundary cannot tell whether a wakeup targets a store that
  // is already held by LSU or one that has not issued yet.  The equivalent
  // safety check lives in cache_agent, which fatals on an unmatched store
  // wakeup.
  logic unused_early_store_wakeup_pending;
  assign unused_early_store_wakeup_pending = early_store_wakeup_pending;

  property p_bypass_rides_normal_completion;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |-> lsu_be_done_valid;
  endproperty
  assert property (p_bypass_rides_normal_completion);

  property p_bypass_payload_matches_done;
    @(posedge clk) disable iff (!rst_n)
      lsu_be_bypass_valid |-> (lsu_be_bypass_pld == lsu_be_done_pld);
  endproperty
  assert property (p_bypass_payload_matches_done);

  // A load must never be refused: the read side has no stalling resource.
  property p_read_side_is_never_refused;
    @(posedge clk) disable iff (!rst_n)
      (be_lsu_issue_valid &&
       !req_property_is_store_side(be_lsu_issue_pld.req_property)) |->
        lsu_be_issue_ready;
  endproperty
  assert property (p_read_side_is_never_refused);

  property p_no_result_during_full_flush;
    @(posedge clk) global_flush_late |->
      !(lsu_be_done_valid || lsu_be_exception_valid || lsu_be_bypass_valid);
  endproperty
  assert property (p_no_result_during_full_flush);
`endif

  modport be (
    input clk, lsu_be_issue_ready, lsu_be_done_valid, lsu_be_done_pld,
          lsu_be_exception_valid, lsu_be_exception_pld,
          lsu_be_bypass_valid, lsu_be_bypass_pld,
    output rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
           be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late
  );

  modport lsu (
    input clk, rst_n, be_lsu_issue_valid, be_lsu_issue_pld,
          be_lsu_entry_ready, be_lsu_store_wakeup_valid, global_flush_late,
          lsu_be_issue_ready,
    input lsu_be_done_valid, lsu_be_exception_valid, lsu_be_bypass_valid,
    output lsu_store_buffer_full, lsu_be_done_valid_q, lsu_be_done_pld,
           lsu_be_exception_valid_q, lsu_be_exception_pld,
           lsu_be_bypass_valid_q, lsu_be_bypass_pld
  );
endinterface : or_be_lsu_if
