`ifndef ISB_FIFO_SV
`define ISB_FIFO_SV

import orca_types::*;

module isb_fifo #(
    parameter int DEPTH = 8
) (
    input  logic        clk,
    input  logic        rst_n,

    // Enqueue (from Frontend)
    input  isb_payload_t [1:0] enq_payload,
    input  logic [1:0]        enq_valid,      // per-slot valid from frontend
    output logic [1:0]        enq_accepted,   // how many were actually accepted

    // Dequeue (to P1 Dispatch)
    output isb_payload_t [1:0] deq_payload,    // head and head+1
    input  logic [1:0]         deq_valid,      // how many P1 consumed this cycle

    // Status
    output logic        full,

    // Flush
    input  logic        flush_late
);

    localparam int PTR_W   = $clog2(DEPTH);
    localparam int COUNT_W = $clog2(DEPTH + 1);

    // Storage
    isb_payload_t fifo_mem [0:DEPTH-1];
    logic [PTR_W-1:0]   head_ptr;
    logic [PTR_W-1:0]   tail_ptr;
    logic [COUNT_W-1:0]  count;

    // Pointer advance with wrap
    function automatic logic [PTR_W-1:0] ptr_advance(
        input logic [PTR_W-1:0] ptr,
        input logic [1:0] inc
    );
        logic [PTR_W:0] sum;
        begin
            sum = ptr + inc;
            if (sum >= DEPTH) begin
                ptr_advance = PTR_W'(sum - DEPTH);
            end else begin
                ptr_advance = sum[PTR_W-1:0];
            end
        end
    endfunction

    // Head output (combinational read)
    logic [PTR_W-1:0] head_ptr_plus_1;
    assign head_ptr_plus_1 = ptr_advance(head_ptr, 2'd1);

    assign deq_payload[0] = (count != '0) ? fifo_mem[head_ptr]      : '0;
    assign deq_payload[1] = (count > 1)   ? fifo_mem[head_ptr_plus_1] : '0;

    // Enqueue acceptance logic
    logic [COUNT_W-1:0] count_after_dequeue;
    logic [COUNT_W-1:0] free_slots;

    always_comb begin
        count_after_dequeue = count - deq_valid;
        free_slots = COUNT_W'(DEPTH - count_after_dequeue);
        enq_accepted = 2'd0;

        if (rst_n && !flush_late && enq_valid[0] && (free_slots != '0)) begin
            enq_accepted = 2'd1;
            if (enq_valid[1] && (free_slots > 1)) begin
                enq_accepted = 2'd2;
            end
        end
    end

    assign full = (count == DEPTH[COUNT_W-1:0]);

    // Sequential: pointers, count, and memory writes
    logic [PTR_W-1:0] tail_ptr_plus_1;
    assign tail_ptr_plus_1 = ptr_advance(tail_ptr, 2'd1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= '0;
        end else if (flush_late) begin
            head_ptr <= '0;
            tail_ptr <= '0;
            count    <= '0;
        end else begin
            // Write enqueued entries
            if (enq_accepted != 2'd0) begin
                fifo_mem[tail_ptr] <= enq_payload[0];
                if (enq_accepted == 2'd2) begin
                    fifo_mem[tail_ptr_plus_1] <= enq_payload[1];
                end
            end

            // Advance pointers
            head_ptr <= ptr_advance(head_ptr, deq_valid);
            tail_ptr <= ptr_advance(tail_ptr, enq_accepted);
            count    <= count_after_dequeue + enq_accepted;
        end
    end

endmodule

`endif // ISB_FIFO_SV
