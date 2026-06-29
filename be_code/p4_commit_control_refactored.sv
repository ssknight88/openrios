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

    // ========================================================================
    // REFACTOR PLAN (2026-06-26):
    // 1. Pre-evaluate head status in separate always_comb (reduce nesting)
    // 2. Flatten flush priority logic (reduce decision tree depth)
    // 3. Decouple flush side-effects (single point of generation)
    // ========================================================================

    // --- Pre-evaluated head status signals ---
    logic head0_can_commit, head0_must_flush;
    logic head1_can_commit, head1_must_flush;
    logic head0_store_commit_ready, head1_store_commit_ready;
    logic head0_store_needs_drain, head1_store_needs_drain;
    logic head0_csr_ready, head1_csr_ready;
    logic dual_fp_commit_block;
    logic ext_irq_takeable;

    // --- Decision outputs ---
    logic flush_selected;
    logic [1:0] commit_count_before_redirect;
    logic head0_will_commit, head1_will_commit;
    logic delay_younger_exception;

    // --- Helper: CSR ready check ---
    function automatic logic check_csr_ready(
        input rob_head_status_t head,
        input logic [TAG_W-1:0] expected_tag
    );
        return !head.is_csr ||
               (csr_inflight_valid && (csr_inflight_tag == expected_tag) &&
                (!head.csr_write_enable || (csr_pend_valid && (csr_pend_tag == expected_tag))));
    endfunction

    // --- Helper: Store drain check ---
    function automatic logic check_store_needs_drain(
        input rob_head_status_t head
    );
        return head.valid && head.done && !head.mispredict_flag && !head.exception_flag && !head.is_mret &&
               head.is_store && head.store_buffered && !head.store_done && !head.store_drain_requested;
    endfunction

    // ========================================================================
    // BLOCK 1: Pre-evaluate all head status signals
    // ========================================================================
    always_comb begin
        // Interrupt ready
        ext_irq_takeable = ext_irq_valid && csr_ie_enabled && csr_meie_enabled;

        // Flush conditions
        head0_must_flush = head0.valid && head0.done && (head0.mispredict_flag || head0.exception_flag || head0.is_mret);
        head1_must_flush = head1.valid && head1.done && (head1.mispredict_flag || head1.exception_flag || head1.is_mret);

        // Store readiness
        head0_store_commit_ready = !head0.is_store || head0.store_done;
        head1_store_commit_ready = !head1.is_store || head1.store_done;

        // Store drain needs
        head0_store_needs_drain = check_store_needs_drain(head0);
        head1_store_needs_drain = check_store_needs_drain(head1);

        // CSR readiness
        head0_csr_ready = check_csr_ready(head0, head_ptr);
        head1_csr_ready = check_csr_ready(head1, head_plus_1);

        // Commit conditions
        head0_can_commit = head0.valid && head0.done && !head0_must_flush &&
                          head0_csr_ready && head0_store_commit_ready;
        head1_can_commit = head1.valid && head1.done && !head1_must_flush &&
                          head1_csr_ready && head1_store_commit_ready;

        // Dual FP commit block
        dual_fp_commit_block = head0_can_commit && head1_can_commit && head0.rd_is_fp && head1.rd_is_fp;

        // CSR guard for younger exception
        delay_younger_exception = head0_can_commit && head0.is_csr && head1_must_flush && head1.exception_flag;
    end

    // --- Helper: commit_payload generation ---
    function automatic commit_payload_t make_commit_entry(
        input logic [TAG_W-1:0]       tag,
        input logic [REG_ADDR_W-1:0]  rd_idx,
        input logic                   rd_is_fp,
        input logic [XLEN-1:0]        result
    );
        make_commit_entry = '0;
        make_commit_entry.commit_valid = 1'b1;
        make_commit_entry.commit_tag   = tag;
        make_commit_entry.rd_idx       = rd_idx;
        make_commit_entry.rd_is_fp     = rd_is_fp;
        make_commit_entry.result_data  = result;
    endfunction

    // ========================================================================
    // BLOCK 2: Flattened priority encoder for flush/commit decision
    // ========================================================================
    always_comb begin
        // Default outputs
        flush_selected             = 1'b0;
        flush_kind                 = FLUSH_NONE;
        flush_tag                  = '0;
        commit_count_before_redirect = 2'd0;
        head0_will_commit          = 1'b0;
        head1_will_commit          = 1'b0;
        p4_is_interrupt            = 1'b0;
        p4_mret_retire             = 1'b0;
        store_drain_req_valid      = 1'b0;
        store_drain_req_tag        = '0;

        // Priority encoder (flattened, no deep nesting)
        // Priority 1: head0 exception
        if (head0_must_flush && head0.exception_flag) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_EXCEPTION;
            flush_tag      = head_ptr;
            commit_count_before_redirect = 2'd0;
        end
        // Priority 2: head0 mispredict
        else if (head0_must_flush && head0.mispredict_flag) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_MISPREDICT;
            flush_tag      = head_ptr;
            head0_will_commit = 1'b1;
            commit_count_before_redirect = 2'd1;
        end
        // Priority 3: head0 MRET
        else if (head0_must_flush && head0.is_mret) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_MRET;
            flush_tag      = head_ptr;
            head0_will_commit = 1'b1;
            p4_mret_retire = 1'b1;
            commit_count_before_redirect = 2'd1;
        end
        // Priority 4: head0 store drain
        else if (head0_store_needs_drain) begin
            store_drain_req_valid = 1'b1;
            store_drain_req_tag   = head_ptr;
        end
        // Priority 5: external interrupt (head0 ready)
        else if (ext_irq_takeable && head0_can_commit && (!head0.is_store || head1.valid)) begin
            flush_selected  = 1'b1;
            flush_kind      = FLUSH_EXCEPTION;
            p4_is_interrupt = 1'b1;
            if (head0.is_store) begin
                head0_will_commit = 1'b1;
                flush_tag         = head_plus_1;
                commit_count_before_redirect = 2'd1;
            end else begin
                flush_tag = head_ptr;
                commit_count_before_redirect = 2'd0;
            end
        end
        // Priority 6: head0 commit + CSR guard for younger exception
        else if (head0_can_commit && delay_younger_exception) begin
            head0_will_commit = 1'b1;
            commit_count_before_redirect = 2'd1;
        end
        // Priority 7: head0 commit + head1 exception
        else if (head0_can_commit && head1_must_flush && head1.exception_flag) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_EXCEPTION;
            flush_tag      = head_plus_1;
            head0_will_commit = 1'b1;
            commit_count_before_redirect = 2'd1;
        end
        // Priority 8: head0 commit + head1 mispredict
        else if (head0_can_commit && head1_must_flush && head1.mispredict_flag) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_MISPREDICT;
            flush_tag      = head_plus_1;
            head0_will_commit = 1'b1;
            head1_will_commit = 1'b1;
            commit_count_before_redirect = 2'd2;
        end
        // Priority 9: head0 commit + head1 MRET
        else if (head0_can_commit && head1_must_flush && head1.is_mret) begin
            flush_selected = 1'b1;
            flush_kind     = FLUSH_MRET;
            flush_tag      = head_plus_1;
            head0_will_commit = 1'b1;
            head1_will_commit = 1'b1;
            p4_mret_retire = 1'b1;
            commit_count_before_redirect = 2'd2;
        end
        // Priority 10: head0 commit + head1 store drain
        else if (head0_can_commit && head1_store_needs_drain && !head0.is_store) begin
            head0_will_commit = 1'b1;
            store_drain_req_valid = 1'b1;
            store_drain_req_tag   = head_plus_1;
            commit_count_before_redirect = 2'd1;
        end
        // Priority 11: dual commit (normal case)
        else if (head0_can_commit && head1_can_commit && !(head0.is_store && head1.is_store) && !dual_fp_commit_block) begin
            head0_will_commit = 1'b1;
            head1_will_commit = 1'b1;
            commit_count_before_redirect = 2'd2;
        end
        // Priority 12: single head0 commit
        else if (head0_can_commit) begin
            head0_will_commit = 1'b1;
            commit_count_before_redirect = 2'd1;
        end
    end

    // ========================================================================
    // BLOCK 3: Unified output generation (decoupled flush side-effects)
    // ========================================================================
    always_comb begin
        // Default all outputs
        commit_ack                 = 2'd0;
        commit_payload             = '0;
        global_flush_late          = 1'b0;
        flush_head_adv             = '0;
        reset_rob_pointers         = 1'b0;
        clear_all_busy             = 1'b0;
        clear_metaarray_flushvalid = 1'b0;
        clear_csr_trackers         = 1'b0;
        p4_csr_retire              = 1'b0;
        p4_csr_write               = 1'b0;
        fp_commit_valid            = 1'b0;
        fp_commit_fflags           = 5'b0;

        // Flush side-effects (unified, single point of generation)
        if (flush_selected) begin
            global_flush_late          = 1'b1;
            reset_rob_pointers         = 1'b1;
            clear_all_busy             = 1'b1;
            clear_metaarray_flushvalid = 1'b1;
            clear_csr_trackers         = 1'b1;
            flush_head_adv             = {{(TAG_W-2){1'b0}}, commit_count_before_redirect};
        end

        // Commit payload generation
        if (head0_will_commit) begin
            commit_ack        = 2'd1;
            commit_payload[0] = make_commit_entry(head_ptr, head0.rd_idx, head0.rd_is_fp, head0.result_data);

            if (head0.is_csr) begin
                p4_csr_retire = 1'b1;
                p4_csr_write  = head0.csr_write_enable;
            end

            if (head0.rd_is_fp) begin
                fp_commit_valid  = 1'b1;
                fp_commit_fflags = head0.fpu_fflags;
            end

            if (head1_will_commit) begin
                commit_ack        = 2'd2;
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
