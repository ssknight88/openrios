module Serial_Instruction_Tracker #(
    parameter int TAG_W = 4
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             serial_set,
    input  logic [TAG_W-1:0] self_tag0,

    input  logic             commit_valid0,
    input  logic             commit_valid1,
    input  logic [TAG_W-1:0] commit_tag0,
    input  logic [TAG_W-1:0] commit_tag1,

    input  logic             global_flush_late,

    output logic             serial_inflight_valid
);

    logic [TAG_W-1:0] serial_inflight_tag;

    wire commit_hit0 = serial_inflight_valid && commit_valid0 && (commit_tag0 == serial_inflight_tag);
    wire commit_hit1 = serial_inflight_valid && commit_valid1 && (commit_tag1 == serial_inflight_tag);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            serial_inflight_valid <= 1'b0;
            serial_inflight_tag   <= '0;
        end else if (global_flush_late) begin
            serial_inflight_valid <= 1'b0;
            serial_inflight_tag   <= '0;
        end else begin
            if (commit_hit0 || commit_hit1) begin
                serial_inflight_valid <= 1'b0;
            end
            if (serial_set && !serial_inflight_valid) begin
                serial_inflight_valid <= 1'b1;
                serial_inflight_tag   <= self_tag0;
            end
        end
    end

endmodule
