`ifndef FP_READ_ADDRESS_MUX_SV
`define FP_READ_ADDRESS_MUX_SV

/* verilator lint_off IMPORTSTAR */
import or_be_types_pkg::*;
/* verilator lint_on IMPORTSTAR */

// FP_read_address_mux -- pure combinational 6 candidate addresses -> 3 FP read
// ports (FP_read_address_mux微架构文档).
//
// (1) per-entry state          : none
// (2) state transition         : none
// (3) condition                : none
// (4) data path                : one 2:1 select per source index k in {1,2,3},
//                                all three driven by a single select bit
// (5) data structure           : none -- no per-entry storage
//
// The two candidate slots offer six possible FP source addresses
// (slot0/1.rs1/2/3_idx) while the FP side has only three read ports.  This
// module does that narrowing; its output drives the read address port of
// **both** FP_ARF and FP_tag_mapping (集成层 §1.1).
//
// No clock and no reset on purpose: ①②③ are all "none", so the module holds no
// state and is not on any flush broadcast list.
module FP_read_address_mux (
    // in-event: broadcast -- the six candidate addresses from IB.  The doc
    // writes them as `slot0/1.rs1/2/3_idx`(5x6); the source number is the port
    // name and the slot is the unpacked index (0 = slot0, 1 = slot1), so the
    // width annotation stays per-port and nothing is packed together.
    input  logic [REG_ADDR_W-1:0] rs1_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs2_idx     [ISSUE_WIDTH],
    input  logic [REG_ADDR_W-1:0] rs3_idx     [ISSUE_WIDTH],

    // in-event: select -- `is_fp_instruction[0]`(1), slot0's bit and nothing
    // else.  ④ is explicit that slot1's bit does not participate, so slot1's
    // copy is not a port here: there is no second wire to ignore.
    input  logic                  is_fp_instruction,

    // out-event: `fp_read_idx[1:3]`(5x3, read addresses).  Numbered 1..3 to
    // match the source number x used by ④ and by 集成层 §2.1; or_be_types_pkg
    // has no constant for this multiplicity, so the range is the documented
    // one, exactly as FP_ARF declares its matching port.
    output logic [REG_ADDR_W-1:0] fp_read_idx [1:3]
);

    // Unpacked slot index of the six candidate addresses.
    localparam int SLOT0 = 0;
    localparam int SLOT1 = 1;

    // ------------------------------------------------------------------
    // (4)#1 fp_read_idx[k] = is_fp_instruction[0] ? slot0.rs{k}_idx
    //                                             : slot1.rs{k}_idx , k in {1,2,3}
    //
    // One select bit for all three ports, and it is slot0's bit alone.  ④ shows
    // why that is enough -- the port the FP side reads always belongs to the
    // slot this bit picks:
    //
    //   let the accepted slot s have rsX_is_fp[s] = 1.  The upstream contract
    //   "touching the FP RF => is_fp_instruction true" gives is_fp_instruction[s]=1.
    //     s = 0 => select bit = 1                          => slot0 chosen  OK
    //     s = 1 => a double-FP dispatch is blocked, so the two slots are never
    //              both FP in one cycle => select bit = 0   => slot1 chosen  OK
    //
    // The two remaining cases produce no consumer at all: select bit 1 with
    // slot0 not accepted means neither slot was accepted (accept[1] => accept[0]),
    // and both bits 0 means no FP source needs resolving this cycle.  So the
    // addresses driven out are either the right ones or unread -- there is no
    // case that would need a per-slot select, and none that would need a fourth
    // read port.
    // ------------------------------------------------------------------
    always_comb begin
        fp_read_idx[1] = is_fp_instruction ? rs1_idx[SLOT0] : rs1_idx[SLOT1];
        fp_read_idx[2] = is_fp_instruction ? rs2_idx[SLOT0] : rs2_idx[SLOT1];
        fp_read_idx[3] = is_fp_instruction ? rs3_idx[SLOT0] : rs3_idx[SLOT1];
    end

endmodule

`endif // FP_READ_ADDRESS_MUX_SV
