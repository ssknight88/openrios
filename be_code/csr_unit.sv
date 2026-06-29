`ifndef CSR_UNIT_SV
`define CSR_UNIT_SV

import orca_types::*;
import exe_subop_pkg::*;

module csr_unit (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               flush_late,

    // P2/P3 Execution Interface
    input  logic               en,
    input  logic [TAG_W-1:0]   self_rob_tag,
    input  logic [XLEN-1:0]    rs1_data,       // GPR rs1 value OR 5-bit zero-extended zimm
    input  logic [EXE_SUBOP_W-1:0] exe_subop,
    input  logic [REG_ADDR_W-1:0]  rd_idx,
    input  logic [XLEN-1:0]    imm_data,       // CSR Address is stored in imm_data[11:0]
    input  logic               csr_write_intent,

    output result_payload_t    wb_payload,
    output logic               busy,

    // P4 Architectural Commit Interface (Writeback Sidecar)
    input  logic               p4_csr_write,
    input  logic [11:0]        csr_pend_addr,
    input  logic [XLEN-1:0]    csr_pend_wdata,

    // Precise Exception Inputs
    input  logic               exception_taken,
    input  logic [XLEN-1:0]    exception_pc,
    input  logic [XLEN-1:0]    exception_cause,
    input  logic [XLEN-1:0]    exception_tval,
    input  logic               mret_taken,

    // Architectural Outputs
    output logic [XLEN-1:0]    csr_mtvec_out,
    output logic [XLEN-1:0]    csr_mepc_out,
    output logic               csr_mie_out,
    output logic               csr_meie_out,
    output logic               csr_fs_enabled,
    output logic [2:0]         csr_frm_out,     // fcsr.frm, drives dynamic FP rounding

    // External Interrupt Input
    input  logic               ext_irq_valid,

    // FP retire side-effects (from P4): accrue fflags + set mstatus.FS=Dirty
    input  logic               fp_commit_valid,
    input  logic [4:0]         fp_commit_fflags,

    // Performance counter interface
    input  logic [1:0]         commit_count,

    // Global Control
    input  logic               clear_csr_trackers
);

    // 1. Physical Architectural CSR Registers (Commit-updated)
    logic [XLEN-1:0] csr_mstatus;
    logic [XLEN-1:0] csr_mcause;
    logic [XLEN-1:0] csr_mepc;
    logic [XLEN-1:0] csr_mtvec;
    logic [XLEN-1:0] csr_mie;
    logic [XLEN-1:0] csr_mip;
    logic [4:0]      csr_fflags;
    logic [2:0]      csr_frm;
    logic [XLEN-1:0] csr_mscratch;   // 0x340
    logic [XLEN-1:0] csr_mtval;      // 0x343 (trap-populate wired in a later stage)

    // misa (0x301): read-only WARL. MXL=2 (RV64); extensions = I, M, F, D.
    // bit3=D, bit5=F, bit8=I, bit12=M -> 0x1128 ; MUST match the Spike --isa used in lockstep.
    localparam logic [XLEN-1:0] CSR_MISA_VALUE = {2'b10, 36'b0, 26'h0001128};
    // mstatus writable (WARL) field mask: MIE(3), MPIE(7), MPP(12:11), FS(14:13).
    localparam logic [XLEN-1:0] CSR_MSTATUS_WMASK = 64'h0000_0000_0000_7888;

    // Performance counters (mcycle=0xB00, minstret=0xB02)
    // Aliased as rdcycle(0xC00) / rdinstret(0xC02) in read path
    logic [XLEN-1:0] csr_mcycle;
    logic [XLEN-1:0] csr_minstret;

    assign csr_mtvec_out = csr_mtvec;
    assign csr_mepc_out  = csr_mepc;
    assign csr_mie_out   = csr_mstatus[3]; // mstatus.MIE is bit 3
    assign csr_meie_out  = csr_mie[11];     // mie.MEIE is bit 11
    assign csr_fs_enabled = (csr_mstatus[14:13] != 2'b00);
    assign csr_frm_out    = csr_frm;

    // 12-bit CSR address decoder from execute stage
    logic [11:0] exe_csr_addr;
    assign exe_csr_addr = imm_data[11:0];

    logic legal_csr_addr;

    always_comb begin
        unique case (exe_csr_addr)
            12'h001, 12'h002, 12'h003: legal_csr_addr = csr_fs_enabled;
            12'h300, 12'h301, 12'h340, 12'h341, 12'h342, 12'h343,
            12'h305, 12'h304, 12'h344: legal_csr_addr = 1'b1;
            12'hF11, 12'hF12, 12'hF13, 12'hF14: legal_csr_addr = !csr_write_intent;
            12'hC00, 12'hC02, 12'hB00, 12'hB02: legal_csr_addr = !csr_write_intent; // Read-only performance counters
            default: legal_csr_addr = 1'b0;
        endcase
    end

    // Read Logic (Speculative in P2/P3)
    logic [XLEN-1:0] csr_rdata;
    always_comb begin
        case (exe_csr_addr)
            12'h001: csr_rdata = {{(XLEN-5){1'b0}}, csr_fflags};
            12'h002: csr_rdata = {{(XLEN-3){1'b0}}, csr_frm};
            12'h003: csr_rdata = {{(XLEN-8){1'b0}}, csr_frm, csr_fflags};
            12'h300: csr_rdata = csr_mstatus;
            12'h301: csr_rdata = CSR_MISA_VALUE;
            12'h340: csr_rdata = csr_mscratch;
            12'h341: csr_rdata = csr_mepc;
            12'h342: csr_rdata = csr_mcause;
            12'h343: csr_rdata = csr_mtval;
            12'h305: csr_rdata = csr_mtvec;
            12'h304: csr_rdata = csr_mie;
            12'h344: csr_rdata = {csr_mip[XLEN-1:12], ext_irq_valid, csr_mip[10:0]};
            12'hC00, 12'hB00: csr_rdata = csr_mcycle;
            12'hC02, 12'hB02: csr_rdata = csr_minstret;
            12'hF11, 12'hF12, 12'hF13, 12'hF14: csr_rdata = '0;
            default: csr_rdata = '0;
        endcase
    end

    // Compute next write data based on Sub-Op
    logic [XLEN-1:0] next_csr_wdata;
    logic            csr_write_en;
    always_comb begin
        next_csr_wdata = csr_rdata;
        csr_write_en   = 1'b0;

        case (exe_subop)
            CSR_CSRRW, CSR_CSRRWI: begin
                next_csr_wdata = rs1_data;
                csr_write_en   = 1'b1;
            end
            CSR_CSRRS, CSR_CSRRSI: begin
                next_csr_wdata = csr_rdata | rs1_data;
                csr_write_en   = 1'b1;
            end
            CSR_CSRRC, CSR_CSRRCI: begin
                next_csr_wdata = csr_rdata & ~rs1_data;
                csr_write_en   = 1'b1;
            end
            default: begin
                next_csr_wdata = csr_rdata;
                csr_write_en   = 1'b0;
            end
        endcase
    end

    assign busy = 1'b0; // 1-cycle latency execution

    // P3 Pipeline output stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wb_payload <= '0;
        end else if (flush_late) begin
            wb_payload <= '0;
        end else begin
            wb_payload <= '0;
            if (en) begin
                wb_payload.result_valid     <= 1'b1;
                wb_payload.tag_out          <= self_rob_tag;
                wb_payload.rd_idx           <= rd_idx;
                wb_payload.is_fp            <= 1'b0;
                wb_payload.result_data      <= csr_rdata; // read data is bypassed and written to rd
                wb_payload.is_csr           <= 1'b1;
                wb_payload.csr_write_enable <= csr_write_en && csr_write_intent && legal_csr_addr;
                wb_payload.csr_addr         <= exe_csr_addr;
                wb_payload.csr_wdata        <= next_csr_wdata; // calculated next state
                wb_payload.mispredict_flag  <= 1'b0;
                wb_payload.exception_flag   <= !legal_csr_addr;
                wb_payload.correct_pc       <= '0;
                wb_payload.exception_cause  <= !legal_csr_addr ? 64'd2 : 64'd0;
            end
        end
    end

`ifndef SYNTHESIS
    logic flush_late_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_late_q <= 1'b0;
        end else begin
            flush_late_q <= flush_late;
            if (flush_late_q && wb_payload.result_valid) begin
                $error("[CSR] stale writeback after flush: wb_valid=%0b tag=%0d csr_addr=0x%03h",
                       wb_payload.result_valid, wb_payload.tag_out, wb_payload.csr_addr);
                $stop;
            end
        end
    end
`endif

    // P4 Commit-Time Architectural CSR Updates (Non-speculative)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mstatus <= 64'h0;
            csr_mepc    <= 64'h0;
            csr_mcause  <= 64'h0;
            csr_mtvec   <= 64'h0;
            csr_mie     <= 64'h0;
            csr_mip     <= 64'h0;
            csr_fflags  <= 5'h0;
            csr_frm     <= 3'h0;
            csr_mscratch <= 64'h0;
            csr_mtval    <= 64'h0;
        end else begin
            if (exception_taken) begin
                csr_mepc   <= exception_pc;
                csr_mcause <= exception_cause;
                csr_mtval  <= exception_tval;
                csr_mstatus[7] <= csr_mstatus[3]; // MPIE <= MIE
                csr_mstatus[3] <= 1'b0;          // MIE <= 0
            end else if (mret_taken) begin
                // MRET: restore the interrupt-enable stack and drop privilege (M-only core).
                csr_mstatus[3]     <= csr_mstatus[7]; // MIE <= MPIE
                csr_mstatus[7]     <= 1'b1;           // MPIE <= 1
                csr_mstatus[12:11] <= 2'b00;          // MPP <= U (WARL)
            end else if (p4_csr_write) begin
                case (csr_pend_addr)
                    12'h001: csr_fflags <= csr_pend_wdata[4:0];
                    12'h002: csr_frm    <= csr_pend_wdata[2:0];
                    12'h003: begin
                        csr_fflags <= csr_pend_wdata[4:0];
                        csr_frm    <= csr_pend_wdata[7:5];
                    end
                    12'h300: begin
                        // WARL: only implemented fields are writable; SD(63) is derived from FS.
                        csr_mstatus     <= (csr_pend_wdata & CSR_MSTATUS_WMASK);
                        csr_mstatus[63] <= (csr_pend_wdata[14:13] == 2'b11);
                    end
                    12'h301: ; // misa: read-only WARL, writes ignored
                    12'h340: csr_mscratch <= csr_pend_wdata;
                    12'h341: csr_mepc    <= csr_pend_wdata;
                    12'h342: csr_mcause  <= csr_pend_wdata;
                    12'h343: csr_mtval   <= csr_pend_wdata;
                    12'h305: csr_mtvec   <= csr_pend_wdata;
                    12'h304: csr_mie     <= csr_pend_wdata;
                    12'h344: csr_mip     <= {csr_pend_wdata[XLEN-1:12], csr_mip[11], csr_pend_wdata[10:0]};
                    default: ;
                endcase
            end

            // FP retire side-effects: accrue fflags into fcsr and mark FP state Dirty.
            // Applied independently of the trap / CSR-write path above. CSR serialization
            // guarantees no same-cycle mstatus/fcsr CSR-write conflicts with an FP retire,
            // and these target disjoint mstatus bits from the trap path (FS/SD vs MIE/MPIE).
            if (fp_commit_valid) begin
                csr_fflags         <= csr_fflags | fp_commit_fflags;
                csr_mstatus[14:13] <= 2'b11; // FS = Dirty
                csr_mstatus[63]    <= 1'b1;  // SD
            end
        end
    end

    // Performance counters increment logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_mcycle   <= '0;
            csr_minstret <= '0;
        end else begin
            csr_mcycle   <= csr_mcycle + 1'b1;
            csr_minstret <= csr_minstret + {{(XLEN-2){1'b0}}, commit_count};
        end
    end

endmodule

`endif // CSR_UNIT_SV
