`ifndef BACKEND_TOP_SV
`define BACKEND_TOP_SV

import orca_types::*;
import exe_subop_pkg::*;

module backend_top (
    input  logic        clk,
    input  logic        rst_n,

    // Frontend enqueue interface (into backend-owned ISB)
    input  isb_payload_t [1:0] frontend_payload,
    output logic [1:0]  frontend_enqueue_cnt,

    // LSU Interface - exposed for testbench-side fake LSU bring-up
    output logic        lsu_req_pending,
    output logic        en_lsu,
    output lsu_req_t    lsu_req,
    input  logic        lsu_busy,
    input  result_payload_t lsu_wb,
    input  logic        lsu_store_buffered,
    input  logic        agu_early_tag_valid,
    input  logic [TAG_W-1:0] agu_early_tag,
    input  logic        store_done_valid,
    input  logic [TAG_W-1:0] store_done_tag,
    input  logic        store_done_exception,
    input  logic [XLEN-1:0] store_done_cause,

    // Other FU Interfaces - still internalized for minimal bring-up
    /*
    // Group 0
    output logic        en_alu0, en_bru, en_div, en_csr,
    input  logic        alu0_busy, bru_busy, div_busy, csr_busy,
    input  result_payload_t alu0_wb, div_wb, bru_wb, csr_wb,
    // Group 1
    output logic        en_alu1, en_mul,
    input  logic        alu1_busy, mul_busy,
    input  result_payload_t alu1_wb, mul_wb,
    // Group 2
    output logic        en_fpu,
    input  logic        fpu_busy,
    input  result_payload_t fpu_wb,
    */

    // CSR File Interface
    output logic        csr_wr_en,
    output logic [11:0] csr_addr,
    output logic [XLEN-1:0] csr_wdata,
    input  logic [XLEN-1:0] csr_rdata, 
    output logic        csr_ie_enabled,

    // External Interrupt
    input  logic        ext_irq_valid,

    // Recovery Interface (to Frontend)
    output logic        global_flush_late,
    output logic [XLEN-1:0] flush_target_pc,
    output logic        reset_rob_pointers,
    output logic        clear_all_busy,
    output logic        clear_metaarray_flushvalid,
    output logic        clear_csr_trackers,

    // Store drain request
    output logic        store_drain_req_valid,
    output logic [TAG_W-1:0] store_drain_req_tag
);

    // --- Internal Signals ---
    
    // FU Interface Signals (Internalized for MBU)
    logic        en_alu0, en_bru, en_div, en_csr;
    logic        alu0_busy, bru_busy, div_busy, csr_busy;
    result_payload_t alu0_wb, div_wb, bru_wb, csr_wb;

    logic        en_alu1, en_mul;
    logic        alu1_busy, mul_busy;
    result_payload_t alu1_wb, mul_wb;

    logic        en_fpu;
    logic        fpu_busy;
    result_payload_t fpu_wb;

    logic [TAG_W-1:0] flush_head_adv;
    logic [TAG_W-1:0] flush_tag_p4;
    flush_kind_e flush_kind;

    // ISB (extracted to isb_fifo module)
    isb_payload_t [1:0] isb_payload;
    logic [1:0]  isb_dequeue;

    // ROB / SideArray
    logic [1:0] rob_alloc_valid;
    logic [1:0] rob_alloc_is_store;
    logic [TAG_W-1:0] slot0_tag, slot1_tag;
    logic rob_full, rob_empty;
    logic rob_can_alloc_1, rob_can_alloc_2;
    result_payload_t [3:0] group_wb_payload;
    logic [1:0] commit_ack;
    logic [TAG_W-1:0] head_ptr, head_plus_1;
    rob_head_status_t head0, head1;
    sidearray_entry_t flush_meta;

    logic        csr_mie_out;
    logic        csr_meie_out;
    logic        csr_fs_enabled;
    logic        p4_is_interrupt;
    logic [XLEN-1:0] csr_trap_pc;
    logic [XLEN-1:0] csr_trap_cause;
    logic [XLEN-1:0] csr_trap_tval;

    // DST_REG
    logic [3:0][REG_ADDR_W-1:0] int_dst_raddr;
    logic [3:0] int_dst_rbusy;
    logic [3:0][TAG_W-1:0] int_dst_rtag;
    logic [2:0][REG_ADDR_W-1:0] fp_dst_raddr;
    logic [2:0] fp_dst_rbusy;
    logic [2:0][TAG_W-1:0] fp_dst_rtag;
    logic [1:0] dst_alloc_valid_int;
    logic [1:0][REG_ADDR_W-1:0] dst_alloc_rd_int;
    logic [1:0][TAG_W-1:0] dst_alloc_tag_int;
    logic dst_alloc_valid_fp;
    logic [REG_ADDR_W-1:0] dst_alloc_rd_fp;
    logic [TAG_W-1:0] dst_alloc_tag_fp;
    commit_payload_t [1:0] commit_payload;

    // ARF
    logic [3:0][REG_ADDR_W-1:0] int_arf_raddr;
    logic [3:0][XLEN-1:0] int_arf_rdata;
    logic [2:0][REG_ADDR_W-1:0] fp_arf_raddr;
    logic [2:0][FLEN-1:0] fp_arf_rdata;
    commit_payload_t [0:0] fp_commit_payload;

    // ISQ
    logic [3:0] isq_wr_en;
    isq_payload_t [3:0] isq_wr_payload;
    logic [3:0] group_fu_busy;
    logic [3:0] isq_valid_bits;
    isq_payload_t [3:0] group_isq_payload;
    logic [3:0] issue_en;
    bypass_t [3:0] bypass_bus;

    // P1 Logic
    logic slot0_can_dispatch, slot1_can_dispatch;
    logic [EXE_TYPE_W-1:0] slot0_target_group, slot1_target_group;
    logic slot0_overlay_valid;
    logic slot0_rs1_ready, slot0_rs2_ready, slot0_rs3_ready;
    logic [XLEN-1:0] slot0_rs1_data, slot0_rs2_data, slot0_rs3_data;
    logic [TAG_W-1:0] slot0_rs1_tag, slot0_rs2_tag, slot0_rs3_tag;
    logic slot1_rs1_ready, slot1_rs2_ready, slot1_rs3_ready;
    logic [XLEN-1:0] slot1_rs1_data, slot1_rs2_data, slot1_rs3_data;
    logic [TAG_W-1:0] slot1_rs1_tag, slot1_rs2_tag, slot1_rs3_tag;
    logic slot0_stall, slot1_stall;

    // CSR Control
    logic csr_inflight_valid;
    logic [TAG_W-1:0] csr_inflight_tag;
    logic csr_pend_valid;
    logic [TAG_W-1:0] csr_pend_tag;
    logic [11:0] csr_pend_addr;
    logic [XLEN-1:0] csr_pend_wdata;
    logic p4_csr_retire;
    logic p4_csr_write;
    logic [XLEN-1:0] csr_mtvec_out;
    logic [2:0] csr_frm_out;
    logic [XLEN-1:0] csr_mepc_out;
    logic       p4_mret_retire;
    logic       fp_commit_valid;
    logic [4:0] fp_commit_fflags;

    logic [ROB_DEPTH-1:0] rob_done_bits;

    logic g0_sel_alu0, g0_sel_bru, g0_sel_div, g0_sel_csr;
    logic g1_sel_alu1, g1_sel_mul;
    logic group3_is_lsu;
    logic group3_fs_illegal_pending;
    logic lsu_fs_illegal_fire;
    logic g0_exec_wb_is_bru;
    result_payload_t g0_exec_wb;
    result_payload_t lsu_fs_wb;
    result_payload_t lsu_payload_to_p3;

    // ISB instance
    isb_fifo #(.DEPTH(8)) u_isb (
        .clk         (clk),
        .rst_n       (rst_n),
        .enq_payload (frontend_payload),
        .enq_valid   ({frontend_payload[1].inst_valid, frontend_payload[0].inst_valid}),
        .enq_accepted(frontend_enqueue_cnt),
        .deq_payload (isb_payload),
        .deq_valid   (isb_dequeue),
        .full        (),
        .flush_late  (global_flush_late)
    );

    // --- Module Instantiations ---

    rob u_rob (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(rob_alloc_valid),
        .alloc_is_store(rob_alloc_is_store),
        .alloc_tag_0(slot0_tag), .alloc_tag_1(slot1_tag),
        .rob_full(rob_full), .rob_empty(rob_empty),
        .rob_can_alloc_1(rob_can_alloc_1), .rob_can_alloc_2(rob_can_alloc_2),
        .wb_payload(group_wb_payload),
        .wb_store_buffered({lsu_store_buffered, 3'b000}),
        .store_drain_req_valid(store_drain_req_valid), .store_drain_req_tag(store_drain_req_tag),
        .store_done_valid(store_done_valid), .store_done_tag(store_done_tag), .store_done_exception(store_done_exception),
        .commit_ack(commit_ack), .head_ptr(head_ptr), .head_plus_1(head_plus_1),
        .head0(head0), .head1(head1),
        .rob_done_bits(rob_done_bits),
        .reset_rob_pointers(reset_rob_pointers), .flush_head_adv(flush_head_adv)
    );

    rob_sidearray u_sidearray (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(rob_alloc_valid), .alloc_tag_0(slot0_tag), .alloc_tag_1(slot1_tag),
        .alloc_pc({isb_payload[1].pc, isb_payload[0].pc}),
        .wb_valid({group_wb_payload[3].result_valid, group_wb_payload[2].result_valid, group_wb_payload[1].result_valid, group_wb_payload[0].result_valid}),
        .wb_payload(group_wb_payload),
        .store_done_valid(store_done_valid), .store_done_tag(store_done_tag),
        .store_done_exception(store_done_exception), .store_done_cause(store_done_cause),
        .flush_tag(flush_tag_p4),
        .flush_meta(flush_meta),
        .clear_metaarray_flushvalid(clear_metaarray_flushvalid)
    );

    dst_reg #(.NUM_READ_PORTS(4), .NUM_WRITE_PORTS(2), .IS_FP(0)) u_dst_int (
        .clk(clk), .rst_n(rst_n),
        .rs_idx(int_dst_raddr), .rs_busy(int_dst_rbusy), .rs_tag(int_dst_rtag),
        .alloc_valid(dst_alloc_valid_int), .alloc_rd_idx(dst_alloc_rd_int), .alloc_tag(dst_alloc_tag_int),
        .commit_payload(commit_payload),
        .clear_all_busy(clear_all_busy)
    );

    dst_reg #(.NUM_READ_PORTS(3), .NUM_WRITE_PORTS(1), .IS_FP(1)) u_dst_fp (
        .clk(clk), .rst_n(rst_n),
        .rs_idx(fp_dst_raddr), .rs_busy(fp_dst_rbusy), .rs_tag(fp_dst_rtag),
        .alloc_valid(dst_alloc_valid_fp), .alloc_rd_idx(dst_alloc_rd_fp), .alloc_tag(dst_alloc_tag_fp),
        .commit_payload(commit_payload),
        .clear_all_busy(clear_all_busy)
    );

    arf #(.NUM_READ_PORTS(4), .NUM_WRITE_PORTS(2), .IS_FP(0)) u_arf_int (
        .clk(clk), .rst_n(rst_n),
        .rs_idx(int_arf_raddr), .rs_data(int_arf_rdata),
        .commit_payload(commit_payload)
    );

    arf #(.NUM_READ_PORTS(3), .NUM_WRITE_PORTS(1), .IS_FP(1)) u_arf_fp (
        .clk(clk), .rst_n(rst_n),
        .rs_idx(fp_arf_raddr), .rs_data(fp_arf_rdata),
        .commit_payload(fp_commit_payload) 
    );

    always_comb begin
        fp_commit_payload = '0;

        if (commit_payload[0].commit_valid && commit_payload[0].rd_is_fp) begin
            fp_commit_payload[0] = commit_payload[0];
        end else if (commit_payload[1].commit_valid && commit_payload[1].rd_is_fp) begin
            fp_commit_payload[0] = commit_payload[1];
        end
    end

    // Issue Queues
    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : gen_isqs
            isq u_isq (
                .clk(clk), .rst_n(rst_n),
                .isq_wr_en(isq_wr_en[g]), .isq_wr_payload(isq_wr_payload[g]),
                .fu_busy(group_fu_busy[g]), .isq_valid(isq_valid_bits[g]), .isq_payload(group_isq_payload[g]),
                .issue_en(issue_en[g]), .bypass_bus(bypass_bus), .flush_late(global_flush_late)
            );
        end
    endgenerate

    // P1 Submodules
    assign slot0_overlay_valid = isb_payload[0].inst_valid &&
                                 slot0_can_dispatch &&
                                 isb_payload[0].use_rd;

    p1_source_resolution u_p1_src (
        .slot0_isb(isb_payload[0]), .slot1_isb(isb_payload[1]),
        .int_dst_raddr(int_dst_raddr), .int_dst_rbusy(int_dst_rbusy), .int_dst_rtag(int_dst_rtag),
        .int_arf_raddr(int_arf_raddr), .int_arf_rdata(int_arf_rdata),
        .fp_dst_raddr(fp_dst_raddr), .fp_dst_rbusy(fp_dst_rbusy), .fp_dst_rtag(fp_dst_rtag),
        .fp_arf_raddr(fp_arf_raddr), .fp_arf_rdata(fp_arf_rdata),
        .slot0_rs1_ready(slot0_rs1_ready), .slot0_rs1_data(slot0_rs1_data), .slot0_rs1_tag(slot0_rs1_tag),
        .slot0_rs2_ready(slot0_rs2_ready), .slot0_rs2_data(slot0_rs2_data), .slot0_rs2_tag(slot0_rs2_tag),
        .slot0_rs3_ready(slot0_rs3_ready), .slot0_rs3_data(slot0_rs3_data), .slot0_rs3_tag(slot0_rs3_tag),
        .slot0_overlay_valid(slot0_overlay_valid), .slot0_alloc_tag(slot0_tag),
        .slot1_rs1_ready(slot1_rs1_ready), .slot1_rs1_data(slot1_rs1_data), .slot1_rs1_tag(slot1_rs1_tag),
        .slot1_rs2_ready(slot1_rs2_ready), .slot1_rs2_data(slot1_rs2_data), .slot1_rs2_tag(slot1_rs2_tag),
        .slot1_rs3_ready(slot1_rs3_ready), .slot1_rs3_data(slot1_rs3_data), .slot1_rs3_tag(slot1_rs3_tag),
        .commit_payload(commit_payload)
    );

    p1_admission_and_backpressure u_p1_adm (
        .slot0_isb(isb_payload[0]),
        .slot1_isb(isb_payload[1]),
        .rob_full(rob_full), .rob_empty(rob_empty),
        .rob_can_alloc_1(rob_can_alloc_1), .rob_can_alloc_2(rob_can_alloc_2),
        .isq_valid(isq_valid_bits),
        .isq_issue_en(issue_en),
        .csr_inflight_valid(csr_inflight_valid),
        .slot0_can_dispatch(slot0_can_dispatch), .slot1_can_dispatch(slot1_can_dispatch),
        .slot0_target_group(slot0_target_group), .slot1_target_group(slot1_target_group),
        .isb_dequeue_cnt()
    );

    p1_deadlock_prevention u_p1_dl (
        .slot0_rs1_ready(slot0_rs1_ready), .slot0_rs1_tag(slot0_rs1_tag),
        .slot0_rs2_ready(slot0_rs2_ready), .slot0_rs2_tag(slot0_rs2_tag),
        .slot0_rs3_ready(slot0_rs3_ready), .slot0_rs3_tag(slot0_rs3_tag),
        .slot1_rs1_ready(slot1_rs1_ready), .slot1_rs1_tag(slot1_rs1_tag),
        .slot1_rs2_ready(slot1_rs2_ready), .slot1_rs2_tag(slot1_rs2_tag),
        .slot1_rs3_ready(slot1_rs3_ready), .slot1_rs3_tag(slot1_rs3_tag),
        .bypass_bus(bypass_bus),
        .rob_done_bits(rob_done_bits),
        .commit_payload(commit_payload),
        .agu_early_tag_valid(agu_early_tag_valid),
        .agu_early_tag(agu_early_tag),
        .slot0_stall(slot0_stall), .slot1_stall(slot1_stall)
    );

    p1_rob_allocation_and_isq_write u_p1_alloc (
        .slot0_isb(isb_payload[0]), .slot0_can_dispatch(slot0_can_dispatch), .slot0_stall(slot0_stall), .slot0_target_group(slot0_target_group),
        .slot1_isb(isb_payload[1]), .slot1_can_dispatch(slot1_can_dispatch), .slot1_stall(slot1_stall), .slot1_target_group(slot1_target_group),
        .flush_late(global_flush_late),
        .slot0_rs1_ready(slot0_rs1_ready), .slot0_rs1_data(slot0_rs1_data), .slot0_rs1_tag(slot0_rs1_tag),
        .slot0_rs2_ready(slot0_rs2_ready), .slot0_rs2_data(slot0_rs2_data), .slot0_rs2_tag(slot0_rs2_tag),
        .slot0_rs3_ready(slot0_rs3_ready), .slot0_rs3_data(slot0_rs3_data), .slot0_rs3_tag(slot0_rs3_tag),
        .slot1_rs1_ready(slot1_rs1_ready), .slot1_rs1_data(slot1_rs1_data), .slot1_rs1_tag(slot1_rs1_tag),
        .slot1_rs2_ready(slot1_rs2_ready), .slot1_rs2_data(slot1_rs2_data), .slot1_rs2_tag(slot1_rs2_tag),
        .slot1_rs3_ready(slot1_rs3_ready), .slot1_rs3_data(slot1_rs3_data), .slot1_rs3_tag(slot1_rs3_tag),
        .rob_tail(slot0_tag), 
        .rob_alloc_valid(rob_alloc_valid), .rob_alloc_is_store(rob_alloc_is_store),
        .dst_alloc_valid_int(dst_alloc_valid_int), .dst_alloc_rd_int(dst_alloc_rd_int), .dst_alloc_tag_int(dst_alloc_tag_int),
        .dst_alloc_valid_fp(dst_alloc_valid_fp), .dst_alloc_rd_fp(dst_alloc_rd_fp), .dst_alloc_tag_fp(dst_alloc_tag_fp),
        .isq_wr_en(isq_wr_en), .isq_wr_payload(isq_wr_payload)
    );

    // P2 Logic
    logic [3:0][XLEN-1:0] group_rs1, group_rs2, group_rs3;
    generate
        for (g = 0; g < 4; g++) begin : gen_p2_mux
            p2_fu_input_mux u_mux (
                .isq_payload(group_isq_payload[g]), .bypass_bus(bypass_bus),
                .rs1_source(group_rs1[g]), .rs2_source(group_rs2[g]), .rs3_source(group_rs3[g])
            );
        end
    endgenerate

    always_comb begin
        g0_sel_alu0 = is_g0_alu0(group_isq_payload[0].exe_subop);
        g0_sel_bru  = is_g0_bru(group_isq_payload[0].exe_subop);
        g0_sel_div  = is_g0_div(group_isq_payload[0].exe_subop);
        g0_sel_csr  = is_g0_csr(group_isq_payload[0].exe_subop);

        unique case (1'b1)
            g0_sel_alu0: group_fu_busy[0] = alu0_busy;
            g0_sel_bru : group_fu_busy[0] = bru_busy;
            g0_sel_div : group_fu_busy[0] = div_busy;
            g0_sel_csr : group_fu_busy[0] = csr_busy;
            default    : group_fu_busy[0] = 1'b1;
        endcase

        g1_sel_alu1 = is_g1_alu1(group_isq_payload[1].exe_subop);
        g1_sel_mul  = is_g1_mul(group_isq_payload[1].exe_subop);

        unique case (1'b1)
            g1_sel_alu1: group_fu_busy[1] = alu1_busy;
            g1_sel_mul : group_fu_busy[1] = mul_busy;
            default    : group_fu_busy[1] = 1'b1;
        endcase

        group_fu_busy[2] = is_g2_fpu(group_isq_payload[2].exe_subop) ? fpu_busy : 1'b1;
        group_fu_busy[3] = group3_is_lsu ? (group3_fs_illegal_pending ? 1'b0 : lsu_busy) : 1'b1;
    end

    assign en_alu0 = issue_en[0] && g0_sel_alu0;
    assign en_bru  = issue_en[0] && g0_sel_bru;
    assign en_div  = issue_en[0] && g0_sel_div;
    assign en_csr  = issue_en[0] && g0_sel_csr;
    assign en_alu1 = issue_en[1] && g1_sel_alu1;
    assign en_mul  = issue_en[1] && g1_sel_mul;
    assign en_fpu  = issue_en[2] && is_g2_fpu(group_isq_payload[2].exe_subop);
    assign group3_is_lsu = is_g3_lsu(group_isq_payload[3].exe_subop);
    assign group3_fs_illegal_pending = isq_valid_bits[3] && group3_is_lsu &&
                                       group_isq_payload[3].uses_fp_state &&
                                       !csr_fs_enabled;
    assign lsu_fs_illegal_fire = issue_en[3] && group3_fs_illegal_pending;
    assign lsu_req_pending = isq_valid_bits[3] && group3_is_lsu && !group3_fs_illegal_pending;
    assign en_lsu  = issue_en[3] && group3_is_lsu && !group3_fs_illegal_pending;

    always_comb begin
        lsu_req = '0;
        lsu_req.tag       = group_isq_payload[3].self_rob_tag;
        lsu_req.rd_idx    = group_isq_payload[3].rd_idx;
        lsu_req.rd_is_fp  = group_isq_payload[3].rd_is_fp;
        lsu_req.is_store  = group_isq_payload[3].is_store;
        lsu_req.is_load   = !group_isq_payload[3].is_store && is_g3_lsu(group_isq_payload[3].exe_subop);
        lsu_req.base_addr = group_rs1[3];
        lsu_req.imm_valid = group_isq_payload[3].imm_valid;
        lsu_req.imm_data  = group_isq_payload[3].imm_data;
        lsu_req.store_data = group_rs2[3];
        lsu_req.store_mask = group_isq_payload[3].store_mask;
        lsu_req.store_size = group_isq_payload[3].store_size;
    end

    always_comb begin
        lsu_fs_wb = '0;
        if (lsu_fs_illegal_fire) begin
            lsu_fs_wb.result_valid    = 1'b1;
            lsu_fs_wb.tag_out         = group_isq_payload[3].self_rob_tag;
            lsu_fs_wb.rd_idx          = group_isq_payload[3].rd_idx;
            lsu_fs_wb.is_fp           = 1'b0;
            lsu_fs_wb.result_data     = '0;
            lsu_fs_wb.exception_flag  = 1'b1;
            lsu_fs_wb.exception_cause = 64'd2;
        end
    end

    assign lsu_payload_to_p3 = lsu_fs_illegal_fire ? lsu_fs_wb : lsu_wb;

    // --- Minimal Bring-Up (MBU) FU Instantiations ---
    alu_simple u_alu0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush_late  (global_flush_late),
        .en          (en_alu0 || en_bru),
        .self_rob_tag(group_isq_payload[0].self_rob_tag),
        .pc          (group_isq_payload[0].pc),
        .rs1         (group_rs1[0]),
        .rs2         (group_rs2[0]),
        .imm_valid   (group_isq_payload[0].imm_valid),
        .imm_data    (group_isq_payload[0].imm_data),
        .pred_taken  (group_isq_payload[0].pred_taken),
        .pred_target_pc(group_isq_payload[0].pred_target_pc),
        .exe_subop   (group_isq_payload[0].exe_subop),
        .rd_idx      (group_isq_payload[0].rd_idx),
        .rd_is_fp    (group_isq_payload[0].rd_is_fp),
        .wb_payload  (g0_exec_wb),
        .busy        (alu0_busy),
        .wb_is_bru   (g0_exec_wb_is_bru)
    );

    alu_simple u_alu1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush_late  (global_flush_late),
        .en          (en_alu1),
        .self_rob_tag(group_isq_payload[1].self_rob_tag),
        .pc          ({XLEN{1'b0}}),
        .rs1         (group_rs1[1]),
        .rs2         (group_rs2[1]),
        .imm_valid   (group_isq_payload[1].imm_valid),
        .imm_data    (group_isq_payload[1].imm_data),
        .pred_taken  (1'b0),
        .pred_target_pc({XLEN{1'b0}}),
        .exe_subop   (group_isq_payload[1].exe_subop),
        .rd_idx      (group_isq_payload[1].rd_idx),
        .rd_is_fp    (group_isq_payload[1].rd_is_fp),
        .wb_payload  (alu1_wb),
        .busy        (alu1_busy),
        .wb_is_bru   ()
    );

    // Tie off unused FUs
    always_comb begin
        alu0_wb = '0;
        bru_wb  = '0;
        if (g0_exec_wb_is_bru) begin
            bru_wb = g0_exec_wb;
        end else begin
            alu0_wb = g0_exec_wb;
        end
    end

    assign bru_busy = alu0_busy;
    
    logic div_ack;
    logic mul_ack;

    div_simple u_div (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush_late  (global_flush_late),
        .en          (en_div),
        .self_rob_tag(group_isq_payload[0].self_rob_tag),
        .rs1         (group_rs1[0]),
        .rs2         (group_rs2[0]),
        .exe_subop   (group_isq_payload[0].exe_subop),
        .rd_idx      (group_isq_payload[0].rd_idx),
        .rd_is_fp    (group_isq_payload[0].rd_is_fp),
        .ack         (div_ack),
        .wb_payload  (div_wb),
        .busy        (div_busy)
    );
    assign csr_trap_pc    = flush_meta.inst_pc; // The interrupted or trapping instruction's PC retrieved from ROB sidearray
    assign csr_trap_cause = p4_is_interrupt ? 64'h800000000000000b : flush_meta.exception_cause;
    assign csr_trap_tval  = p4_is_interrupt ? '0 : flush_meta.exception_tval; // mtval: 0 for interrupts
    assign csr_ie_enabled = csr_mie_out; // Expose the internal MIE status to the top-level output port

    // Performance counter: commit count per cycle
    logic [1:0] perf_commit_count;
    assign perf_commit_count = {1'b0, commit_payload[0].commit_valid}
                             + {1'b0, commit_payload[1].commit_valid};

    csr_unit u_csr (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush_late        (global_flush_late),
        .en                (en_csr),
        .self_rob_tag      (group_isq_payload[0].self_rob_tag),
        .rs1_data          (group_rs1[0]),
        .exe_subop         (group_isq_payload[0].exe_subop),
        .rd_idx            (group_isq_payload[0].rd_idx),
        .imm_data          (group_isq_payload[0].imm_data),
        .csr_write_intent  (group_isq_payload[0].csr_write_intent),
        .wb_payload        (csr_wb),
        .busy              (csr_busy),
        .p4_csr_write      (p4_csr_write),
        .csr_pend_addr     (csr_pend_addr),
        .csr_pend_wdata    (csr_pend_wdata),
        .exception_taken   (global_flush_late && (flush_kind == FLUSH_EXCEPTION)),
        .exception_pc      (csr_trap_pc),
        .exception_cause   (csr_trap_cause),
        .exception_tval    (csr_trap_tval),
        .mret_taken        (p4_mret_retire),
        .csr_mtvec_out     (csr_mtvec_out),
        .csr_mepc_out      (csr_mepc_out),
        .csr_mie_out       (csr_mie_out),
        .csr_meie_out      (csr_meie_out),
        .csr_fs_enabled    (csr_fs_enabled),
        .csr_frm_out       (csr_frm_out),
        .ext_irq_valid     (ext_irq_valid),
        .fp_commit_valid   (fp_commit_valid),
        .fp_commit_fflags  (fp_commit_fflags),
        .commit_count      (perf_commit_count),
        .clear_csr_trackers(clear_csr_trackers)
    );

    mul_simple u_mul (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush_late  (global_flush_late),
        .en          (en_mul),
        .self_rob_tag(group_isq_payload[1].self_rob_tag),
        .rs1         (group_rs1[1]),
        .rs2         (group_rs2[1]),
        .exe_subop   (group_isq_payload[1].exe_subop),
        .rd_idx      (group_isq_payload[1].rd_idx),
        .rd_is_fp    (group_isq_payload[1].rd_is_fp),
        .ack         (mul_ack),
        .wb_payload  (mul_wb),
        .busy        (mul_busy)
    );

    fpu_simple u_fpu (
        .clk         (clk),
        .rst_n       (rst_n),
        .flush_late  (global_flush_late),
        .en          (en_fpu),
        .self_rob_tag(group_isq_payload[2].self_rob_tag),
        .rs1         (group_rs1[2]),
        .rs2         (group_rs2[2]),
        .rs3         (group_rs3[2]),
        .exe_subop   (group_isq_payload[2].exe_subop),
        .fpu_meta    (group_isq_payload[2].imm_data),
        .rd_idx      (group_isq_payload[2].rd_idx),
        .rd_is_fp    (group_isq_payload[2].rd_is_fp),
        .fs_enabled  (csr_fs_enabled),
        .frm         (csr_frm_out),
        .wb_payload  (fpu_wb),
        .busy        (fpu_busy)
    );

    // P3 Logic
    p3_intra_group_arbiter u_p3_arb (
        .alu0_payload(alu0_wb), .div_payload(div_wb), .bru_payload(bru_wb), .csr_payload(csr_wb),
        .alu1_payload(alu1_wb), .mul_payload(mul_wb),
        .fpu_payload(fpu_wb), .lsu_payload(lsu_payload_to_p3),
        .group_wb_payload(group_wb_payload),
        .alu0_ack(), .div_ack(div_ack), .bru_ack(), .csr_ack(), .alu1_ack(), .mul_ack(mul_ack)
    );

    generate
        for (g = 0; g < 4; g++) begin : gen_bypass
            if (g == 3) begin : gen_bypass_lsu
                // LSU load results may wake dependents. Store completion and
                // exception-only LSU results still retire through ROB / sidearray,
                // but they do not participate in bypass wakeup.
                assign bypass_bus[g].valid = lsu_wb.result_valid &&
                                             !lsu_store_buffered &&
                                             !lsu_wb.exception_flag &&
                                             !global_flush_late;
                assign bypass_bus[g].tag   = lsu_wb.tag_out;
                assign bypass_bus[g].data  = lsu_wb.result_data;
            end else begin : gen_bypass_normal
                assign bypass_bus[g].valid = group_wb_payload[g].result_valid &&
                                             !group_wb_payload[g].exception_flag &&
                                             !global_flush_late;
                assign bypass_bus[g].tag   = group_wb_payload[g].tag_out;
                assign bypass_bus[g].data  = group_wb_payload[g].result_data;
            end
        end
    endgenerate

    // CSR Control
    csr_control u_csr_ctrl (
        .clk(clk), .rst_n(rst_n),
        .p1_csr_valid(rob_alloc_valid[0] && isb_payload[0].is_csr), .p1_csr_tag(slot0_tag),
        .csr_inflight_valid(csr_inflight_valid), .csr_inflight_tag(csr_inflight_tag),
        .p3_csr_wb_valid(group_wb_payload[0].result_valid && group_wb_payload[0].is_csr), .p3_csr_payload(group_wb_payload[0]),
        .csr_pend_valid(csr_pend_valid), .csr_pend_tag(csr_pend_tag),
        .csr_pend_addr(csr_pend_addr), .csr_pend_wdata(csr_pend_wdata),
        .p4_csr_retire(p4_csr_retire), .clear_csr_trackers(clear_csr_trackers)
    );

    // P4 Logic
    p4_commit_control u_p4_ctrl (
        .head_ptr(head_ptr), .head_plus_1(head_plus_1),
        .head0(head0), .head1(head1),
        .commit_ack(commit_ack), .commit_payload(commit_payload),
        .fp_commit_valid(fp_commit_valid), .fp_commit_fflags(fp_commit_fflags),
        .global_flush_late(global_flush_late), .flush_head_adv(flush_head_adv), .flush_tag(flush_tag_p4), .flush_kind(flush_kind),
        .reset_rob_pointers(reset_rob_pointers), .clear_all_busy(clear_all_busy), 
        .clear_metaarray_flushvalid(clear_metaarray_flushvalid), .clear_csr_trackers(clear_csr_trackers),
        .csr_inflight_valid(csr_inflight_valid), .csr_inflight_tag(csr_inflight_tag),
        .csr_pend_valid(csr_pend_valid), .csr_pend_tag(csr_pend_tag),
        .p4_csr_retire(p4_csr_retire), .p4_csr_write(p4_csr_write), .p4_mret_retire(p4_mret_retire),
        .ext_irq_valid(ext_irq_valid), .csr_ie_enabled(csr_mie_out), .csr_meie_enabled(csr_meie_out), .p4_is_interrupt(p4_is_interrupt),
        .store_drain_req_valid(store_drain_req_valid), .store_drain_req_tag(store_drain_req_tag)
    );

    always_comb begin
        unique case (rob_alloc_valid)
            2'b00: isb_dequeue = 2'd0;
            2'b01: isb_dequeue = 2'd1;
            2'b11: isb_dequeue = 2'd2;
            default: isb_dequeue = 2'd0;
        endcase
    end

    assign flush_target_pc = (flush_kind == FLUSH_MISPREDICT) ? flush_meta.target_pc :
                             (flush_kind == FLUSH_EXCEPTION)  ? csr_mtvec_out :
                             (flush_kind == FLUSH_MRET)        ? csr_mepc_out : '0;

    assign csr_wr_en = p4_csr_write;
    assign csr_addr  = csr_pend_addr;
    assign csr_wdata = csr_pend_wdata;

endmodule

`endif // BACKEND_TOP_SV
