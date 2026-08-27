// Backend observer and sole BE-side owner of decode/execute/commit/flush DPI.
class be_agent;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned DPI_ROB_IDX_W = 6;

  virtual ob_if ob_vif;
  virtual orbe_fe_if fe_vif;
  be_config cfg;
  be_getter getter;
  bit stop_requested;
  bit model_ready;

  bit allocated_by_rob[longint unsigned];
  bit lsu_by_rob[longint unsigned];
  bit execute_started_by_rob[longint unsigned];
  bit pending_by_rob[longint unsigned];
  logic [MOCK_ROB_TAG_W-1:0] full_tag_by_rob[longint unsigned];
  longint unsigned allocation_order_by_rob[longint unsigned];
  longint unsigned next_allocation_order;

  logic [MOCK_FLUSH_ALL_DUP-1:0] last_flush_all;
  bit last_pflush;
  bit trap_commit_consumed;
  longint unsigned cycle_count;
  longint unsigned retire_count;
  longint unsigned retire_print_interval;

  function new(virtual ob_if ob_vif, virtual orbe_fe_if fe_vif,
               virtual getter_if getter_vif, be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[BE] be_agent requires be_config");
    this.ob_vif = ob_vif;
    this.fe_vif = fe_vif;
    this.cfg = cfg;
    getter = new(getter_vif, cfg);
    stop_requested = 1'b0;
    model_ready = 1'b0;
    last_flush_all = '0;
    last_pflush = 1'b0;
    trap_commit_consumed = 1'b0;
    cycle_count = 0;
    retire_count = 0;
    retire_print_interval = 1;
    void'($value$plusargs("RETIRE_PRINT_INTERVAL=%d", retire_print_interval));
    if (retire_print_interval == 0)
      cfg.reporter.fatal("[BE] RETIRE_PRINT_INTERVAL must be non-zero");
    next_allocation_order = 0;
    ob_vif.dpi_be_phase_seq = 0;
    if (MOCK_ROB_ADDR_W != DPI_ROB_IDX_W)
      cfg.reporter.fatal("[BE] observer/model ROB width mismatch");
  endfunction

  function automatic logic [DPI_ROB_IDX_W-1:0] dpi_rob_idx(
      input longint unsigned rob_idx);
    return rob_idx[DPI_ROB_IDX_W-1:0];
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[BE] %s failed rc=%0d", operation, rc));
  endtask

  task automatic wait_for_model();
    while (!stop_requested) begin
      @(negedge ob_vif.clk);
      if (isa_dpi_is_config_ready()) begin
        model_ready = 1'b1;
        return;
      end
    end
  endtask

  task automatic clear_local_anchors();
    allocated_by_rob.delete();
    lsu_by_rob.delete();
    execute_started_by_rob.delete();
    pending_by_rob.delete();
    full_tag_by_rob.delete();
    allocation_order_by_rob.delete();
  endtask

  task automatic observe_allocations();
    longint unsigned rob_idx;
    longint signed insn_id;
    bit getter_is_lsu;

    if (ob_vif.redirect_valid || ob_vif.rob_alloc_valid == '0)
      return;
    for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++) begin
      if (!ob_vif.rob_alloc_valid[lane])
        continue;
      rob_idx = ob_vif.rob_alloc_rob_idx[lane];
      insn_id = isa_dpi_decode_and_issue(
          MODEL_CORE_ID, dpi_rob_idx(rob_idx), ob_vif.rob_alloc_pld[lane].pc,
          ob_vif.rob_alloc_pld[lane].inst_bits,
          ob_vif.rob_alloc_pld[lane].is_compressed);
      if (insn_id == ISA_API_INVALID_INSN_ID)
        cfg.reporter.fatal($sformatf(
            "[BE] decodeAndIssue lost anchor lane=%0d rob=%0d pc=0x%016h",
            lane, rob_idx, ob_vif.rob_alloc_pld[lane].pc));
      if (ob_vif.rob_alloc_pld[lane].fetch_excp_vld) begin
        check_rc($sformatf("triggerTrap rob=%0d", rob_idx),
                 isa_dpi_trigger_trap(
                     MODEL_CORE_ID, dpi_rob_idx(rob_idx),
                     ob_vif.rob_alloc_pld[lane].exception_cause,
                     ob_vif.rob_alloc_pld[lane].exception_tval));
      end
      full_tag_by_rob[rob_idx] = ob_vif.rob_alloc_rob_ptr[lane][MOCK_ROB_TAG_W-1:0];
      getter.after_decode(lane, full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          getter_is_lsu);
      allocated_by_rob[rob_idx] = 1'b1;
      lsu_by_rob[rob_idx] = getter_is_lsu;
      execute_started_by_rob.delete(rob_idx);
      pending_by_rob.delete(rob_idx);
      allocation_order_by_rob[rob_idx] = next_allocation_order++;
      cfg.print_be(3, $sformatf(
          "[BE][DECODE] cycle=%0d lane=%0d tag=0x%0h rob=%0d id=%0d pc=0x%016h lsu=%0b",
          cycle_count, lane, full_tag_by_rob[rob_idx], rob_idx, insn_id,
          ob_vif.rob_alloc_pld[lane].pc, getter_is_lsu));
    end
  endtask

  task automatic finish_execute(input longint unsigned rob_idx, input int rc,
                                input string operation);
    bit trap_valid;
    if (rc == ISA_API_PENDING) begin
      pending_by_rob[rob_idx] = 1'b1;
      return;
    end
    trap_valid = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx)) != 0;
    if ((rc == ISA_API_FAIL) && !trap_valid)
      cfg.reporter.fatal($sformatf("[BE] %s failed without model trap rc=%0d", operation, rc));
    if ((rc != ISA_API_PASS) && (rc != ISA_API_SKIP)
        && !((rc == ISA_API_FAIL) && trap_valid))
      cfg.reporter.fatal($sformatf("[BE] %s invalid rc=%0d", operation, rc));
    pending_by_rob.delete(rob_idx);
    getter.after_execute(full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx));
  endtask

  task automatic retry_pending_execution();
    longint unsigned rob_idx;
    foreach (pending_by_rob[rob_idx]) begin
      int rc;
      if (!pending_by_rob[rob_idx])
        continue;
      if (!allocated_by_rob.exists(rob_idx) || lsu_by_rob[rob_idx]) begin
        pending_by_rob.delete(rob_idx);
        continue;
      end
      rc = isa_dpi_execute_insn(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
      finish_execute(rob_idx, rc, $sformatf("executeInsn-retry rob=%0d", rob_idx));
    end
  endtask

  task automatic observe_execution_writebacks();
    for (int source = 0; source < MOCK_ROB_CMT_NUM; source++) begin
      longint unsigned rob_idx;
      int rc;
      if (!ob_vif.exe_rob_wr_vld[source])
        continue;
      rob_idx = ob_vif.exe_rob_wr_idx[source];
      if (!allocated_by_rob.exists(rob_idx)) begin
        cfg.print_be(3, $sformatf("[BE] ignore stale execute rob=%0d", rob_idx));
        continue;
      end
      if (lsu_by_rob[rob_idx])
        continue;
      if (execute_started_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf("[BE] duplicate execute event rob=%0d", rob_idx));
      execute_started_by_rob[rob_idx] = 1'b1;
      rc = isa_dpi_execute_insn(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
      finish_execute(rob_idx, rc, $sformatf("executeInsn rob=%0d", rob_idx));
    end
  endtask

  task automatic observe_commits();
    for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++) begin
      longint unsigned rob_idx;
      bit precommit_trap;
      bit final_trap;
      int rc;
      if (!ob_vif.rob_commit_valid[lane])
        continue;
      rob_idx = ob_vif.rob_commit_rob_idx[lane];
      if (!allocated_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf("[BE] commit for unallocated rob=%0d", rob_idx));
      precommit_trap = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx)) != 0;
      rc = isa_dpi_commit_auto(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
      check_rc($sformatf("commitAuto rob=%0d", rob_idx), rc);
      getter.after_commit(full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          precommit_trap, final_trap);
      retire_count++;
      if ((retire_count % retire_print_interval) == 0)
        $display("[RETIRE] cycle=%0d pc=0x%016h tag=0x%0h trap=%0b",
                 cycle_count, ob_vif.rob_commit_pld[lane].pc,
                 full_tag_by_rob[rob_idx], final_trap);
      if (final_trap) begin
        trap_commit_consumed = 1'b1;
        clear_local_anchors();
      end else begin
        allocated_by_rob.delete(rob_idx);
        lsu_by_rob.delete(rob_idx);
        execute_started_by_rob.delete(rob_idx);
        pending_by_rob.delete(rob_idx);
        full_tag_by_rob.delete(rob_idx);
        allocation_order_by_rob.delete(rob_idx);
      end
    end
  endtask

  task automatic sample_trap_commit();
    // Kept as an explicit lifecycle hook; commit classification is performed
    // synchronously in observe_commits using the same entry and tag.
  endtask

  task automatic observe_flushes(output bit flush_event);
    logic [MOCK_FLUSH_ALL_DUP-1:0] rising_flush;
    bit rising_pflush;

    rising_flush = ob_vif.flush_all & ~last_flush_all;
    rising_pflush = ob_vif.pflush && !last_pflush && !(|ob_vif.flush_all);
    flush_event = (|ob_vif.flush_all) || rising_pflush;
    if (|rising_flush) begin
      if (!trap_commit_consumed)
        check_rc("flushAll", isa_dpi_flush_all(MODEL_CORE_ID));
      trap_commit_consumed = 1'b0;
      clear_local_anchors();
      getter.flush_local();
    end else if (rising_pflush) begin
      if (allocated_by_rob.num() != 0) begin
        logic [DPI_ROB_IDX_W-1:0] first_younger;
        first_younger = '0;
        first_younger[MOCK_ROB_SLOT_W-1:0] =
            (ob_vif.pflush_rob_idx[MOCK_ROB_SLOT_W-1:0] + 1'b1);
        check_rc($sformatf("flush younger than rob=%0d", ob_vif.pflush_rob_idx),
                 isa_dpi_flush(MODEL_CORE_ID, first_younger));
      end
      clear_local_anchors();
      getter.flush_local();
    end
    last_flush_all = ob_vif.flush_all;
    last_pflush = ob_vif.pflush;
  endtask

  task run();
    wait_for_model();
    if (!model_ready)
      return;
    forever begin
      bit flush_event;
      bit model_to_exit;
      @(negedge ob_vif.clk);
      if (stop_requested)
        return;
      cycle_count++;
      getter.retire_responses();
      sample_trap_commit();
      observe_flushes(flush_event);
      if (!flush_event) begin
        getter.service_lsu_metadata();
        retry_pending_execution();
        observe_allocations();
        observe_execution_writebacks();
        observe_commits();
      end
      isa_dpi_tick_finish(1'b1);
      model_to_exit = isa_dpi_is_to_exit() != 0;
      ob_vif.dpi_be_phase_seq++;
      if (model_to_exit)
        return;
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask
endclass
