// ORBE COSIM observation boundary.
//
// This interface intentionally carries only primitive observation fields.
// It must not depend on MOCK_RTL, BETA, P600, or any RTL-specific payload type.
interface ob_cosim_if #(
    parameter int unsigned ISSUE_NUM = 1,
    parameter int unsigned ROB_ADDR_W = 1,
    // The address-keyed CSR snapshot capacity stays independent of the
    // eventual ISA-case CSR list. Unused entries are marked invalid.
    parameter int unsigned CSR_STATE_NUM = 16
) (input logic clk);
  logic rst_n;

  // A valid group represents one architectural commit event. The BE sampler
  // consumes valid groups in increasing group order.
  logic [ISSUE_NUM-1:0] commit_valid;
  logic [ISSUE_NUM-1:0][63:0] commit_pc;
  logic [ISSUE_NUM-1:0][ROB_ADDR_W-1:0] commit_rob_idx;

  // Architectural register-file snapshots. These are continuous DUT
  // observations; they are not per-commit payloads and have no valid bit.
  logic [31:0][63:0] int_arf;
  logic [31:0][63:0] fp_arf;

  // CSR state is carried as an address-keyed table so the real DUT binding
  // can freeze the compared CSR set per ISA case without changing this
  // product-neutral interface. csr_valid qualifies the complete snapshot;
  // csr_state_valid qualifies individual entries in the table.
  logic                         csr_valid;
  logic [CSR_STATE_NUM-1:0]     csr_state_valid;
  logic [CSR_STATE_NUM-1:0][11:0] csr_state_addr;
  logic [CSR_STATE_NUM-1:0][63:0] csr_state;

  // Optional CSR instruction observation for diagnostics. The checker must
  // not infer architectural state solely from this event payload.
  logic        csr_event_valid;
  logic [11:0] csr_event_addr;
  logic [63:0] csr_event_wdata;
  logic [63:0] csr_event_rdata;

  // Memory state changes are independent of the ROB commit pulse. In
  // particular, a tohost store can set the model exit state before its
  // normal commit observation is visible to the environment.
  logic        mem_store_commit_valid;
  logic [63:0] mem_store_commit_order;
  logic [63:0] mem_store_commit_vaddr;
  logic [63:0] mem_store_commit_data;
  logic [7:0]  mem_store_commit_mask;
  logic [63:0] mem_store_commit_pc;
  logic [63:0] mem_store_commit_rob_idx;
  logic        mem_store_commit_terminal;
endinterface
