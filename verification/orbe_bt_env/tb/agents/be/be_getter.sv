class be_getter;
  localparam int unsigned MODEL_CORE_ID = 0;

  virtual getter_if vif;
  be_config cfg;

  function new(virtual getter_if vif, be_config cfg);
    if (cfg == null)
      be_reporter::fatal_static("[GETTER] be_getter requires be_config");
    this.vif = vif;
    this.cfg = cfg;
    vif.decode_rsp_valid = '0;
    vif.decode_rsp_tag = '0;
    vif.decode_rsp_is_lsu = '0;
    vif.decode_rsp_exception = '0;
    vif.decode_rsp_cause = '{default:'0};
    vif.decode_rsp_tval = '0;
    vif.lsu_meta_req_ready = 1'b0;
    vif.lsu_meta_rsp_valid = 1'b0;
    vif.lsu_meta_rsp_tag = '0;
    vif.lsu_meta_rsp_pld = '0;
    vif.execute_rsp_valid = 1'b0;
    vif.execute_rsp_tag = '0;
    vif.execute_rsp_exception = 1'b0;
    vif.execute_rsp_redirect = 1'b0;
    vif.execute_rsp_next_pc = '0;
    vif.execute_rsp_cause = '0;
    vif.execute_rsp_tval = '0;
    vif.commit_rsp_valid = 1'b0;
    vif.commit_rsp_tag = '0;
    vif.commit_rsp_trap = 1'b0;
    vif.commit_rsp_cause = '0;
    vif.commit_rsp_tval = '0;
    vif.commit_rsp_redirect_pc = '0;
  endfunction

  function automatic logic [23:0] canonical_exe_subop(input logic [23:0] raw);
    logic [23:0] canonical;
    canonical = raw;
    if (raw[23:22] == 2'b10) begin
      // The ISA model encodes RVC {funct3, op} in opcode_or_op;
      // OR-BE encodes only the compressed quadrant op in that field.
      canonical[21:17] = 5'b0;
      canonical[11:0] = 12'b0;
    end
    return canonical;
  endfunction

  task automatic retire_responses();
    for (int lane = 0; lane < MOCK_ISSUE_NUM; lane++)
      if (vif.decode_rsp_valid[lane] && vif.decode_rsp_ready[lane])
        vif.decode_rsp_valid[lane] = 1'b0;
    if (vif.lsu_meta_rsp_valid && vif.lsu_meta_rsp_ready)
      vif.lsu_meta_rsp_valid = 1'b0;
    if (vif.execute_rsp_valid && vif.execute_rsp_ready)
      vif.execute_rsp_valid = 1'b0;
    if (vif.commit_rsp_valid)
      vif.commit_rsp_valid = 1'b0;
    vif.lsu_meta_req_ready = !vif.lsu_meta_rsp_valid;
  endtask

  task automatic flush_local();
    vif.decode_rsp_valid = '0;
    vif.lsu_meta_rsp_valid = 1'b0;
    vif.execute_rsp_valid = 1'b0;
    vif.commit_rsp_valid = 1'b0;
    vif.lsu_meta_req_ready = 1'b1;
  endtask

  task automatic after_decode(
      input int unsigned lane,
      input logic [MOCK_ROB_TAG_W-1:0] full_tag,
      input logic [MOCK_ROB_ADDR_W-1:0] model_rob_idx,
      output bit getter_is_lsu);
    byte unsigned is_lsu;
    byte unsigned trap_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    int rc;

    if (lane >= MOCK_ISSUE_NUM)
      cfg.reporter.fatal("[GETTER] decode lane out of range");
    if (vif.decode_rsp_valid[lane])
      cfg.reporter.fatal($sformatf("[GETTER] decode lane %0d response overwritten", lane));
    rc = isa_dpi_get_decode_metadata(MODEL_CORE_ID, model_rob_idx,
                                     is_lsu, trap_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_decode_metadata rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    getter_is_lsu = is_lsu != 0;
    vif.decode_rsp_tag[lane] = full_tag;
    vif.decode_rsp_is_lsu[lane] = getter_is_lsu;
    vif.decode_rsp_exception[lane] = trap_valid != 0;
    vif.decode_rsp_cause[lane] = exception_cause_t'(trap_cause[4:0]);
    vif.decode_rsp_tval[lane] = trap_tval;
    vif.decode_rsp_valid[lane] = 1'b1;
  endtask

  task automatic service_lsu_metadata();
    byte unsigned req_property;
    int unsigned exe_subop;
    byte unsigned mem_funct3;
    byte unsigned rd_is_fp;
    longint unsigned rs1_data;
    longint unsigned rs2_data;
    byte unsigned imm_valid;
    longint signed imm_data;
    byte unsigned is_store;
    int rc;
    logic [MOCK_ROB_TAG_W-1:0] tag;

    vif.lsu_meta_req_ready = !vif.lsu_meta_rsp_valid;
    if (!vif.lsu_meta_req_valid || !vif.lsu_meta_req_ready)
      return;
    tag = vif.lsu_meta_req_tag;
    rc = isa_dpi_get_lsu_issue_metadata(
        MODEL_CORE_ID, {{(64-MOCK_ROB_SLOT_W){1'b0}}, tag[MOCK_ROB_SLOT_W-1:0]},
        req_property, exe_subop, mem_funct3, rd_is_fp,
        rs1_data, rs2_data, imm_valid, imm_data, is_store);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_lsu_issue_metadata tag=0x%0h rc=%0d",
                                   tag, rc));
    vif.lsu_meta_rsp_tag = tag;
    vif.lsu_meta_rsp_pld.req_property = lsu_req_property_t'(req_property[6:0]);
    vif.lsu_meta_rsp_pld.exe_subop = canonical_exe_subop(exe_subop[23:0]);
    vif.lsu_meta_rsp_pld.mem_funct3 = mem_funct3[2:0];
    vif.lsu_meta_rsp_pld.rd_is_fp = rd_is_fp != 0;
    vif.lsu_meta_rsp_pld.rs1_data = rs1_data;
    vif.lsu_meta_rsp_pld.rs2_data = rs2_data;
    vif.lsu_meta_rsp_pld.imm_valid = imm_valid != 0;
    vif.lsu_meta_rsp_pld.imm_data = imm_data;
    vif.lsu_meta_rsp_pld.is_store = is_store != 0;
    vif.lsu_meta_rsp_valid = 1'b1;
    vif.lsu_meta_req_ready = 1'b0;
  endtask

  task automatic after_execute(
      input logic [MOCK_ROB_TAG_W-1:0] full_tag,
      input logic [MOCK_ROB_ADDR_W-1:0] model_rob_idx);
    byte unsigned trap_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    int rc;

    if (vif.execute_rsp_valid)
      cfg.reporter.fatal("[GETTER] execute response overwritten");
    rc = isa_dpi_get_execute_metadata(MODEL_CORE_ID, model_rob_idx,
                                      trap_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_execute_metadata rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    vif.execute_rsp_tag = full_tag;
    vif.execute_rsp_exception = trap_valid != 0;
    vif.execute_rsp_redirect = isa_dpi_is_insn_redirect(MODEL_CORE_ID, model_rob_idx) != 0;
    vif.execute_rsp_next_pc = isa_dpi_get_next_pc_of_insn(MODEL_CORE_ID, model_rob_idx);
    vif.execute_rsp_cause = exception_cause_t'(trap_cause[4:0]);
    vif.execute_rsp_tval = trap_tval;
    cfg.print_be(3, $sformatf(
        "[GETTER][EXECUTE] tag=0x%0h rob=%0d redirect=%0b next_pc=0x%016h trap=%0b",
        full_tag, model_rob_idx, vif.execute_rsp_redirect,
        vif.execute_rsp_next_pc, vif.execute_rsp_exception));
    vif.execute_rsp_valid = 1'b1;
  endtask

  task automatic after_commit(
      input logic [MOCK_ROB_TAG_W-1:0] full_tag,
      input logic [MOCK_ROB_ADDR_W-1:0] model_rob_idx,
      input bit precommit_trap,
      output bit final_trap);
    byte unsigned trap_record_valid;
    longint unsigned trap_cause;
    longint unsigned trap_tval;
    bit late_trap;
    int rc;

    if (vif.commit_rsp_valid)
      cfg.reporter.fatal("[GETTER] commit response overwritten");
    rc = isa_dpi_get_commit_auto_trap_info(MODEL_CORE_ID, model_rob_idx,
                                           trap_record_valid, trap_cause, trap_tval);
    if (rc != ISA_API_PASS)
      cfg.reporter.fatal($sformatf("[GETTER] get_commit_auto_trap_info rob=%0d rc=%0d",
                                   model_rob_idx, rc));
    final_trap = precommit_trap || (trap_record_valid != 0);
    late_trap = !precommit_trap && (trap_record_valid != 0);
    vif.commit_rsp_tag = full_tag;
    vif.commit_rsp_trap = late_trap;
    vif.commit_rsp_cause = exception_cause_t'(trap_cause[4:0]);
    vif.commit_rsp_tval = trap_tval;
    vif.commit_rsp_redirect_pc = final_trap
        ? isa_dpi_get_spec_pc(MODEL_CORE_ID) : 64'd0;
    vif.commit_rsp_valid = 1'b1;
  endtask
endclass
