`ifndef ROB_SV
`define ROB_SV

import orca_types::*;

module rob (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Dispatch / Allocation
    input  logic [1:0]  alloc_valid,
    input  logic [1:0]  alloc_is_store,
    output logic [TAG_W-1:0] alloc_tag_0,
    output logic [TAG_W-1:0] alloc_tag_1,
    output logic        rob_full,
    output logic        rob_empty,
    output logic        rob_can_alloc_1,
    output logic        rob_can_alloc_2,

    // P3: Writeback (4 groups)
    input  result_payload_t [3:0] wb_payload,
    input  logic [3:0]  wb_store_buffered,
    input  logic        store_drain_req_valid,
    input  logic [TAG_W-1:0] store_drain_req_tag,
    input  logic        store_done_valid,
    input  logic [TAG_W-1:0] store_done_tag,
    input  logic        store_done_exception,

    // P4: Commit / Read
    input  logic [1:0]  commit_ack,
    output logic [TAG_W-1:0] head_ptr,
    output logic [TAG_W-1:0] head_plus_1,
    
    // Read data for head and head+1
    output rob_head_status_t head0,
    output rob_head_status_t head1,

    // ROB Status for P1
    output logic [ROB_DEPTH-1:0] rob_done_bits,

    // Flush control
    input  logic        reset_rob_pointers,
    input  logic [TAG_W-1:0] flush_head_adv
);

    // Storage
    typedef struct packed {
        logic               valid;
        logic               done;
        logic               is_store;
        logic               store_buffered;
        logic               store_drain_requested;
        logic               store_done;
        logic [REG_ADDR_W-1:0] rd_idx;
        logic               rd_is_fp;
        logic [XLEN-1:0]    result_data;
        logic               mispredict_flag;
        logic               exception_flag;
        logic               is_csr;
        logic               csr_write_enable;
        logic [4:0]         fpu_fflags;
        logic               is_mret;
    } rob_entry_t;

    rob_entry_t [ROB_DEPTH-1:0] rob_data;

    // Pointers
    logic [TAG_W-1:0] head;
    logic [TAG_W-1:0] tail;
    logic [TAG_W-1:0] flush_new_head;
    logic             full_flag;
    logic [TAG_W:0]   rob_occupancy;
    logic [TAG_W:0]   rob_free_slots;
    localparam logic [TAG_W:0] ROB_DEPTH_EXT = ROB_DEPTH;

    assign head_ptr    = head;
    assign head_plus_1 = head + {{(TAG_W-1){1'b0}}, 1'b1};
    assign flush_new_head = head + flush_head_adv;

    // Helper function to check if tag is within [head, tail) window
    function automatic logic is_tag_in_flight(
        input logic [TAG_W-1:0] tag,
        input logic [TAG_W-1:0] head,
        input logic [TAG_W-1:0] tail,
        input logic             full
    );
        if (full) begin
            return 1'b1;
        end else if (head == tail) begin
            return 1'b0;
        end else if (head < tail) begin
            return (tag >= head) && (tag < tail);
        end else begin
            return (tag >= head) || (tag < tail);
        end
    endfunction

    // Status
    assign rob_full  = (head == tail) && full_flag;
    assign rob_empty = (head == tail) && !full_flag;
    always_comb begin
        if (rob_full) begin
            rob_occupancy = ROB_DEPTH_EXT;
        end else if (rob_empty) begin
            rob_occupancy = '0;
        end else if (tail >= head) begin
            rob_occupancy = {1'b0, tail - head};
        end else begin
            rob_occupancy = ROB_DEPTH_EXT - {1'b0, head - tail};
        end
    end
    assign rob_free_slots = ROB_DEPTH_EXT - rob_occupancy;
    assign rob_can_alloc_1 = (rob_free_slots >= {{TAG_W{1'b0}}, 1'b1});
    assign rob_can_alloc_2 = (rob_free_slots >= {{(TAG_W-1){1'b0}}, 2'd2});

    assign alloc_tag_0 = tail;
    assign alloc_tag_1 = tail + 1'b1;

    // Read Logic
    always_comb begin
        for (int i = 0; i < ROB_DEPTH; i++) begin
            rob_done_bits[i] = rob_data[i].done;
        end
    end

    // rob_head_status_t has the same packed layout as rob_entry_t,
    // so direct assignment works and keeps the two structs in sync.
    assign head0 = rob_data[head];
    assign head1 = rob_data[head_plus_1];

    // Sequential Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
            full_flag <= 1'b0;
            for (int i = 0; i < ROB_DEPTH; i++) begin
                rob_data[i] <= '0;
            end
        end else if (reset_rob_pointers) begin
            head <= flush_new_head;
            tail <= flush_new_head;
            full_flag <= 1'b0;
            for (int i = 0; i < ROB_DEPTH; i++) begin
                rob_data[i].valid <= 1'b0;
                rob_data[i].done  <= 1'b0;
            end
        end else begin
`ifndef SYNTHESIS
            if (alloc_valid[0] && rob_data[tail].valid) begin
                $error("[ROB] allocation overwrite slot0 tag=%0d head=%0d tail=%0d full=%0b",
                       tail, head, tail, full_flag);
                $stop;
            end
            if (alloc_valid[1] && rob_data[tail + 1'b1].valid) begin
                $error("[ROB] allocation overwrite slot1 tag=%0d head=%0d tail=%0d full=%0b",
                       tail + 1'b1, head, tail, full_flag);
                $stop;
            end
`endif
            // 1. Writeback (P3)
            for (int i = 0; i < 4; i++) begin
                if (wb_payload[i].result_valid && is_tag_in_flight(wb_payload[i].tag_out, head, tail, full_flag)) begin
                    rob_data[wb_payload[i].tag_out].valid            <= 1'b1;
                    rob_data[wb_payload[i].tag_out].done             <= 1'b1;
                    rob_data[wb_payload[i].tag_out].store_buffered    <= wb_store_buffered[i];
                    rob_data[wb_payload[i].tag_out].rd_idx           <= wb_payload[i].rd_idx;
                    rob_data[wb_payload[i].tag_out].rd_is_fp         <= wb_payload[i].is_fp;
                    rob_data[wb_payload[i].tag_out].result_data      <= wb_payload[i].result_data;
                    rob_data[wb_payload[i].tag_out].mispredict_flag  <= wb_payload[i].mispredict_flag;
                    rob_data[wb_payload[i].tag_out].exception_flag   <= wb_payload[i].exception_flag;
                    rob_data[wb_payload[i].tag_out].is_csr           <= wb_payload[i].is_csr;
                    rob_data[wb_payload[i].tag_out].csr_write_enable <= wb_payload[i].csr_write_enable;
                    rob_data[wb_payload[i].tag_out].fpu_fflags       <= wb_payload[i].fpu_fflags;
                    rob_data[wb_payload[i].tag_out].is_mret          <= wb_payload[i].is_mret;
                end
            end

            if (store_drain_req_valid) begin
                rob_data[store_drain_req_tag].store_drain_requested <= 1'b1;
            end

            if (store_done_valid) begin
                rob_data[store_done_tag].store_done <= 1'b1;
                if (store_done_exception) begin
                    rob_data[store_done_tag].exception_flag <= 1'b1;
                end
            end

            // 2. Allocation (P1)
            if (alloc_valid[1]) begin
                rob_data[tail].valid <= 1'b1;
                rob_data[tail].done <= 1'b0;
                rob_data[tail].is_store <= alloc_is_store[0];
                rob_data[tail].store_buffered <= 1'b0;
                rob_data[tail].store_drain_requested <= 1'b0;
                rob_data[tail].store_done <= 1'b0;
                rob_data[tail].mispredict_flag <= 1'b0;
                rob_data[tail].exception_flag <= 1'b0;
                rob_data[tail].is_csr <= 1'b0;
                rob_data[tail].csr_write_enable <= 1'b0;
                rob_data[tail].is_mret <= 1'b0;
                rob_data[tail + 1'b1].valid <= 1'b1;
                rob_data[tail + 1'b1].done <= 1'b0;
                rob_data[tail + 1'b1].is_store <= alloc_is_store[1];
                rob_data[tail + 1'b1].store_buffered <= 1'b0;
                rob_data[tail + 1'b1].store_drain_requested <= 1'b0;
                rob_data[tail + 1'b1].store_done <= 1'b0;
                rob_data[tail + 1'b1].mispredict_flag <= 1'b0;
                rob_data[tail + 1'b1].exception_flag <= 1'b0;
                rob_data[tail + 1'b1].is_csr <= 1'b0;
                rob_data[tail + 1'b1].csr_write_enable <= 1'b0;
                rob_data[tail + 1'b1].is_mret <= 1'b0;
                tail <= tail + {{(TAG_W-2){1'b0}}, 2'd2};
            end else if (alloc_valid[0]) begin
                rob_data[tail].valid <= 1'b1;
                rob_data[tail].done <= 1'b0;
                rob_data[tail].is_store <= alloc_is_store[0];
                rob_data[tail].store_buffered <= 1'b0;
                rob_data[tail].store_drain_requested <= 1'b0;
                rob_data[tail].store_done <= 1'b0;
                rob_data[tail].mispredict_flag <= 1'b0;
                rob_data[tail].exception_flag <= 1'b0;
                rob_data[tail].is_csr <= 1'b0;
                rob_data[tail].csr_write_enable <= 1'b0;
                rob_data[tail].is_mret <= 1'b0;
                tail <= tail + {{(TAG_W-2){1'b0}}, 2'd1};
            end

            // 3. Commit (P4)
            if (commit_ack == 2'd2) begin
                rob_data[head].valid <= 1'b0;
                rob_data[head].done  <= 1'b0;
                rob_data[head_plus_1].valid <= 1'b0;
                rob_data[head_plus_1].done  <= 1'b0;
                head <= head + {{(TAG_W-2){1'b0}}, 2'd2};
            end else if (commit_ack == 2'd1) begin
                rob_data[head].valid <= 1'b0;
                rob_data[head].done  <= 1'b0;
                head <= head + {{(TAG_W-2){1'b0}}, 2'd1};
            end

            // Full flag update
            case ({alloc_valid[1], alloc_valid[0], commit_ack})
                4'b00_00: full_flag <= full_flag;
                4'b01_00: full_flag <= (tail + 1'b1 == head);
                4'b11_00: full_flag <= (tail + {{(TAG_W-2){1'b0}}, 2'd2} == head);
                4'b00_01: full_flag <= 1'b0;
                4'b01_01: full_flag <= (tail == head);
                4'b11_01: full_flag <= (tail + 1'b1 == head);
                4'b00_10: full_flag <= 1'b0;
                4'b01_10: full_flag <= (tail + {{(TAG_W-1){1'b0}}, 1'b1} == head + {{(TAG_W-2){1'b0}}, 2'd2});
                4'b11_10: full_flag <= (tail == head);
                default: full_flag <= full_flag;
            endcase
        end
    end

endmodule

`endif // ROB_SV
