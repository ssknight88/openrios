`ifndef P4_COMMIT_CONTROL_SV
`define P4_COMMIT_CONTROL_SV

import orca_types::*;

module p4_commit_control (
    // ROB Status
    input  logic [TAG_W-1:0] head_ptr,
    input  logic [TAG_W-1:0] head_plus_1,
    input  rob_head_status_t head0,
    input  rob_head_status_t head1,

    // Commit Decisions
    output logic [1:0]  commit_ack,
    output commit_payload_t [1:0] commit_payload,

    // FP retire side-effects (accrue fflags / set mstatus.FS=Dirty in csr_unit)
    output logic        fp_commit_valid,
    output logic [4:0]  fp_commit_fflags,

    // Flush Decisions (Expanded for alignment)
    output logic        global_flush_late,
    output logic [TAG_W-1:0] flush_head_adv,
    output logic [TAG_W-1:0] flush_tag,
    output flush_kind_e flush_kind,
    output logic        reset_rob_pointers,
    output logic        clear_all_busy,
    output logic        clear_metaarray_flushvalid,
    output logic        clear_csr_trackers,

    // CSR Side Effects
    input  logic        csr_inflight_valid,
    input  logic [TAG_W-1:0] csr_inflight_tag,
    input  logic        csr_pend_valid,
    input  logic [TAG_W-1:0] csr_pend_tag,
    output logic        p4_csr_retire,
    output logic        p4_csr_write,
    output logic        p4_mret_retire,

    // External Interrupt
    input  logic        ext_irq_valid,
    input  logic        csr_ie_enabled,
    input  logic        csr_meie_enabled,
    output logic        p4_is_interrupt,

    // Store drain request
    output logic        store_drain_req_valid,
    output logic [TAG_W-1:0] store_drain_req_tag
);

    logic head0_can_commit, head0_must_flush;
    logic head1_can_commit, head1_must_flush;
    logic head0_store_commit_ready, head1_store_commit_ready;
    logic head0_store_needs_drain, head1_store_needs_drain;
    logic head0_csr_ready, head1_csr_ready;
    logic [1:0] commit_count_before_redirect;
    logic dual_fp_commit_block;
    
    // Internal arbitration signals
    logic flush_selected_this_cycle;
    logic head0_will_commit, head1_will_commit;
    logic delay_younger_exception;
    logic ext_irq_takeable;

    assign ext_irq_takeable = ext_irq_valid && csr_ie_enabled && csr_meie_enabled;

    assign head0_must_flush = head0.valid && head0.done && (head0.mispredict_flag || head0.exception_flag || head0.is_mret);
    assign head1_must_flush = head1.valid && head1.done && (head1.mispredict_flag || head1.exception_flag || head1.is_mret);

    assign head0_store_commit_ready = !head0.is_store || head0.store_done;
    assign head1_store_commit_ready = !head1.is_store || head1.store_done;

    assign head0_store_needs_drain = head0.valid && head0.done && !head0_must_flush &&
                                     head0.is_store && head0.store_buffered &&
                                     !head0.store_done && !head0.store_drain_requested;

    assign head1_store_needs_drain = head1.valid && head1.done && !head1_must_flush &&
                                     head1.is_store && head1.store_buffered &&
                                     !head1.store_done && !head1.store_drain_requested;

    assign head0_csr_ready = !head0.is_csr ||
                             (csr_inflight_valid && (csr_inflight_tag == head_ptr) &&
                              (!head0.csr_write_enable || (csr_pend_valid && (csr_pend_tag == head_ptr))));
    assign head1_csr_ready = !head1.is_csr ||
                             (csr_inflight_valid && (csr_inflight_tag == head_plus_1) &&
                              (!head1.csr_write_enable || (csr_pend_valid && (csr_pend_tag == head_plus_1))));

    // Initial commit conditions (ignoring external flushes for now)
    assign head0_can_commit = head0.valid && head0.done && !head0_must_flush &&
                              head0_csr_ready &&
                              head0_store_commit_ready;

    assign head1_can_commit = head1.valid && head1.done && !head1_must_flush &&
                              head1_csr_ready &&
                              head1_store_commit_ready;

    assign dual_fp_commit_block = head0_can_commit && head1_can_commit && head0.rd_is_fp && head1.rd_is_fp;

    // 统一 commit_payload 生成 helper（带 '0 初始化，规避未定义状态）
    function automatic commit_payload_t make_commit_entry(
        input logic [TAG_W-1:0]       tag,
        input logic [REG_ADDR_W-1:0]  rd_idx,
        input logic                   rd_is_fp,
        input logic [XLEN-1:0]        result
    );
        make_commit_entry = '0; // 关键：默认赋初值，防止新扩展字段漏赋值
        make_commit_entry.commit_valid = 1'b1;
        make_commit_entry.commit_tag   = tag;
        make_commit_entry.rd_idx       = rd_idx;
        make_commit_entry.rd_is_fp     = rd_is_fp;
        make_commit_entry.result_data  = result;
    endfunction

    always_comb begin
        // Default outputs
        commit_ack                 = 2'd0;
        commit_payload             = '0;
        global_flush_late          = 1'b0;
        flush_head_adv             = '0;
        flush_tag                  = '0;
        flush_kind                 = FLUSH_NONE;
        reset_rob_pointers         = 1'b0;
        clear_all_busy             = 1'b0;
        clear_metaarray_flushvalid = 1'b0;
        clear_csr_trackers         = 1'b0;
        p4_csr_retire              = 1'b0;
        p4_csr_write               = 1'b0;
        p4_mret_retire             = 1'b0;
        p4_is_interrupt            = 1'b0;
        fp_commit_valid            = 1'b0;
        fp_commit_fflags           = 5'b0;
        store_drain_req_valid      = 1'b0;
        store_drain_req_tag        = '0;
        commit_count_before_redirect = 2'd0;
        
        // Default internal states
        flush_selected_this_cycle  = 1'b0;
        head0_will_commit          = 1'b0;
        head1_will_commit          = 1'b0;

        // 临时组合信号，声明于 combinational block 顶部，符合标准 RTL 风格
        delay_younger_exception    = head0_can_commit && head0.is_csr && head1_must_flush && head1.exception_flag;

        // 1. Evaluate internal flushes from ROB heads
        if (head0_must_flush) begin
            if (head0.exception_flag) begin
                // head0 异常：不 commit，直接重定向到 mtvec
                flush_selected_this_cycle    = 1'b1;
                commit_count_before_redirect = 2'd0;
                flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                flush_tag                    = head_ptr;
                flush_kind                   = FLUSH_EXCEPTION;
            end else if (head0.mispredict_flag) begin
                // head0 分支预测错误：自身 commit，然后重定向到 correct target
                flush_selected_this_cycle    = 1'b1;
                head0_will_commit            = 1'b1;
                commit_count_before_redirect = 2'd1;
                flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                flush_tag                    = head_ptr;
                flush_kind                   = FLUSH_MISPREDICT;
            end else if (head0.is_mret) begin
                // head0 MRET: retire it, then redirect to mepc and restore mstatus at commit.
                flush_selected_this_cycle    = 1'b1;
                head0_will_commit            = 1'b1;
                commit_count_before_redirect = 2'd1;
                flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                flush_tag                    = head_ptr;
                flush_kind                   = FLUSH_MRET;
                p4_mret_retire               = 1'b1;
            end
        end else if (head0_store_needs_drain) begin
            store_drain_req_valid = 1'b1;
            store_drain_req_tag   = head_ptr;
        end else if (ext_irq_takeable && head0_can_commit && (!head0.is_store || head1.valid)) begin
            // Interrupt pending, and head0 is fully ready to commit.
            // If head0 is a store, we commit the store and take the interrupt on head1.
            // Otherwise, we take the interrupt on head0 (committing 0 instructions).
            flush_selected_this_cycle = 1'b1;
            p4_is_interrupt           = 1'b1;
            flush_kind                = FLUSH_EXCEPTION;

            if (head0.is_store) begin
                head0_will_commit            = 1'b1;
                commit_count_before_redirect = 2'd1;
                flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                flush_tag                    = head_plus_1;
            end else begin
                commit_count_before_redirect = 2'd0;
                flush_head_adv               = '0;
                flush_tag                    = head_ptr;
            end
        end else if (head0_can_commit) begin
            if (delay_younger_exception) begin
                // P0 CSR Guard: 延迟一拍。本拍仅提交 CSR，不触发 flush，下一拍 head1 变成 head0 后再触发精确 exception
                head0_will_commit            = 1'b1;
                commit_count_before_redirect = 2'd1;
            end else begin
                // 正常双发/单发与 Flush 仲裁
                head0_will_commit            = 1'b1;
                commit_count_before_redirect = 2'd1;
                
                if (head1_must_flush) begin
                    if (head1.exception_flag) begin
                        // head1 异常：仅 commit head0，head1 不 commit 且触发 flush 转向 mtvec
                        flush_selected_this_cycle    = 1'b1;
                        commit_count_before_redirect = 2'd1;
                        flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                        flush_tag                    = head_plus_1;
                        flush_kind                   = FLUSH_EXCEPTION;
                    end else if (head1.mispredict_flag) begin
                        // head1 预测错误：head0 和 head1 都 commit，然后触发 flush 转向 correct target
                        flush_selected_this_cycle    = 1'b1;
                        head1_will_commit            = 1'b1;
                        commit_count_before_redirect = 2'd2;
                        flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                        flush_tag                    = head_plus_1;
                        flush_kind                   = FLUSH_MISPREDICT;
                    end else if (head1.is_mret) begin
                        // head1 MRET: commit head0 and head1, then redirect to mepc / restore mstatus.
                        flush_selected_this_cycle    = 1'b1;
                        head1_will_commit            = 1'b1;
                        commit_count_before_redirect = 2'd2;
                        flush_head_adv               = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
                        flush_tag                    = head_plus_1;
                        flush_kind                   = FLUSH_MRET;
                        p4_mret_retire               = 1'b1;
                    end
                end else if (head1_store_needs_drain && !head0.is_store) begin
                    store_drain_req_valid = 1'b1;
                    store_drain_req_tag   = head_plus_1;
                end else if (head1_can_commit && !(head0.is_store && head1.is_store) && !dual_fp_commit_block) begin
                    head1_will_commit            = 1'b1;
                    commit_count_before_redirect = 2'd2;
                end
            end
        end

        // 2. External Interrupts are evaluated on ready boundaries.
        // It triggers a flush and redirects to mtvec when MIE is enabled and head0 is ready.

        // 3. Final Output Generation
        // 不管是否 flush，在此拍依然输出对应的 commit_ack 和 commit_payload！
        if (flush_selected_this_cycle) begin
            global_flush_late          = 1'b1;
            reset_rob_pointers         = 1'b1;
            clear_all_busy             = 1'b1;
            clear_metaarray_flushvalid = 1'b1;
            clear_csr_trackers         = 1'b1;
            store_drain_req_valid      = 1'b0;
            store_drain_req_tag        = '0;
        end
        
        // 统一物理端口赋值，保证逻辑一致性
        if (head0_will_commit) begin
            commit_ack       = 2'd1;
            commit_payload[0] = make_commit_entry(head_ptr, head0.rd_idx, head0.rd_is_fp, head0.result_data);
            if (head0.is_csr) begin
                p4_csr_retire = 1'b1;
                p4_csr_write  = head0.csr_write_enable;
            end
            if (head0.rd_is_fp) begin
                fp_commit_valid  = 1'b1;
                fp_commit_fflags = fp_commit_fflags | head0.fpu_fflags;
            end

            if (head1_will_commit) begin
                commit_ack      = 2'd2;
                commit_payload[1] = make_commit_entry(head_plus_1, head1.rd_idx, head1.rd_is_fp, head1.result_data);
                if (head1.is_csr) begin
                    p4_csr_retire = 1'b1;
                    p4_csr_write  = head1.csr_write_enable;
                end
                if (head1.rd_is_fp) begin
                    fp_commit_valid  = 1'b1;
                    fp_commit_fflags = fp_commit_fflags | head1.fpu_fflags;
                end
            end
        end
    end

endmodule

`endif // P4_COMMIT_CONTROL_SV
