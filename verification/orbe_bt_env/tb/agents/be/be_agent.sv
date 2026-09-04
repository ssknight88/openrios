// Backend observer and sole BE-side owner of decode/execute/commit/recovery DPI.
class be_agent;
  localparam int unsigned MODEL_CORE_ID = 0;
  localparam int unsigned DPI_ROB_IDX_W = MOCK_ROB_ADDR_W;

  virtual ob_if ob_vif;
  virtual ob_cosim_if #(MOCK_ISSUE_NUM, MOCK_ROB_ADDR_W) ob_cosim_vif;
  virtual orbe_fe_if fe_vif;
  be_config cfg;
  be_getter getter;
  mailbox #(cosim_commit_event_t) cosim_commit_events;
  mailbox #(cosim_arch_state_event_t) cosim_arch_state_events;
  bit stop_requested;
  bit model_ready;

  bit allocated_by_rob[longint unsigned];
  bit lsu_by_rob[longint unsigned];
  bit execute_started_by_rob[longint unsigned];
  bit pending_by_rob[longint unsigned];
  logic [MOCK_ROB_TAG_W-1:0] full_tag_by_rob[longint unsigned];
  longint unsigned pc_by_rob[longint unsigned];
  longint unsigned allocation_order_by_rob[longint unsigned];
  longint unsigned next_allocation_order;

  bit last_redirect_valid;
  bit last_recovery_valid;
  bit trap_commit_consumed;
  longint unsigned cycle_count;
  longint unsigned retire_count;
  longint unsigned retire_print_interval;
  bit mem_store_observation_seen;
  longint unsigned last_mem_store_order;

  function new(virtual ob_if ob_vif, virtual orbe_fe_if fe_vif,
               virtual getter_if getter_vif,
               virtual ob_cosim_if #(MOCK_ISSUE_NUM, MOCK_ROB_ADDR_W) ob_cosim_vif,
               mailbox #(cosim_commit_event_t) cosim_commit_events,
               mailbox #(cosim_arch_state_event_t) cosim_arch_state_events,
               be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[BE] be_agent requires be_config");
    this.ob_vif = ob_vif;
    this.ob_cosim_vif = ob_cosim_vif;
    this.fe_vif = fe_vif;
    this.cosim_commit_events = cosim_commit_events;
    this.cosim_arch_state_events = cosim_arch_state_events;
    this.cfg = cfg;
    if (cosim_commit_events == null)
      be_reporter::fatal_static("[BE] be_agent requires COSIM commit event mailbox");
    if (cosim_arch_state_events == null)
      be_reporter::fatal_static("[BE] be_agent requires COSIM architectural state mailbox");
    getter = new(getter_vif, cfg);
    stop_requested = 1'b0;
    model_ready = 1'b0;
    last_redirect_valid = 1'b0;
    last_recovery_valid = 1'b0;
    trap_commit_consumed = 1'b0;
    cycle_count = 0;
    retire_count = 0;
    retire_print_interval = 1;
    mem_store_observation_seen = 1'b0;
    last_mem_store_order = 0;
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

  function automatic bit recovery_kind_known(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT,
      ORBE_RECOVERY_EXCEPTION,
      ORBE_RECOVERY_MRET,
      ORBE_RECOVERY_INTERRUPT,
      ORBE_RECOVERY_FENCE_I,
      ORBE_RECOVERY_SRET:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  function automatic string recovery_kind_name(
      input orbe_recovery_kind_e kind);
    case (kind)
      ORBE_RECOVERY_MISPREDICT: return "mispredict";
      ORBE_RECOVERY_EXCEPTION:  return "exception";
      ORBE_RECOVERY_MRET:       return "mret";
      ORBE_RECOVERY_INTERRUPT:  return "interrupt";
      ORBE_RECOVERY_FENCE_I:    return "fence_i";
      ORBE_RECOVERY_SRET:       return "sret";
      default:                  return "reserved";
    endcase
  endfunction

  task automatic check_rc(input string operation, input int rc);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[BE] %s failed rc=%0d", operation, rc));
  endtask

  task automatic refresh_mock_cosim_arf_observation();
`ifdef ORBE_DUT_RTL_V1
    return;
`else
    // MOCK_RTL has no independently implemented architectural register file.
    // After the BE-side shared model has consumed all commits for this cycle,
    // mirror its committed state into the observation boundary. This makes
    // the MOCK run an end-to-end transport/ordering test only; real RTL must
    // replace this task's producer with its own INT/FP ARF observation nets.
    if (!cfg.cosim_enable || ob_cosim_vif.rst_n !== 1'b1)
      return;
    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      ob_cosim_vif.int_arf[index] = isa_dpi_get_gpr(MODEL_CORE_ID, index);
      ob_cosim_vif.fp_arf[index] = isa_dpi_get_fpr(MODEL_CORE_ID, index);
    end
`endif
  endtask

  task automatic publish_cosim_arch_state_observation();
    cosim_arch_state_event_t state_event;

    if (!cfg.cosim_enable)
      return;
    if (ob_cosim_vif.rst_n !== 1'b1)
      return;
    if (ob_cosim_vif.csr_valid !== 1'b0 &&
        ob_cosim_vif.csr_valid !== 1'b1)
      cfg.reporter.fatal("[BE][COSIM] csr_valid is X/Z");

    for (int index = 0; index < COSIM_ARF_REG_NUM; index++) begin
      if (^ob_cosim_vif.int_arf[index] === 1'bx ||
          ^ob_cosim_vif.fp_arf[index] === 1'bx)
        cfg.reporter.fatal($sformatf(
            "[BE][COSIM] ARF observation contains X/Z index=%0d", index));
      state_event.int_arf[index] = ob_cosim_vif.int_arf[index];
      state_event.fp_arf[index] = ob_cosim_vif.fp_arf[index];
    end

    state_event.csr_valid = ob_cosim_vif.csr_valid;
    state_event.csr_state_valid = ob_cosim_vif.csr_state_valid;
    state_event.csr_state_addr = ob_cosim_vif.csr_state_addr;
    state_event.csr_state = ob_cosim_vif.csr_state;
    state_event.csr_event_valid = ob_cosim_vif.csr_event_valid;
    state_event.csr_event_addr = ob_cosim_vif.csr_event_addr;
    state_event.csr_event_wdata = ob_cosim_vif.csr_event_wdata;
    state_event.csr_event_rdata = ob_cosim_vif.csr_event_rdata;

    if (state_event.csr_valid === 1'b1) begin
      for (int index = 0; index < COSIM_CSR_STATE_NUM; index++) begin
        if (state_event.csr_state_valid[index] !== 1'b0 &&
            state_event.csr_state_valid[index] !== 1'b1)
          cfg.reporter.fatal($sformatf(
              "[BE][COSIM] csr_state_valid[%0d] is X/Z", index));
        if (state_event.csr_state_valid[index] === 1'b1 &&
            (^state_event.csr_state_addr[index] === 1'bx ||
             ^state_event.csr_state[index] === 1'bx))
          cfg.reporter.fatal($sformatf(
              "[BE][COSIM] valid CSR entry contains X/Z index=%0d", index));
      end
    end

    if (state_event.csr_event_valid !== 1'b0 &&
        state_event.csr_event_valid !== 1'b1)
      cfg.reporter.fatal("[BE][COSIM] csr_event_valid is X/Z");
    if (state_event.csr_event_valid === 1'b1 &&
        (^state_event.csr_event_addr === 1'bx ||
         ^state_event.csr_event_wdata === 1'bx ||
         ^state_event.csr_event_rdata === 1'bx))
      cfg.reporter.fatal("[BE][COSIM] valid CSR event contains X/Z");

    cosim_arch_state_events.put(state_event);
  endtask

  task automatic wait_for_model();
    while (!stop_requested) begin
      @(negedge ob_vif.clk);
      if (isa_dpi_is_config_ready()) begin
        model_ready = 1'b1;
        cfg.print_be(1, $sformatf("[BE][MODEL_READY] cycle=%0d model_ready=1",
                                  cycle_count));
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
    pc_by_rob.delete();
    allocation_order_by_rob.delete();
  endtask

  // Sample the product-neutral COSIM boundary and hand structured events to
  // the adapter. The adapter owns cycle and sequence counters.
  task automatic publish_cosim_commit_event(input int unsigned group,
                                            input longint unsigned pc,
                                            input longint unsigned rob_idx);
    cosim_commit_event_t commit_event;

    if (!cfg.cosim_enable)
      return;
    commit_event.group = group;
    commit_event.kind = COSIM_EVENT_COMMIT;
    commit_event.pc = pc;
    commit_event.rob_idx = rob_idx;
    commit_event.order = '0;
    commit_event.vaddr = '0;
    commit_event.data = '0;
    commit_event.mask = '0;
    commit_event.terminal = 1'b0;
    cosim_commit_events.put(commit_event);
  endtask

  task automatic publish_cosim_commit_observation();
    bit group_gap_seen;
    longint unsigned rob_idx;

    group_gap_seen = 1'b0;
    if (!cfg.cosim_enable)
      return;
    if (ob_cosim_vif.rst_n !== 1'b1)
      return;
    for (int group = 0; group < MOCK_ISSUE_NUM; group++) begin
      if (ob_cosim_vif.commit_valid[group] !== 1'b0 &&
          ob_cosim_vif.commit_valid[group] !== 1'b1)
        cfg.reporter.fatal($sformatf(
            "[BE][COSIM] commit_valid group=%0d is X/Z", group));
      if (ob_cosim_vif.commit_valid[group] !== 1'b1) begin
        group_gap_seen = 1'b1;
        continue;
      end
      if (group_gap_seen)
        cfg.reporter.fatal($sformatf(
            "[BE][COSIM] group=%0d commit is valid after an invalid earlier group",
            group));
      if (^ob_cosim_vif.commit_pc[group] === 1'bx ||
          ^ob_cosim_vif.commit_rob_idx[group] === 1'bx)
        cfg.reporter.fatal($sformatf(
            "[BE][COSIM] group=%0d commit observation contains X/Z", group));
      rob_idx = '0;
      rob_idx[MOCK_ROB_ADDR_W-1:0] = ob_cosim_vif.commit_rob_idx[group];
      publish_cosim_commit_event(group, ob_cosim_vif.commit_pc[group], rob_idx);
    end
  endtask

  task automatic publish_cosim_mem_observation();
    cosim_commit_event_t mem_event;
    bit terminal_store;

    if (ob_cosim_vif.rst_n !== 1'b1 ||
        ob_cosim_vif.mem_store_commit_valid !== 1'b1)
      return;
    if (^ob_cosim_vif.mem_store_commit_order === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_vaddr === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_data === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_mask === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_pc === 1'bx ||
        ^ob_cosim_vif.mem_store_commit_rob_idx === 1'bx)
      cfg.reporter.fatal(
          "[BE][COSIM] memory store observation contains X/Z");

    if (mem_store_observation_seen &&
        (ob_cosim_vif.mem_store_commit_order == last_mem_store_order))
      return;
    mem_store_observation_seen = 1'b1;
    last_mem_store_order = ob_cosim_vif.mem_store_commit_order;

    // Some ISA model builds recognize a tohost write in storeCommit and some
    // only latch the exit state at tick_finish. Re-check the shared model at
    // the BE sampling boundary so the terminal store is marked consistently.
    terminal_store = ob_cosim_vif.mem_store_commit_terminal ||
                     (isa_dpi_is_to_exit() != 0);
    mem_event.kind = COSIM_EVENT_MEM_STORE;
    mem_event.group = '0;
    mem_event.pc = ob_cosim_vif.mem_store_commit_pc;
    mem_event.rob_idx = ob_cosim_vif.mem_store_commit_rob_idx;
    mem_event.order = ob_cosim_vif.mem_store_commit_order;
    mem_event.vaddr = ob_cosim_vif.mem_store_commit_vaddr;
    mem_event.data = ob_cosim_vif.mem_store_commit_data;
    mem_event.mask = ob_cosim_vif.mem_store_commit_mask;
    mem_event.terminal = terminal_store;
    cosim_commit_events.put(mem_event);
    // Cache owns production of the record. Once this sampler has copied it
    // into the structured event mailbox, clear the boundary so the next
    // cache phase can publish a new store event.
    ob_cosim_vif.mem_store_commit_valid = 1'b0;
    ob_cosim_vif.mem_store_commit_terminal = 1'b0;
  endtask

  task automatic publish_cosim_dut_exit_observation();
    cosim_commit_event_t exit_event;

    exit_event.kind = COSIM_EVENT_DUT_EXIT;
    exit_event.group = '0;
    exit_event.pc = '0;
    exit_event.rob_idx = '0;
    exit_event.order = '0;
    exit_event.vaddr = '0;
    exit_event.data = '0;
    exit_event.mask = '0;
    exit_event.terminal = 1'b1;
    cosim_commit_events.put(exit_event);
  endtask

  task automatic publish_cosim_cycle_end_observation();
    cosim_commit_event_t end_event;

    if (!cfg.cosim_enable)
      return;
    end_event.kind = COSIM_EVENT_CYCLE_END;
    end_event.group = '0;
    end_event.pc = '0;
    end_event.rob_idx = '0;
    end_event.order = '0;
    end_event.vaddr = '0;
    end_event.data = '0;
    end_event.mask = '0;
    end_event.terminal = 1'b0;
    cosim_commit_events.put(end_event);
  endtask

  task automatic observe_allocations();
    longint unsigned rob_idx;
    longint signed insn_id;
    bit getter_is_lsu;
    int trap_rc;

    if (ob_vif.recovery_valid || ob_vif.alloc_valid == '0)
      return;
    for (int group = 0; group < MOCK_ISSUE_NUM; group++) begin
      if (!ob_vif.alloc_valid[group])
        continue;
      rob_idx = ob_vif.alloc_tag[group];
      insn_id = isa_dpi_decode_and_issue(
          MODEL_CORE_ID, dpi_rob_idx(rob_idx), ob_vif.alloc_pld[group].pc,
          ob_vif.alloc_pld[group].inst_bits,
          ob_vif.alloc_pld[group].is_compressed);
      if (insn_id == ISA_API_INVALID_INSN_ID)
        cfg.reporter.fatal($sformatf(
            "[BE] decodeAndIssue lost anchor group=%0d rob=%0d pc=0x%016h inst=0x%08h compressed=%0b",
            group, rob_idx, ob_vif.alloc_pld[group].pc,
            ob_vif.alloc_pld[group].inst_bits,
            ob_vif.alloc_pld[group].is_compressed));
      if (ob_vif.alloc_pld[group].fetch_excp_vld) begin
        trap_rc = isa_dpi_trigger_trap(
            MODEL_CORE_ID, dpi_rob_idx(rob_idx),
            ob_vif.alloc_pld[group].exception_cause,
            ob_vif.alloc_pld[group].exception_tval);
        cfg.print_be(2, $sformatf(
            "[BE][FETCH_TRAP] cycle=%0d group=%0d rob=%0d pc=0x%016h cause=%0d tval=0x%016h rc=%0d",
            cycle_count, group, rob_idx, ob_vif.alloc_pld[group].pc,
            ob_vif.alloc_pld[group].exception_cause,
            ob_vif.alloc_pld[group].exception_tval, trap_rc));
        check_rc($sformatf("triggerTrap rob=%0d", rob_idx), trap_rc);
      end
      full_tag_by_rob[rob_idx] = ob_vif.alloc_tag[group][MOCK_ROB_TAG_W-1:0];
      getter.after_decode(group, full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          getter_is_lsu);
      allocated_by_rob[rob_idx] = 1'b1;
      lsu_by_rob[rob_idx] = getter_is_lsu;
      execute_started_by_rob.delete(rob_idx);
      pending_by_rob.delete(rob_idx);
      pc_by_rob[rob_idx] = ob_vif.alloc_pld[group].pc;
      allocation_order_by_rob[rob_idx] = next_allocation_order++;
      cfg.print_be(2, $sformatf(
          "[BE][DECODE] cycle=%0d group=%0d order=%0d tag=0x%0h rob=%0d id=%0d pc=0x%016h inst=0x%08h compressed=%0b lsu=%0b fetch_excp=%0b",
          cycle_count, group, allocation_order_by_rob[rob_idx],
          full_tag_by_rob[rob_idx], rob_idx, insn_id,
          ob_vif.alloc_pld[group].pc, ob_vif.alloc_pld[group].inst_bits,
          ob_vif.alloc_pld[group].is_compressed, getter_is_lsu,
          ob_vif.alloc_pld[group].fetch_excp_vld));
    end
  endtask

  task automatic finish_execute(input longint unsigned rob_idx, input int rc,
                                input string operation);
    bit trap_valid;
    if (rc == ISA_API_PENDING) begin
      pending_by_rob[rob_idx] = 1'b1;
      cfg.print_be(2, $sformatf(
          "[BE][EXECUTE_PENDING] cycle=%0d rob=%0d tag=0x%0h operation=%s rc=%0d",
          cycle_count, rob_idx, full_tag_by_rob[rob_idx], operation, rc));
      return;
    end
    trap_valid = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx)) != 0;
    if (trap_valid)
      cfg.print_be(2, $sformatf(
          "[BE][EXECUTE_TRAP] cycle=%0d rob=%0d tag=0x%0h operation=%s rc=%0d trap_valid=1",
          cycle_count, rob_idx, full_tag_by_rob[rob_idx], operation, rc));
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
      if (!ob_vif.exec_valid[source])
        continue;
      rob_idx = ob_vif.exec_tag[source];
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
    for (int group = 0; group < MOCK_ISSUE_NUM; group++) begin
      longint unsigned rob_idx;
      bit precommit_trap;
      bit final_trap;
      int rc;
      if (!ob_vif.commit_valid[group])
        continue;
      rob_idx = ob_vif.commit_tag[group];
      if (!allocated_by_rob.exists(rob_idx))
        cfg.reporter.fatal($sformatf("[BE] commit for unallocated rob=%0d", rob_idx));
      precommit_trap = isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(rob_idx)) != 0;
      rc = isa_dpi_commit_auto(MODEL_CORE_ID, dpi_rob_idx(rob_idx));
      check_rc($sformatf("commitAuto rob=%0d", rob_idx), rc);
      getter.after_commit(full_tag_by_rob[rob_idx], dpi_rob_idx(rob_idx),
                          precommit_trap, final_trap);
      retire_count++;
      if ((retire_count % retire_print_interval) == 0)
        cfg.print_be(2, $sformatf(
            "[BE][COMMIT] cycle=%0d group=%0d retire=%0d rob=%0d tag=0x%0h pc=0x%016h rc=%0d precommit_trap=%0b final_trap=%0b",
            cycle_count, group, retire_count, rob_idx, full_tag_by_rob[rob_idx],
            ob_vif.commit_pc[group], rc, precommit_trap, final_trap));
      if (final_trap) begin
        trap_commit_consumed = 1'b1;
        clear_local_anchors();
      end else begin
        allocated_by_rob.delete(rob_idx);
        lsu_by_rob.delete(rob_idx);
        execute_started_by_rob.delete(rob_idx);
        pending_by_rob.delete(rob_idx);
        full_tag_by_rob.delete(rob_idx);
        pc_by_rob.delete(rob_idx);
        allocation_order_by_rob.delete(rob_idx);
      end
    end
  endtask

  task automatic sample_trap_commit();
    // Kept as an explicit lifecycle hook; commit classification is performed
    // synchronously in observe_commits using the same entry and tag.
  endtask

  task automatic observe_recoveries(output bit recovery_event);
    bit rising_recovery;
    int rc;
    bit precommit_trap;
    bit final_trap;
    longint unsigned origin_rob_idx;
    longint unsigned squash_rob_idx;
    int unsigned anchors_before;

    if (ob_vif.recovery_valid !== 1'b0 &&
        ob_vif.recovery_valid !== 1'b1)
      cfg.reporter.fatal("[BE][RECOVERY] recovery_valid is X/Z");
    recovery_event = ob_vif.recovery_valid === 1'b1;
    rising_recovery = recovery_event && !last_recovery_valid;
    anchors_before = allocated_by_rob.num();

    if (rising_recovery) begin
      if (^ob_vif.recovery_kind === 1'bx ||
          ^ob_vif.recovery_origin_tag === 1'bx ||
          ^ob_vif.recovery_squash_tag === 1'bx ||
          ^ob_vif.recovery_redirect_pc === 1'bx)
        cfg.reporter.fatal("[BE][RECOVERY] recovery observation contains X/Z");
      if (!recovery_kind_known(ob_vif.recovery_kind))
        cfg.reporter.fatal($sformatf(
            "[BE][RECOVERY] reserved recovery kind value=%0d",
            ob_vif.recovery_kind));

      origin_rob_idx = ob_vif.recovery_origin_tag;
      squash_rob_idx = ob_vif.recovery_squash_tag;

      if (ob_vif.recovery_kind == ORBE_RECOVERY_INTERRUPT) begin
        cfg.reporter.fatal(
            "[BE][RECOVERY_INTERRUPT] unsupported until interrupt cause observation is wired");
      end else if (ob_vif.recovery_kind == ORBE_RECOVERY_EXCEPTION) begin
        if (trap_commit_consumed) begin
          cfg.print_be(2, $sformatf(
              "[BE][RECOVERY_EXCEPTION] cycle=%0d origin=%0d anchors_before=%0d already_consumed_by_commit=1",
              cycle_count, origin_rob_idx, anchors_before));
        end else begin
          if (!allocated_by_rob.exists(origin_rob_idx))
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] exception recovery for unallocated rob=%0d",
                origin_rob_idx));
          precommit_trap =
              isa_dpi_has_trap(MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx)) != 0;
          if (!precommit_trap)
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] rob=%0d has no shared-model trap record",
                origin_rob_idx));
          rc = isa_dpi_commit_auto(MODEL_CORE_ID, dpi_rob_idx(origin_rob_idx));
          check_rc($sformatf("commitAuto exception rob=%0d", origin_rob_idx), rc);
          getter.after_commit(full_tag_by_rob[origin_rob_idx],
                              dpi_rob_idx(origin_rob_idx),
                              precommit_trap, final_trap);
          if (!final_trap)
            cfg.reporter.fatal($sformatf(
                "[BE][RECOVERY_EXCEPTION] commitAuto rob=%0d did not consume a trap",
                origin_rob_idx));
          retire_count++;
          publish_cosim_commit_event(0, pc_by_rob[origin_rob_idx],
                                     origin_rob_idx);
          cfg.print_be(2, $sformatf(
              "[BE][RECOVERY_EXCEPTION] cycle=%0d retire=%0d rob=%0d tag=0x%0h redirect_pc=0x%016h rc=%0d",
              cycle_count, retire_count, origin_rob_idx,
              full_tag_by_rob[origin_rob_idx], ob_vif.recovery_redirect_pc,
              rc));
        end
        trap_commit_consumed = 1'b0;
        clear_local_anchors();
        getter.flush_local();
      end else begin
        rc = ISA_API_PASS;
        if (allocated_by_rob.num() != 0) begin
          rc = isa_dpi_flush(MODEL_CORE_ID, dpi_rob_idx(squash_rob_idx));
          check_rc($sformatf("flush from rob=%0d kind=%s",
                             squash_rob_idx,
                             recovery_kind_name(ob_vif.recovery_kind)), rc);
        end
        cfg.print_be(2, $sformatf(
            "[BE][RECOVERY_FLUSH] cycle=%0d kind=%s origin=%0d squash=%0d redirect_pc=0x%016h commits_origin=%0b anchors_before=%0d rc=%0d",
            cycle_count, recovery_kind_name(ob_vif.recovery_kind),
            origin_rob_idx, squash_rob_idx, ob_vif.recovery_redirect_pc,
            recovery_commits_origin(ob_vif.recovery_kind), anchors_before, rc));
        trap_commit_consumed = 1'b0;
        clear_local_anchors();
        getter.flush_local();
      end
    end
    last_recovery_valid = recovery_event;
  endtask

  task automatic observe_redirects();
    if (ob_vif.recovery_valid && !last_redirect_valid)
      cfg.print_be(2, $sformatf(
          "[BE][REDIRECT] cycle=%0d kind=%s redirect_pc=0x%016h anchors=%0d",
          cycle_count, recovery_kind_name(ob_vif.recovery_kind),
          ob_vif.recovery_redirect_pc, allocated_by_rob.num()));
    last_redirect_valid = ob_vif.recovery_valid;
  endtask

  task run();
    wait_for_model();
    if (!model_ready)
      return;
    cfg.print_be(1, $sformatf("[BE][START] cycle=%0d", cycle_count));
    forever begin
      bit recovery_event;
      bit model_to_exit;
      @(negedge ob_vif.clk);
      if (stop_requested)
        return;
      cycle_count++;
      publish_cosim_commit_observation();
      publish_cosim_mem_observation();
      getter.retire_responses();
      sample_trap_commit();
      observe_redirects();
      getter.service_lsu_metadata();
      retry_pending_execution();
      observe_execution_writebacks();
      observe_commits();
      observe_recoveries(recovery_event);
      if (!recovery_event && !trap_commit_consumed)
        observe_allocations();
      isa_dpi_tick_finish(1'b1);
      model_to_exit = isa_dpi_is_to_exit() != 0;
      ob_vif.dpi_be_phase_seq++;
      if (model_to_exit) begin
        publish_cosim_dut_exit_observation();
        publish_cosim_cycle_end_observation();
        refresh_mock_cosim_arf_observation();
        // The final post-commit architectural state must be published before
        // the BE worker returns, otherwise the COSIM adapter can block forever
        // waiting for the last snapshot.
        publish_cosim_arch_state_observation();
        cfg.print_be(1, $sformatf(
            "[BE][EXIT] cycle=%0d retire_count=%0d", cycle_count, retire_count));
        return;
      end
      publish_cosim_cycle_end_observation();
      refresh_mock_cosim_arf_observation();
      // Put the state snapshot after the exit marker, when present. The
      // adapter blocks on this mailbox, so all events for this cycle are
      // visible before it drains the commit mailbox.
      publish_cosim_arch_state_observation();
    end
  endtask

  task shutdown();
    stop_requested = 1'b1;
  endtask
endclass
