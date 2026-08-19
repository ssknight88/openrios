`timescale 1ns/1ps

import orca_types::*;

module fake_lsu #(
    parameter int STB_DEPTH = 4,
    parameter int MEM_DEPTH = 256
) (
    input  logic        clk,
    input  logic        rst_n,

    // Group 3 request boundary from backend
    input  logic        req_pending,
    input  logic        req_valid,
    input  lsu_req_t    req_payload,

    // Commit / flush sideband
    input  logic        flush_late,
    input  logic [ROB_DEPTH-1:0] flush_discard_mask,
    input  logic        store_drain_req_valid,
    input  logic [TAG_W-1:0] store_drain_req_tag,
    input  logic [7:0]  cfg_load_backpressure_cycles,
    input  logic [7:0]  cfg_store_drain_cycles,

    // LSU outputs back into backend
    output logic        lsu_busy,
    output result_payload_t lsu_wb,
    output logic        lsu_store_buffered,
    output logic        agu_early_tag_valid,
    output logic [TAG_W-1:0] agu_early_tag,
    output logic        store_done_valid,
    output logic [TAG_W-1:0] store_done_tag,
    output logic        store_done_exception,
    output logic [XLEN-1:0] store_done_cause,

    // Debug observability
    output logic        dbg_stb_full,
    output logic        dbg_alias_block,
    output logic        dbg_cache_backpressure
);

`ifndef SYNTHESIS
    import "DPI-C" function bit dpi_is_elf_loaded();
    import "DPI-C" function bit dpi_read_mem(input longint addr, input int size, output longint data);
    import "DPI-C" function bit dpi_write_mem(input longint addr, input int size, input longint data);
`endif

    localparam int MEM_IDX_W = $clog2(MEM_DEPTH);

`ifndef SYNTHESIS
    bit lsu_dbg_enable;
    initial begin
        lsu_dbg_enable = $test$plusargs("LSU_DBG");
    end
`else
    wire lsu_dbg_enable = 1'b0;
`endif

    typedef struct packed {
        logic               valid;
        logic               draining;
        logic [7:0]         drain_cnt;
        logic               exception_flag;
        logic [XLEN-1:0]    exception_cause;
        logic [TAG_W-1:0]   tag;
        logic [XLEN-1:0]    addr;
        logic [XLEN-1:0]    data;
        logic [2:0]         store_size;
    } stb_entry_t;

    logic [XLEN-1:0] mem [0:MEM_DEPTH-1];
    stb_entry_t stb [0:STB_DEPTH-1];

    // Internal fixed-latency LSU pipeline.
    logic            stage1_valid;
    lsu_req_t        stage1_payload;
    logic [XLEN-1:0] stage1_addr;
    logic            stage1_exception;
    logic [XLEN-1:0] stage1_exception_cause;

    logic            stage2_valid;
    logic            stage2_is_store;
    result_payload_t stage2_wb;

    logic agu_early_tag_valid_r;
    logic [TAG_W-1:0] agu_early_tag_r;

    logic       stb_free_found;
    logic [31:0] stb_free_idx;
    logic       load_stlf_hit;
    logic [XLEN-1:0] new_req_addr;
    logic       store_drain_req_hit;
    logic       load_backpressure_active;
    logic [TAG_W-1:0] load_backpressure_tag;
    logic [7:0] load_backpressure_remaining;
    logic       load_backpressure_done_valid;
    logic [TAG_W-1:0] load_backpressure_done_tag;
    logic       load_cache_backpressure;

    function automatic logic [MEM_IDX_W-1:0] mem_idx(input logic [XLEN-1:0] addr);
        return addr[MEM_IDX_W-1:0];
    endfunction

    function automatic logic host_mem_enabled();
`ifndef SYNTHESIS
        return dpi_is_elf_loaded();
`else
        return 1'b0;
`endif
    endfunction

    function automatic logic addr_range_exception(input logic [XLEN-1:0] addr, input int unsigned size);
        logic [XLEN-1:0] end_addr;
        logic in_smoke_range;
        logic in_bench_range;
        if (size == 0) begin
            return 1'b1;
        end
        end_addr = addr + size - 1;
        if (host_mem_enabled()) begin
            in_smoke_range = (addr >= 64'h10000) && (end_addr < 64'h1000000); // 16MB range for smoke/embench
            in_bench_range = (addr[63:26] == 38'h20) &&
                             (end_addr[63:26] == 38'h20);
            return !(in_smoke_range || in_bench_range);
        end else begin
            return (addr[XLEN-1:12] != {{(XLEN-12-1){1'b0}}, 1'b1}) ||
                   (end_addr[XLEN-1:12] != {{(XLEN-12-1){1'b0}}, 1'b1});
        end
    endfunction

    function automatic int unsigned lsu_load_access_size(input logic [2:0] funct3, input logic rd_is_fp);
        if (rd_is_fp) begin
            case (funct3)
                3'b010:  return 4; // FLW
                3'b011:  return 8; // FLD
                default: return 0;
            endcase
        end
        case (funct3)
            3'b000:  return 1; // LB
            3'b001:  return 2; // LH
            3'b010:  return 4; // LW
            3'b011:  return 8; // LD
            3'b100:  return 1; // LBU
            3'b101:  return 2; // LHU
            3'b110:  return 4; // LWU
            default: return 0;
        endcase
    endfunction

    function automatic int unsigned lsu_store_access_size(input logic [2:0] funct3);
        case (funct3)
            3'b000:  return 1; // SB
            3'b001:  return 2; // SH
            3'b010:  return 4; // SW
            3'b011:  return 8; // SD
            default: return 0;
        endcase
    endfunction

    function automatic int unsigned lsu_access_size(input logic is_load, input logic is_store, input logic [2:0] funct3, input logic rd_is_fp);
        if (is_load && !is_store) begin
            return lsu_load_access_size(funct3, rd_is_fp);
        end
        if (is_store && !is_load) begin
            return lsu_store_access_size(funct3);
        end
        return 0;
    endfunction

    function automatic logic [XLEN-1:0] extend_load_data(input logic [63:0] raw, input logic [2:0] funct3, input logic rd_is_fp);
        if (rd_is_fp) begin
            case (funct3)
                3'b010: return {32'hffff_ffff, raw[31:0]}; // FLW NaN-box
                3'b011: return raw;                         // FLD
                default: return raw;
            endcase
        end
        case (funct3)
            3'b000: return {{56{raw[7]}}, raw[7:0]};     // LB
            3'b001: return {{48{raw[15]}}, raw[15:0]};   // LH
            3'b010: return {{32{raw[31]}}, raw[31:0]};   // LW
            3'b011: return raw;                          // LD
            3'b100: return {56'b0, raw[7:0]};            // LBU
            3'b101: return {48'b0, raw[15:0]};           // LHU
            3'b110: return {32'b0, raw[31:0]};           // LWU
            default: return raw;
        endcase
    endfunction

    function automatic logic [7:0] local_mem_read_byte(input logic [XLEN-1:0] byte_addr);
        logic [XLEN-1:0] word_base = byte_addr & ~64'd7;
        logic [2:0] byte_lane = byte_addr[2:0];
        return mem[mem_idx(word_base)][8*byte_lane +: 8];
    endfunction

    task automatic local_mem_write_byte(input logic [XLEN-1:0] byte_addr, input logic [7:0] data);
        logic [XLEN-1:0] word_base = byte_addr & ~64'd7;
        logic [2:0] byte_lane = byte_addr[2:0];
        mem[mem_idx(word_base)][8*byte_lane +: 8] <= data;
    endtask

    function automatic int get_youngest_stb_match(input logic [XLEN-1:0] byte_addr, input logic [TAG_W-1:0] load_tag);
        int match_idx = -1;
        logic [TAG_W-1:0] youngest_tag = '0;
        for (int i = 0; i < STB_DEPTH; i++) begin
            if (stb[i].valid) begin
                int unsigned store_size_bytes = lsu_store_access_size(stb[i].store_size);
                logic addr_match;
                addr_match = (byte_addr >= stb[i].addr) && (byte_addr < stb[i].addr + store_size_bytes);
`ifndef SYNTHESIS
                if (lsu_dbg_enable) begin
                    $display("[LSU_DBG_MATCH] Checking stb[%d]: tag=%d, addr=%x, size=%d, addr_match=%b, byte_addr=%x", i, stb[i].tag, stb[i].addr, store_size_bytes, addr_match, byte_addr);
                end
`endif
                if (addr_match) begin
                    logic [TAG_W-1:0] tag_dist;
                    tag_dist = (load_tag >= stb[i].tag) ? (load_tag - stb[i].tag) : (load_tag + ROB_DEPTH[TAG_W-1:0] - stb[i].tag);
`ifndef SYNTHESIS
                    if (lsu_dbg_enable) begin
                        $display("[LSU_DBG_MATCH] tag_dist=%d, load_tag=%d, stb_tag=%d", tag_dist, load_tag, stb[i].tag);
                    end
`endif
                    if (tag_dist > 0) begin
                        if (match_idx == -1) begin
                            match_idx = i;
                            youngest_tag = stb[i].tag;
                        end else begin
                            logic [TAG_W-1:0] current_tag_dist;
                            current_tag_dist = (load_tag >= youngest_tag) ? (load_tag - youngest_tag) : (load_tag + ROB_DEPTH[TAG_W-1:0] - youngest_tag);
                            if (tag_dist < current_tag_dist) begin
                                match_idx = i;
                                youngest_tag = stb[i].tag;
                            end
                        end
                    end
                end
            end
        end
        return match_idx;
    endfunction

    assign new_req_addr = req_payload.base_addr + (req_payload.imm_valid ? req_payload.imm_data : '0);
    assign load_cache_backpressure =
        req_pending &&
        req_payload.is_load &&
        (cfg_load_backpressure_cycles != 8'd0) &&
        !(load_backpressure_done_valid && (load_backpressure_done_tag == req_payload.tag));

    always_comb begin
        stb_free_found = 1'b0;
        stb_free_idx = '0;
        for (int i = 0; i < STB_DEPTH; i++) begin
            if (!stb[i].valid && !stb_free_found) begin
                stb_free_found = 1'b1;
                stb_free_idx = i;
            end
        end
    end

    always_comb begin
        load_stlf_hit = 1'b0;
        if (stage1_valid && stage1_payload.is_load) begin
            automatic int unsigned load_size_bytes = lsu_load_access_size(stage1_payload.store_size, stage1_payload.rd_is_fp);
            for (int b = 0; b < 8; b++) begin
                if (b < load_size_bytes) begin
                    if (get_youngest_stb_match(stage1_addr + b, stage1_payload.tag) != -1) begin
                        load_stlf_hit = 1'b1;
                    end
                end
            end
        end
    end

    always_comb begin
        store_drain_req_hit = 1'b0;
        for (int i = 0; i < STB_DEPTH; i++) begin
            if (stb[i].valid && (stb[i].tag == store_drain_req_tag)) begin
                store_drain_req_hit = 1'b1;
            end
        end
    end

    // Black-box contract:
    // - flush_late always wins and must not backpressure recovery
    // - store drain latency does not backpressure unrelated loads
    // - stores block only when the STB has no free entry
    always_comb begin
        lsu_busy = 1'b0;

        if (flush_late) begin
            lsu_busy = 1'b0;
        end else if (load_cache_backpressure) begin
            lsu_busy = 1'b1;
        end else if (req_pending && req_payload.is_store) begin
            lsu_busy = !stb_free_found;
        end
    end

    assign dbg_stb_full = !stb_free_found;
    assign dbg_alias_block = load_stlf_hit;
    assign dbg_cache_backpressure = load_cache_backpressure;

    assign agu_early_tag_valid = agu_early_tag_valid_r;
    assign agu_early_tag = agu_early_tag_r;
    assign lsu_wb = stage2_valid ? stage2_wb : '0;
    assign lsu_store_buffered = stage2_valid && stage2_is_store;

    logic [XLEN-1:0] loaded_raw_data;
    always_comb begin
        loaded_raw_data = '0;
        if (stage1_valid && stage1_payload.is_load && !stage1_exception) begin
            automatic int unsigned load_size_bytes = lsu_load_access_size(stage1_payload.store_size, stage1_payload.rd_is_fp);
            for (int b = 0; b < 8; b++) begin
                if (b < load_size_bytes) begin
                    automatic logic [XLEN-1:0] byte_addr = stage1_addr + b;
                    automatic int stb_idx = get_youngest_stb_match(byte_addr, stage1_payload.tag);
                    automatic logic [7:0] byte_val;
                    if (stb_idx != -1) begin
                        automatic int unsigned offset = byte_addr - stb[stb_idx].addr;
                        byte_val = stb[stb_idx].data[8*offset +: 8];
                        if (lsu_dbg_enable) begin
                            $display("[LSU_DBG] Load Tag=%d, Addr=%x, ByteOffset=%d, STB hit index=%d (Tag=%d), ByteVal=%x", stage1_payload.tag, stage1_addr, b, stb_idx, stb[stb_idx].tag, byte_val);
                        end
                    end else begin
`ifndef SYNTHESIS
                        if (host_mem_enabled()) begin
                            automatic longint dpi_byte_data = '0;
                            void'(dpi_read_mem(byte_addr, 1, dpi_byte_data));
                            byte_val = dpi_byte_data[7:0];
                        end else begin
                            byte_val = local_mem_read_byte(byte_addr);
                        end
`else
                        byte_val = local_mem_read_byte(byte_addr);
`endif
`ifndef SYNTHESIS
                        if (lsu_dbg_enable) begin
                            $display("[LSU_DBG] Load Tag=%d, Addr=%x, ByteOffset=%d, STB miss, MemByteVal=%x", stage1_payload.tag, stage1_addr, b, byte_val);
                        end
`endif
                    end
                    loaded_raw_data[8*b +: 8] = byte_val;
                end
            end
        end
    end

    logic [XLEN-1:0] extended_load_data_val;
    assign extended_load_data_val = extend_load_data(loaded_raw_data, stage1_payload.store_size, stage1_payload.rd_is_fp);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
            stage2_is_store <= 1'b0;
            stage1_payload <= '0;
            stage1_addr <= '0;
            stage1_exception <= 1'b0;
            stage1_exception_cause <= '0;
            stage2_wb <= '0;
            agu_early_tag_valid_r <= 1'b0;
            agu_early_tag_r <= '0;
            load_backpressure_active <= 1'b0;
            load_backpressure_tag <= '0;
            load_backpressure_remaining <= '0;
            load_backpressure_done_valid <= 1'b0;
            load_backpressure_done_tag <= '0;
            store_done_valid <= 1'b0;
            store_done_tag <= '0;
            store_done_exception <= 1'b0;
            store_done_cause <= '0;
            for (int i = 0; i < STB_DEPTH; i++) begin
                stb[i] <= '0;
            end
        end else if (flush_late) begin
            // Flush owns absolute priority over same-cycle request launch.
            // Already-running committed drain state is preserved and resumes
            // after recovery; speculative entries named by flush_discard_mask
            // are discarded.
            agu_early_tag_valid_r <= 1'b0;
            agu_early_tag_r <= '0;
            stage1_valid <= 1'b0;
            stage2_valid <= 1'b0;
            stage2_is_store <= 1'b0;
            load_backpressure_active <= 1'b0;
            load_backpressure_tag <= '0;
            load_backpressure_remaining <= '0;
            load_backpressure_done_valid <= 1'b0;
            load_backpressure_done_tag <= '0;
            store_done_valid <= 1'b0;
            store_done_tag <= '0;
            store_done_exception <= 1'b0;
            store_done_cause <= '0;

            for (int i = 0; i < STB_DEPTH; i++) begin
                if (stb[i].valid && flush_discard_mask[stb[i].tag]) begin
                    stb[i].valid <= 1'b0;
                    stb[i].draining <= 1'b0;
                end
            end
        end else begin
            agu_early_tag_valid_r <= 1'b0;
            agu_early_tag_r <= '0;
            store_done_valid <= 1'b0;
            store_done_tag <= '0;
            store_done_exception <= 1'b0;
            store_done_cause <= '0;

            if (req_valid && req_payload.is_load &&
                load_backpressure_done_valid && (load_backpressure_done_tag == req_payload.tag)) begin
                load_backpressure_done_valid <= 1'b0;
                load_backpressure_done_tag <= '0;
            end

            if (req_pending && req_payload.is_load &&
                (cfg_load_backpressure_cycles != 8'd0) &&
                !(load_backpressure_done_valid && (load_backpressure_done_tag == req_payload.tag))) begin
                if (!load_backpressure_active || (load_backpressure_tag != req_payload.tag)) begin
                    load_backpressure_active <= 1'b1;
                    load_backpressure_tag <= req_payload.tag;
                    load_backpressure_remaining <= cfg_load_backpressure_cycles - 8'd1;
                    if (cfg_load_backpressure_cycles == 8'd1) begin
                        load_backpressure_active <= 1'b0;
                        load_backpressure_done_valid <= 1'b1;
                        load_backpressure_done_tag <= req_payload.tag;
                    end
                end else if (load_backpressure_remaining > 8'd1) begin
                    load_backpressure_remaining <= load_backpressure_remaining - 8'd1;
                end else begin
                    load_backpressure_active <= 1'b0;
                    load_backpressure_remaining <= '0;
                    load_backpressure_done_valid <= 1'b1;
                    load_backpressure_done_tag <= req_payload.tag;
                end
            end

            for (int i = 0; i < STB_DEPTH; i++) begin
                if (stb[i].valid && stb[i].draining) begin
                    if (stb[i].drain_cnt > 8'd1) begin
                        stb[i].drain_cnt <= stb[i].drain_cnt - 8'd1;
                    end else begin
                        store_done_valid <= 1'b1;
                        store_done_tag <= stb[i].tag;
                        store_done_exception <= stb[i].exception_flag;
                        store_done_cause <= stb[i].exception_cause;

                        if (!stb[i].exception_flag) begin
`ifndef SYNTHESIS
                            if (host_mem_enabled()) begin
                                void'(dpi_write_mem(stb[i].addr, lsu_store_access_size(stb[i].store_size), stb[i].data));
                            end else begin
                                automatic int unsigned store_size_bytes = lsu_store_access_size(stb[i].store_size);
                                for (int b = 0; b < 8; b++) begin
                                    if (b < store_size_bytes) begin
                                        automatic logic [XLEN-1:0] byte_addr = stb[i].addr + b;
                                        automatic logic [XLEN-1:0] word_base = byte_addr & ~64'd7;
                                        automatic logic [2:0] byte_lane = byte_addr[2:0];
                                        mem[mem_idx(word_base)][8*byte_lane +: 8] <= stb[i].data[8*b +: 8];
                                    end
                                end
                            end
`else
                            automatic int unsigned store_size_bytes = lsu_store_access_size(stb[i].store_size);
                            for (int b = 0; b < 8; b++) begin
                                if (b < store_size_bytes) begin
                                    automatic logic [XLEN-1:0] byte_addr = stb[i].addr + b;
                                    automatic logic [XLEN-1:0] word_base = byte_addr & ~64'd7;
                                    automatic logic [2:0] byte_lane = byte_addr[2:0];
                                    mem[mem_idx(word_base)][8*byte_lane +: 8] <= stb[i].data[8*b +: 8];
                                end
                            end
`endif
                        end

                        stb[i].valid <= 1'b0;
                        stb[i].draining <= 1'b0;
                        stb[i].drain_cnt <= '0;
                    end
                end
            end

            // ROB-head drain request starts an L1D-side drain but does not
            // remove the STB entry until Store_Done is returned.
            if (store_drain_req_valid) begin
                for (int i = 0; i < STB_DEPTH; i++) begin
                    if (stb[i].valid && (stb[i].tag == store_drain_req_tag) && !stb[i].draining) begin
                        stb[i].draining <= 1'b1;
                        stb[i].drain_cnt <= (cfg_store_drain_cycles == 8'd0) ? 8'd1 : cfg_store_drain_cycles;
                    end
                end

                if (!store_drain_req_hit) begin
                    store_done_valid <= 1'b1;
                    store_done_tag <= store_drain_req_tag;
                    store_done_exception <= 1'b1;
                    store_done_cause <= 64'd7;
                end
            end

            // Stage 1 -> Stage 2
            stage2_valid <= stage1_valid;
            stage2_is_store <= stage1_valid && stage1_payload.is_store;
            stage2_wb <= '0;
            if (stage1_valid) begin
                stage2_wb.result_valid <= 1'b1;
                stage2_wb.tag_out <= stage1_payload.tag;
                stage2_wb.rd_idx <= stage1_payload.rd_idx;
                stage2_wb.is_fp <= stage1_payload.rd_is_fp;
                stage2_wb.mispredict_flag <= 1'b0;
                stage2_wb.exception_flag <= stage1_exception;
                stage2_wb.correct_pc <= '0;
                stage2_wb.exception_cause <= stage1_exception_cause;
                stage2_wb.exception_tval  <= stage1_exception ? stage1_addr : '0; // faulting load addr -> mtval
                stage2_wb.is_csr <= 1'b0;
                stage2_wb.csr_write_enable <= 1'b0;
                stage2_wb.csr_addr <= '0;
                stage2_wb.csr_wdata <= '0;

                if (stage1_payload.is_load && !stage1_exception) begin
                    stage2_wb.result_data <= extended_load_data_val;
                end else begin
                    stage2_wb.result_data <= '0;
                end
            end

            // Issue -> Stage 1
            stage1_valid <= req_valid;
            if (req_valid) begin
                automatic int unsigned req_size_bytes = lsu_access_size(req_payload.is_load, req_payload.is_store, req_payload.store_size, req_payload.rd_is_fp);
                stage1_payload <= req_payload;
                stage1_addr <= new_req_addr;
                stage1_exception <= req_payload.is_load && addr_range_exception(new_req_addr, req_size_bytes);
                stage1_exception_cause <= (req_payload.is_load && addr_range_exception(new_req_addr, req_size_bytes)) ? 64'd5 : 64'd0;

                if (req_payload.is_load && !addr_range_exception(new_req_addr, req_size_bytes)) begin
                    agu_early_tag_valid_r <= 1'b1;
                    agu_early_tag_r <= req_payload.tag;
                end

                if (req_payload.is_store && stb_free_found) begin
                    stb[stb_free_idx].valid <= 1'b1;
                    stb[stb_free_idx].draining <= 1'b0;
                    stb[stb_free_idx].drain_cnt <= '0;
                    stb[stb_free_idx].exception_flag <= addr_range_exception(new_req_addr, req_size_bytes);
                    stb[stb_free_idx].exception_cause <= addr_range_exception(new_req_addr, req_size_bytes) ? 64'd7 : 64'd0;
                    stb[stb_free_idx].tag <= req_payload.tag;
                    stb[stb_free_idx].addr <= new_req_addr;
                    stb[stb_free_idx].data <= req_payload.store_data;
                    stb[stb_free_idx].store_size <= req_payload.store_size;
`ifndef SYNTHESIS
                    if (lsu_dbg_enable) begin
                        $display("[LSU_DBG] Buffered store Tag=%d, Addr=%x, Data=%x, Size=%d", req_payload.tag, new_req_addr, req_payload.store_data, req_payload.store_size);
                    end
`endif
                end
            end else begin
                stage1_exception <= 1'b0;
                stage1_exception_cause <= '0;
            end
        end
    end

endmodule
