# Module `PC_File`

PC_File stores the instruction PC associated with each ROB tag. It accepts PCs

## Submodule
无。

## FSM
### State
#### Per-entry State
- Per-entry state: none.
- Structure state: none.
- Reset state: entry_inst_pc[t] = 0 for all t.

### State Transition & Condition Name
无。

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `condition`：
   No condition event is owned by this module.

## Data structure
### State

None.

### Header

None. self_tag and read tags are external addresses.

### Payload

- `entry_inst_pc[t]`：Width / Depth=XLEN x ROB_DEPTH (64 x 16); Storage location=entry indexed by t; Written by=alloc_pc[s].fire; Read by=inst_pc, trace_pc

At the active edge:
entry_inst_pc[alloc_pc[s].self_tag] <- alloc_pc[s].pc.
Reset clears all entries; flush does not clear them.

## Data Path
- `allocation payload` -> `entry_inst_pc[self_tag]`：pc_alloc_t；驱动 alloc_pc[s]；write on accept[s] at the edge
- `entry_inst_pc[flush_tag]` -> `output inst_pc`：XLEN；驱动 inst_pc；asynchronous read
- `entry_inst_pc[head0_tag]` -> `output trace_pc[0]`：XLEN；驱动 trace_pc[0]；asynchronous read
- `entry_inst_pc[head1_tag]` -> `output trace_pc[1]`：XLEN；驱动 trace_pc[1]；asynchronous read

## Interface

### In-event

- `alloc_pc[s]`：Notify；self_tag[TAG_W], pc[XLEN]；sampled on rising edge

### In Static Info

- `flush_tag`：TAG_W；address
- `head0_tag`：TAG_W；address
- `head1_tag`：TAG_W；address
Clock is clk and reset is asynchronous active-low rst_n.

### Out-event

- 无。

### Out Static Info

- Name=inst_pc; Type / Width=XLEN; Cardinality=1; Generation rule=entry_inst_pc[flush_tag]; Validity=always combinational
- Name=trace_pc; Type / Width=XLEN; Cardinality=ISSUE_WIDTH (2); Generation rule=trace_pc[0] = entry_inst_pc[head0_tag]; trace_pc[1] = entry_inst_pc[head1_tag]; Validity=always combinational
- `inst_pc`：XLEN；combinational
- `trace_pc`：XLEN；combinational

### Interface Timing

- 无。


