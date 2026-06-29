`ifndef ISQ_SV
`define ISQ_SV

import orca_types::*;

module isq (
    input  logic        clk,
    input  logic        rst_n,

    // P1: Dispatch (Write)
    input  logic        isq_wr_en,
    input  isq_payload_t isq_wr_payload,

    // P2: Select & Issue
    input  logic        fu_busy,
    output logic        isq_valid,
    output isq_payload_t isq_payload,
    output logic        issue_en,

    // Bypass Snooping (4 buses)
    input  bypass_t [3:0] bypass_bus,

    // Global Flush
    input  logic        flush_late
);

    logic               entry_valid;
    isq_payload_t       entry_payload;

    assign isq_valid   = entry_valid;
    assign isq_payload = entry_payload;

    // Wakeup Logic (Combinational - "fast_ready")
    logic rs1_wakeup, rs2_wakeup, rs3_wakeup;

    assign rs1_wakeup = (bypass_bus[0].valid && !entry_payload.rs1_ready && (entry_payload.rs1_wait_tag == bypass_bus[0].tag)) ||
                        (bypass_bus[1].valid && !entry_payload.rs1_ready && (entry_payload.rs1_wait_tag == bypass_bus[1].tag)) ||
                        (bypass_bus[2].valid && !entry_payload.rs1_ready && (entry_payload.rs1_wait_tag == bypass_bus[2].tag)) ||
                        (bypass_bus[3].valid && !entry_payload.rs1_ready && (entry_payload.rs1_wait_tag == bypass_bus[3].tag));

    assign rs2_wakeup = (bypass_bus[0].valid && !entry_payload.rs2_ready && (entry_payload.rs2_wait_tag == bypass_bus[0].tag)) ||
                        (bypass_bus[1].valid && !entry_payload.rs2_ready && (entry_payload.rs2_wait_tag == bypass_bus[1].tag)) ||
                        (bypass_bus[2].valid && !entry_payload.rs2_ready && (entry_payload.rs2_wait_tag == bypass_bus[2].tag)) ||
                        (bypass_bus[3].valid && !entry_payload.rs2_ready && (entry_payload.rs2_wait_tag == bypass_bus[3].tag));

    assign rs3_wakeup = (bypass_bus[0].valid && !entry_payload.rs3_ready && (entry_payload.rs3_wait_tag == bypass_bus[0].tag)) ||
                        (bypass_bus[1].valid && !entry_payload.rs3_ready && (entry_payload.rs3_wait_tag == bypass_bus[1].tag)) ||
                        (bypass_bus[2].valid && !entry_payload.rs3_ready && (entry_payload.rs3_wait_tag == bypass_bus[2].tag)) ||
                        (bypass_bus[3].valid && !entry_payload.rs3_ready && (entry_payload.rs3_wait_tag == bypass_bus[3].tag));

    // Ready status (Dispatch static + Combinational Wakeup)
    logic rs1_ready_final, rs2_ready_final, rs3_ready_final;
    assign rs1_ready_final = entry_payload.rs1_ready || rs1_wakeup;
    assign rs2_ready_final = entry_payload.rs2_ready || rs2_wakeup;
    assign rs3_ready_final = entry_payload.rs3_ready || rs3_wakeup;

    // Select Logic
    assign issue_en = entry_valid && rs1_ready_final && rs2_ready_final && rs3_ready_final && !fu_busy && !flush_late;

    // Sequential Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            entry_valid   <= 1'b0;
            entry_payload <= '0;
        end else if (flush_late) begin
            entry_valid   <= 1'b0;
            entry_payload <= '0;
        end else begin
            // Persist bypass wakeups so sources can become ready across different cycles.
            if (entry_valid) begin
                if (rs1_wakeup) begin
                    entry_payload.rs1_ready <= 1'b1;
                    entry_payload.rs1_data  <= bypass_bus[0].valid && (entry_payload.rs1_wait_tag == bypass_bus[0].tag) ? bypass_bus[0].data :
                                               bypass_bus[1].valid && (entry_payload.rs1_wait_tag == bypass_bus[1].tag) ? bypass_bus[1].data :
                                               bypass_bus[2].valid && (entry_payload.rs1_wait_tag == bypass_bus[2].tag) ? bypass_bus[2].data :
                                               bypass_bus[3].data;
                end
                if (rs2_wakeup) begin
                    entry_payload.rs2_ready <= 1'b1;
                    entry_payload.rs2_data  <= bypass_bus[0].valid && (entry_payload.rs2_wait_tag == bypass_bus[0].tag) ? bypass_bus[0].data :
                                               bypass_bus[1].valid && (entry_payload.rs2_wait_tag == bypass_bus[1].tag) ? bypass_bus[1].data :
                                               bypass_bus[2].valid && (entry_payload.rs2_wait_tag == bypass_bus[2].tag) ? bypass_bus[2].data :
                                               bypass_bus[3].data;
                end
                if (rs3_wakeup) begin
                    entry_payload.rs3_ready <= 1'b1;
                    entry_payload.rs3_data  <= bypass_bus[0].valid && (entry_payload.rs3_wait_tag == bypass_bus[0].tag) ? bypass_bus[0].data :
                                               bypass_bus[1].valid && (entry_payload.rs3_wait_tag == bypass_bus[1].tag) ? bypass_bus[1].data :
                                               bypass_bus[2].valid && (entry_payload.rs3_wait_tag == bypass_bus[2].tag) ? bypass_bus[2].data :
                                               bypass_bus[3].data;
                end
            end

            // 1. Issue: entry becomes invalid unless new write happens
            if (issue_en) begin
                entry_valid <= 1'b0;
            end

            // 2. Dispatch: Refill rule
            if (isq_wr_en) begin
                entry_valid   <= 1'b1;
                entry_payload <= isq_wr_payload;
            end
        end
    end

endmodule

`endif // ISQ_SV
