# Module `backend_top`

`backend_top`：`ISSUE_WIDTH=2`、`NUM_LANES=4` 的 OR-BE 后端无状态集成 module。

## Submodule

1. `IB`：`temp/new_v4.1/p1/IB.md`
2. `decode`：`temp/new_v4.1/p1/decode.md`
3. `dependency_check`：`temp/new_v4.1/p1/dependency_check.md`
4. `dispatch_logic`：`temp/new_v4.1/p1/dispatch_logic.md`
5. `INT_ARF`：`temp/new_v4.1/p1/INT_ARF.md`
6. `FP_ARF`：`temp/new_v4.1/p1/FP_ARF.md`
7. `INT_tag_mapping`：`temp/new_v4.1/p1/INT_tag_mapping.md`
8. `FP_tag_mapping`：`temp/new_v4.1/p1/FP_tag_mapping.md`
9. `FP_read_address_mux`：`temp/new_v4.1/p1/FP_read_address_mux.md`
10. `isq_payload_assembly`：`temp/new_v4.1/top/isq_payload_assembly.md`
11. `p1_ISQ_input_mux`：`temp/new_v4.1/p1/p1_ISQ_input_mux.md`，实例名 `u_p1_ISQ_input_mux_G0`
12. `p1_ISQ_input_mux`：`temp/new_v4.1/p1/p1_ISQ_input_mux.md`，实例名 `u_p1_ISQ_input_mux_G1`
13. `p1_ISQ_input_mux`：`temp/new_v4.1/p1/p1_ISQ_input_mux.md`，实例名 `u_p1_ISQ_input_mux_G2`
14. `p1_ISQ_input_mux`：`temp/new_v4.1/p1/p1_ISQ_input_mux.md`，实例名 `u_p1_ISQ_input_mux_G3`
15. `ISQ_Group0`：`temp/new_v4.1/p2p3/ISQ_Group0.md`
16. `ISQ_Group1`：`temp/new_v4.1/p2p3/ISQ_Group1.md`
17. `ISQ_Group2`：`temp/new_v4.1/p2p3/ISQ_Group2.md`
18. `ISQ_Group3`：`temp/new_v4.1/p2p3/ISQ_Group3.md`
19. `alu_simple`：`temp/from_zelin/fu/alu_simple.md`，实例名 `u_alu0_bru`
20. `alu_simple`：`temp/from_zelin/fu/alu_simple.md`，实例名 `u_alu1`
21. `csr_unit`：`temp/from_zelin/fu/csr_unit.md`
22. `div_simple`：`temp/from_zelin/fu/div_simple.md`
23. `mul_simple`：`temp/from_zelin/fu/mul_simple.md`
24. `fpu_simple`：`temp/from_zelin/fu/fpu_simple.md`
25. `p3_arbiter_G0`：`temp/new_v4.1/p2p3/p3_arbiter_G0.md`
26. `p3_arbiter_G1`：`temp/new_v4.1/p2p3/p3_arbiter_G1.md`
27. `lsu_bridge`：`temp/from_zelin/lsu/lsu_bridge.md`
28. `Buffer`：`temp/new_v4.1/p4/Buffer.md`
29. `PC_File`：`temp/new_v4.1/p4/PC_File.md`
30. `SerialInstructionTracker`：`temp/new_v4.1/p4/SerialInstructionTracker.md`
31. `flush_model`：`temp/new_v4.1/p4/flush_model.md`
32. `system_instruction_handler`：`temp/new_v4.1/p4/system_instruction_handler.md`
33. `CompletionScoreboard`：`temp/new_v4.1/p4/CompletionScoreboard.md`

## FSM

### State

无。

### State Transition & Condition Name

无。

### Detailed Condition Description

无。

## Data structure

### State

无。

### Header

无。

### Payload

无。

## Internal Connections

1. `fe_instr_pld[s] -> IB.enq_IB_Payload[s]`：`fe_be_instr_pld_t` 的 `pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval` 逐字段连接至同名 `ib_payload_t` 字段，`s∈{0,...,ISSUE_WIDTH-1}`；组合传递；当前拍有效。
2. `fe_valid[s] -> IB.fe_valid[s]`：`fe_valid[s]` Event；组合传递；当前拍有效。
3. `alloc_valid[s] -> IB.accept[s]`、`INT_tag_mapping.accept[s]`、`FP_tag_mapping.accept[s]`、`PC_File.accept[s]`、`CompletionScoreboard.accept[s]`：无 payload Event；组合传递；当前拍 pulse。
4. `IB.head_IB_Payload[s] -> decode.decode_payload[s]`、`isq_payload_assembly.head_IB_Payload[s]`，`IB.head_IB_Payload[s].pc -> PC_File.pc[s]`：`ib_payload_t` 及其 `pc` 字段；组合传递；当前拍有效。
5. `IB.inst_valid[s] -> dependency_check.inst_valid[s]`、`dispatch_logic.inst_valid[s]`：1 bit；组合传递；当前拍有效。
6. `decode.rd_idx[s] -> dependency_check.rd_idx[s]`、`INT_tag_mapping.alloc_rd_idx[s]`、`FP_tag_mapping.alloc_rd_idx[s]`、`CompletionScoreboard.rd_idx[s]`：`REG_ADDR_W` bit；组合传递；当前拍有效。
7. `decode.rs1_idx[s] -> dependency_check.rs1_idx[s]`、`INT_ARF.rs_idx[s][1]`、`INT_tag_mapping.rs_idx[s][1]`、`FP_read_address_mux.rs1_idx[s]`：`REG_ADDR_W` bit；组合传递；当前拍有效。
8. `decode.rs2_idx[s] -> dependency_check.rs2_idx[s]`、`INT_ARF.rs_idx[s][2]`、`INT_tag_mapping.rs_idx[s][2]`、`FP_read_address_mux.rs2_idx[s]`：`REG_ADDR_W` bit；组合传递；当前拍有效。
9. `decode.rs3_idx[s] -> dependency_check.rs3_idx[s]`、`FP_read_address_mux.rs3_idx[s]`：`REG_ADDR_W` bit；组合传递；当前拍有效。
10. `decode.dec_info[s] -> dependency_check`、`dispatch_logic`、`isq_payload_assembly`：`decoded_info_t`；`rd_is_fp`、`use_rd`、`is_serial`、`is_fp_instruction`、`use_rs1`、`use_rs2`、`use_rs3`、`rs1_is_fp`、`rs2_is_fp`、`rs3_is_fp`、`is_store`、`exe_subop` 和 `full_decode` 按各子模块公开 Interface 连接；组合传递；当前拍有效。
11. `decode.dec_is_fp_opcode[s] -> dependency_check.is_fp_opcode[s]`：1 bit；组合传递；当前拍有效。
12. `decode.dec_is_fp_opcode[0] -> FP_read_address_mux.is_fp_opcode`：1 bit；组合传递；当前拍有效。
13. `dependency_check.serial0 -> dispatch_logic.serial0`、`dependency_check.serial_inst -> dispatch_logic.serial_inst`、`dependency_check.fp0 -> dispatch_logic.fp0`、`dependency_check.fp1 -> dispatch_logic.fp1`、`dependency_check.slot_missed_wakeup[s] -> dispatch_logic.slot_missed_wakeup[s]`：组合传递；当前拍有效。
14. `CompletionScoreboard.Buffer_tail -> dependency_check.Buffer_tail`、`CompletionScoreboard.scoreboard_valid_bits -> dependency_check.scoreboard_valid_bits`、`CompletionScoreboard.scoreboard_exec_done_bits -> dependency_check.scoreboard_exec_done_bits`：组合传递；当前拍有效。
15. `INT_tag_mapping.tag[s][x] -> dependency_check.int_rename_read_tag[s][x]`、`INT_tag_mapping.busy[s][x] -> dependency_check.int_rename_read_busy[s][x]`，`x∈{1,...,INT_SRC_PER_SLOT}`；组合传递；当前拍有效。
16. `FP_tag_mapping.tag[x] -> dependency_check.fp_rename_read_tag[x]`、`FP_tag_mapping.busy[x] -> dependency_check.fp_rename_read_busy[x]`，`x∈{1,...,FP_READ_PORTS}`；组合传递；当前拍有效。
17. `dependency_check.rsX_ready[s][x] -> isq_payload_assembly.rsX_ready[s][x]`、`dependency_check.rsX_wait_tag[s][x] -> isq_payload_assembly.rsX_wait_tag[s][x]`、`dependency_check.rs_data_sel_t[s][x] -> isq_payload_assembly.rs_data_sel_t[s][x]`：组合传递；当前拍有效。
18. `alloc_tag[0] -> dispatch_logic.self_tag`：`TAG_W` bit；组合传递；当前拍有效。
19. `alloc_tag[s] -> INT_tag_mapping.self_tag[s]`、`FP_tag_mapping.self_tag[s]`、`isq_payload_assembly.self_tag[s]`、`PC_File.self_tag[s]`、`CompletionScoreboard.alloc_self_tag[s]`：`TAG_W` bit；组合传递；当前拍有效。
20. `dependency_check.rd_write_enable[s] -> INT_tag_mapping.alloc_rd_write_enable[s]`、`FP_tag_mapping.alloc_rd_write_enable[s]`、`CompletionScoreboard.rd_write_enable[s]`：1 bit；组合传递；当前拍有效。
21. `system_instruction_handler.fs_enabled -> dispatch_logic.fs_enabled`、`system_instruction_handler.frm -> dispatch_logic.frm`：组合传递；当前拍有效。
22. `CompletionScoreboard.can_alloc_1 -> dispatch_logic.can_alloc_1`、`CompletionScoreboard.can_alloc_2 -> dispatch_logic.can_alloc_2`、`CompletionScoreboard.buffer_empty -> dispatch_logic.buffer_empty`：组合传递；当前拍有效。
23. `ISQ_Group0.isq_free_for_dispatch -> dispatch_logic.isq_free_for_dispatch[0]`、`ISQ_Group1.isq_free_for_dispatch -> dispatch_logic.isq_free_for_dispatch[1]`、`ISQ_Group2.isq_free_for_dispatch -> dispatch_logic.isq_free_for_dispatch[2]`、`ISQ_Group3.isq_free_for_dispatch -> dispatch_logic.isq_free_for_dispatch[3]`：各 1 bit；组合传递；当前拍有效。
24. `SerialInstructionTracker.serial_inflight_valid -> dispatch_logic.serial_inflight_valid`：1 bit；组合传递；当前拍有效。
25. `dispatch_logic.serial_set_valid -> SerialInstructionTracker.serial_set_valid`：`serial_set_tag` payload Event；组合传递；当前拍 pulse。
26. `FP_read_address_mux.fp_read_idx[x] -> FP_ARF.fp_read_idx[x]`、`FP_tag_mapping.fp_read_idx[x]`：`REG_ADDR_W` bit；组合传递；当前拍有效。
27. `INT_ARF.ARF[s][x] -> isq_payload_assembly.INT_ARF[s][x]`、`FP_ARF.ARF[x] -> isq_payload_assembly.FP_ARF[x]`：`XLEN` bit；组合传递；当前拍有效。
28. `dispatch_logic.slot_FU_Group[s] -> isq_payload_assembly.slot_FU_Group[s]`、`dispatch_logic.effective_rm[s] -> isq_payload_assembly.effective_rm[s]`，`dispatch_logic.is_fence_i[s] -> CompletionScoreboard.is_fence_i[s]`、`dispatch_logic.may_flush[s] -> CompletionScoreboard.may_flush[s]`、`dispatch_logic.is_atomic[s] -> CompletionScoreboard.is_atomic[s]`：组合传递；当前拍有效。
29. `commit_data[s] -> INT_ARF.commit_data[s]`、`FP_ARF.commit_data[s]`、`isq_payload_assembly.commit_data[s]`，`lane_bypass_data[l] -> isq_payload_assembly.bypass_data[l]`：`XLEN` bit；组合传递；当前拍有效。
30. `isq_payload_assembly.slot_payload[s] -> u_p1_ISQ_input_mux_G0.slot_payload[s]`、`u_p1_ISQ_input_mux_G1.slot_payload[s]`、`u_p1_ISQ_input_mux_G2.slot_payload[s]`、`u_p1_ISQ_input_mux_G3.slot_payload[s]`：`isq_payload_t`；组合传递；当前拍有效。
31. `dispatch_logic.select_payload[g][s] -> u_p1_ISQ_input_mux_G0.select_payload[s]`、`u_p1_ISQ_input_mux_G1.select_payload[s]`、`u_p1_ISQ_input_mux_G2.select_payload[s]`、`u_p1_ISQ_input_mux_G3.select_payload[s]`：分别使用 `g=0`、`1`、`2`、`3`；组合传递；当前拍有效。
32. `u_p1_ISQ_input_mux_G0.ISQ_payload_in -> ISQ_Group0.payload_in`、`u_p1_ISQ_input_mux_G1.ISQ_payload_in -> ISQ_Group1.payload_in`、`u_p1_ISQ_input_mux_G2.ISQ_payload_in -> ISQ_Group2.payload_in`、`u_p1_ISQ_input_mux_G3.ISQ_payload_in -> ISQ_Group3.payload_in`：`isq_payload_t`；组合传递；当前拍有效。
33. `dispatch_logic.isq_wr_en[g] -> ISQ_Group0.dispatch_valid`、`ISQ_Group1.dispatch_valid`、`ISQ_Group2.dispatch_valid`、`ISQ_Group3.dispatch_valid`：分别使用 `g=0`、`1`、`2`、`3`；无 payload Event；组合传递；当前拍 pulse。
34. `lane_bypass_valid[l]`、`lane_bypass_tag[l]`、`lane_bypass_data[l] -> ISQ_Group0.bypass_publish_valid[l]`、`ISQ_Group1.bypass_publish_valid[l]`、`ISQ_Group2.bypass_publish_valid[l]`、`ISQ_Group3.bypass_publish_valid[l]`：bypass Event 及 payload；组合传递；当前拍有效。
35. `lane_bypass_valid[l]`、`lane_bypass_tag[l] -> dependency_check.bypass_publish_valid[l]`：bypass Event 及 `bypass_tag` payload；组合传递；当前拍有效。
36. `u_alu0_bru.FU_ready -> ISQ_Group0.FU_ready[G0_FU_ALU]`、`csr_unit.FU_ready -> ISQ_Group0.FU_ready[G0_FU_CSR]`、`div_simple.FU_ready -> ISQ_Group0.FU_ready[G0_FU_DIV]`：组合传递；当前拍有效。
37. `u_alu1.FU_ready -> ISQ_Group1.FU_ready[G1_FU_ALU]`、`mul_simple.FU_ready -> ISQ_Group1.FU_ready[G1_FU_MUL]`：组合传递；当前拍有效。
38. `fpu_simple.FU_ready -> ISQ_Group2.FU_ready`、`lsu_bridge.FU_ready -> ISQ_Group3.FU_ready`：组合传递；当前拍有效。
39. `ISQ_Group0.issue_valid -> u_alu0_bru.issue_valid`、`csr_unit.issue_valid`、`div_simple.issue_valid`：`ISQ_Group0` issue Event payload 的对应字段逐字段连接；组合传递；当前拍有效。
40. `ISQ_Group1.issue_valid -> u_alu1.issue_valid`、`mul_simple.issue_valid`：`ISQ_Group1` issue Event payload 的对应字段逐字段连接；`u_alu1` 的 `pc`、`inst_bits`、`is_compressed`、`pred_taken`、`pred_target_pc`、`full_decode`、`fetch_excp_vld`、`fetch_excp_cause`、`fetch_excp_tval`、`mstatus_tsr`、`mstatus_tw` 和 `mstatus_tvm` 接 `0`，`current_priv` 接 `2'b11`；组合传递；当前拍有效。
41. `ISQ_Group2.issue_valid -> fpu_simple.issue_valid`：`ISQ_Group2` issue Event 及 payload；组合传递；当前拍有效。
42. `ISQ_Group3.issue_valid -> lsu_bridge.issue_valid`：`ISQ_Group3` issue Event 及 payload；组合传递；当前拍有效。
43. `system_instruction_handler.current_priv -> u_alu0_bru.current_priv`、`csr_unit.current_priv`，`system_instruction_handler.mstatus_tsr -> u_alu0_bru.mstatus_tsr`，`system_instruction_handler.mstatus_tw -> u_alu0_bru.mstatus_tw`，`system_instruction_handler.mstatus_tvm -> u_alu0_bru.mstatus_tvm`、`csr_unit.mstatus_tvm`，`system_instruction_handler.fs_enabled -> csr_unit.fs_enabled`：组合传递；当前拍有效。
44. `u_alu0_bru.request_valid -> p3_arbiter_G0.request_valid[G0_FU_ALU]`、`csr_unit.request_valid -> p3_arbiter_G0.request_valid[G0_FU_CSR]`、`div_simple.request_valid -> p3_arbiter_G0.request_valid[G0_FU_DIV]`：completion request Event 及完整 payload；组合传递；当前拍有效。
45. `u_alu1.request_valid -> p3_arbiter_G1.request_valid[G1_FU_ALU]`、`mul_simple.request_valid -> p3_arbiter_G1.request_valid[G1_FU_MUL]`：completion request Event 及完整 payload；组合传递；当前拍有效。
46. `p3_arbiter_G0.winner_grant[k] -> u_alu0_bru.winner_grant`、`csr_unit.winner_grant`、`div_simple.winner_grant`，`p3_arbiter_G0.loser_hold[k] -> u_alu0_bru.loser_hold`、`csr_unit.loser_hold`、`div_simple.loser_hold`：分别使用 `k=G0_FU_ALU`、`G0_FU_CSR`、`G0_FU_DIV`；组合传递；当前拍有效。
47. `p3_arbiter_G1.winner_grant[k] -> u_alu1.winner_grant`、`mul_simple.winner_grant`，`p3_arbiter_G1.loser_hold[k] -> u_alu1.loser_hold`、`mul_simple.loser_hold`：分别使用 `k=G1_FU_ALU`、`G1_FU_MUL`；组合传递；当前拍有效。
48. `p3_arbiter_G0`、`p3_arbiter_G1`、`fpu_simple`、`lsu_bridge` 的 `result_data`、`mispredict_flag`、`mispredict_target_pc`、`exception_flag`、`exception_cause`、`exception_tval`、`is_mret`、`is_sret`、`fpu_fflags -> lane_result_data[l]` 和同名 `lane_*[l]`：分别使用 `l=0`、`1`、`2`、`3`；组合传递；当前拍有效。
49. `p3_arbiter_G0.bypass_publish_valid -> lane_bypass_valid[0]`、`p3_arbiter_G1.bypass_publish_valid -> lane_bypass_valid[1]`、`fpu_simple.bypass_publish_valid -> lane_bypass_valid[2]`、`lsu_bridge.bypass_publish_valid -> lane_bypass_valid[3]`：bypass Event 及 `bypass_tag`、`bypass_data` payload 逐 lane 聚合；组合传递；当前拍有效。
50. `exec_valid[l]`、`exec_tag[l]`、`lane_result_data[l] -> Buffer.writeback_valid[l]`：writeback Event 及 payload；组合传递；当前拍有效。
51. `exec_valid[l]`、`exec_tag[l]`、`lane_mispredict_flag[l]`、`lane_mispredict_target_pc[l]`、`lane_exception_flag[l]`、`lane_exception_cause[l]`、`lane_exception_tval[l]`、`lane_is_mret[l]`、`lane_is_sret[l]`、`lane_fpu_fflags[l] -> CompletionScoreboard.writeback_valid[l]`：writeback Event 及 payload；组合传递；当前拍有效。
52. `p3_arbiter_G0.csr_sideband_publish_valid -> system_instruction_handler.csr_sideband_valid`：`tag_out`、`is_csr`、`csr_write_enable`、`csr_addr`、`csr_wdata` payload Event；组合传递；当前拍有效。
53. `csr_unit.csr_addr -> system_instruction_handler.csr_addr`、`system_instruction_handler.csr_rdata -> csr_unit.csr_rdata`：CSR 组合读地址和读数据；当前拍有效。
54. `commit_valid[s] -> INT_ARF.commit_valid[s]`、`FP_ARF.commit_valid[s]`、`INT_tag_mapping.commit_valid[s]`、`FP_tag_mapping.commit_valid[s]`、`dependency_check.commit_valid[s]`、`SerialInstructionTracker.commit_valid[s]`、`system_instruction_handler.commit_valid[s]`：commit Event；各消费者取得 `backend_top_commit_payload[s]` 中其公开 Interface 定义的字段；组合传递；当前拍有效。
55. `commit_count -> system_instruction_handler.commit_count`：`COMMIT_COUNT_W` bit；组合传递；当前拍有效。
56. `CompletionScoreboard.head_tag[s] -> Buffer.head_tag[s]`、`PC_File.head_tag[s]`：`TAG_W` bit；组合传递；当前拍有效。
57. `CompletionScoreboard.flush_tag -> PC_File.flush_tag`：`TAG_W` bit；组合传递；当前拍有效。
58. `CompletionScoreboard.flush_valid -> flush_model.flush_valid`：`flush_tag`、`recovery_kind` payload Event；组合传递；当前拍有效。
59. `CompletionScoreboard.recovery_mispredict_target_pc -> flush_model.mispredict_target_pc`、`CompletionScoreboard.recovery_exception_cause -> flush_model.exception_cause`、`CompletionScoreboard.recovery_exception_tval -> flush_model.exception_tval`：组合传递；当前拍有效。
60. `PC_File.inst_pc -> flush_model.inst_pc`、`system_instruction_handler.mepc -> flush_model.mepc`、`system_instruction_handler.sepc -> flush_model.sepc`、`system_instruction_handler.interrupt_cause -> flush_model.interrupt_cause`、`system_instruction_handler.trap_vector -> flush_model.trap_vector`：组合传递；当前拍有效。
61. `flush_model.cause -> system_instruction_handler.trap_cause_in`、`flush_model.is_interrupt -> system_instruction_handler.trap_is_interrupt_in`：组合传递；当前拍有效。
62. `flush_model.trap_state_write -> system_instruction_handler.trap_state_write`：`trap_state_write_t` Event；组合传递；当前拍有效。
63. `system_instruction_handler.interrupt_pending -> CompletionScoreboard.interrupt_pending`：1 bit；组合传递；当前拍有效。
64. `ISQ_Group3.entry_self_tag -> CompletionScoreboard.st_br_resolve_tag`、`ISQ_Group3.isq_occupied -> CompletionScoreboard.st_br_resolve_tag_valid`：组合传递；当前拍有效。
65. `CompletionScoreboard.st_br_resolve -> lsu_bridge.st_br_resolve`：1 bit；组合传递；当前拍有效。
66. `CompletionScoreboard.store_wakeup_valid -> lsu_bridge.store_wakeup_valid`：`store_wakeup_tag` payload Event；组合传递；当前拍有效。
67. `lsu_be_issue_ready -> lsu_bridge.lsu_be_issue_ready`：1 bit；组合传递；当前拍有效。
68. `lsu_be_writeback_valid -> lsu_bridge.lsu_be_writeback_valid`：`lsu_be_writeback_pld_t` payload Event；组合传递；当前拍有效。
69. `lsu_be_bypass_valid -> lsu_bridge.lsu_be_bypass_valid`：`lsu_be_bypass_pld_t` payload Event；组合传递；当前拍有效。
70. `mip_meip -> system_instruction_handler.mip_meip`、`mip_mtip -> system_instruction_handler.mip_mtip`、`mip_msip -> system_instruction_handler.mip_msip`：各 1 bit；组合传递；当前拍有效。
71. `rst_n -> IB`、`INT_ARF`、`FP_ARF`、`INT_tag_mapping`、`FP_tag_mapping`、`ISQ_Group0`、`ISQ_Group1`、`ISQ_Group2`、`ISQ_Group3`、`u_alu0_bru`、`u_alu1`、`csr_unit`、`div_simple`、`mul_simple`、`fpu_simple`、`lsu_bridge`、`Buffer`、`PC_File`、`SerialInstructionTracker`、`system_instruction_handler`、`CompletionScoreboard`：1 bit；持续传递。
72. `flush_model.global_flush_late -> IB`、`dispatch_logic`、`INT_tag_mapping`、`FP_tag_mapping`、`ISQ_Group0`、`ISQ_Group1`、`ISQ_Group2`、`ISQ_Group3`、`u_alu0_bru`、`u_alu1`、`csr_unit`、`div_simple`、`mul_simple`、`fpu_simple`、`lsu_bridge`、`SerialInstructionTracker`、`system_instruction_handler`、`CompletionScoreboard`：无 payload Event；组合传递；当前拍 pulse。

## Interface

### In-event

1. `fe_valid[s]`：Transaction，`s∈{0,...,ISSUE_WIDTH-1}`
	- Fire来源：`fe_valid[s].fire = fe_valid[s] ∧ fe_ready[s]`
	- Payload：`fe_instr_pld[s]` `fe_be_instr_pld_t`；上升沿采样
	`fe_instr_pld[s]`：`pc` `XLEN` bit、`inst_bits` 32 bit、`is_compressed` 1 bit、`pred_taken` 1 bit、`pred_target_pc` `XLEN` bit、`fetch_excp_vld` 1 bit、`fetch_excp_cause` `FETCH_EXCP_CAUSE_W` bit、`fetch_excp_tval` `XLEN` bit
2. `lsu_be_writeback_valid`：Notify，单 lane
	- Fire来源：`lsu_be_writeback_valid.fire`
	- Payload：`lsu_be_writeback_pld` `lsu_be_writeback_pld_t`；当前拍有效
3. `lsu_be_bypass_valid`：Notify，单 lane
	- Fire来源：`lsu_be_bypass_valid.fire`
	- Payload：`lsu_be_bypass_pld` `lsu_be_bypass_pld_t`；当前拍有效

### In Static Info

1. `rst_n`：1 bit；低有效复位电平；持续传给含复位输入的子模块。
2. `lsu_be_issue_ready`：1 bit；LSU 当前拍可接收 issue；当前拍有效。
3. `mip_meip`：1 bit；机器外部中断 pending 电平；当前拍有效。
4. `mip_mtip`：1 bit；机器定时器中断 pending 电平；当前拍有效。
5. `mip_msip`：1 bit；机器软件中断 pending 电平；当前拍有效。

### Out-event

1. `redirect_valid`：Notify，单 lane
	- Fire来源：`redirect_valid.fire = flush_model.redirect_valid.fire`
		- `flush_model.redirect_valid.fire`：见 `Submodule` 第 31 条。
	- Constraint：无额外约束。
	- Payload：`backend_top_redirect_payload`；当前拍 pulse
	`backend_top_redirect_payload`：`redirect_pc` `XLEN` bit、`redirect_kind` `RECOVERY_KIND_W` bit、`frontend_icache_invalidate` 1 bit
		- `redirect_pc = flush_model.redirect_pc`
			- `flush_model.redirect_pc`：见 `Submodule` 第 31 条。
		- `redirect_kind = flush_model.redirect_kind`
			- `flush_model.redirect_kind`：见 `Submodule` 第 31 条。
		- `frontend_icache_invalidate = flush_model.frontend_icache_invalidate`
			- `flush_model.frontend_icache_invalidate`：见 `Submodule` 第 31 条。
2. `predictor_update_valid`：Notify，单 lane
	- Fire来源：`predictor_update_valid.fire = u_alu0_bru.predictor_update_valid.fire`
		- `u_alu0_bru.predictor_update_valid.fire`：见 `Submodule` 第 19 条。
	- Constraint：无额外约束。
	- Payload：`backend_top_predictor_update_payload`；当前拍 pulse
	`backend_top_predictor_update_payload`：`predictor_update_branch_pc` `XLEN` bit、`predictor_update_actual_taken` 1 bit、`predictor_update_actual_target` `XLEN` bit、`predictor_update_cf_class` `cf_class_e`
		- `predictor_update_branch_pc = u_alu0_bru.predictor_update_branch_pc`
			- `u_alu0_bru.predictor_update_branch_pc`：见 `Submodule` 第 19 条。
		- `predictor_update_actual_taken = u_alu0_bru.predictor_update_actual_taken`
			- `u_alu0_bru.predictor_update_actual_taken`：见 `Submodule` 第 19 条。
		- `predictor_update_actual_target = u_alu0_bru.predictor_update_actual_target`
			- `u_alu0_bru.predictor_update_actual_target`：见 `Submodule` 第 19 条。
		- `predictor_update_cf_class = u_alu0_bru.predictor_update_cf_class`
			- `u_alu0_bru.predictor_update_cf_class`：见 `Submodule` 第 19 条。
3. `be_lsu_issue_valid`：Transaction，单 lane
	- Fire来源：`be_lsu_issue_valid.fire = lsu_bridge.be_lsu_issue_valid.fire`
		- `lsu_bridge.be_lsu_issue_valid.fire`：见 `Submodule` 第 27 条。
	- Constraint：payload 保持和背压遵循 `lsu_bridge` 的 Transaction 接口。
	- Payload：`be_lsu_issue_pld` `be_lsu_issue_pld_t`；fire 拍采样
		- `be_lsu_issue_pld = lsu_bridge.be_lsu_issue_pld`
			- `lsu_bridge.be_lsu_issue_pld`：见 `Submodule` 第 27 条。
4. `be_lsu_store_wakeup_valid`：Notify，单 lane
	- Fire来源：`be_lsu_store_wakeup_valid.fire = lsu_bridge.be_lsu_store_wakeup_valid.fire`
		- `lsu_bridge.be_lsu_store_wakeup_valid.fire`：见 `Submodule` 第 27 条。
	- Constraint：无额外约束。
	- Payload：`be_lsu_store_wakeup_tag` `TAG_W` bit；当前拍 pulse
		- `be_lsu_store_wakeup_tag = lsu_bridge.be_lsu_store_wakeup_tag`
			- `lsu_bridge.be_lsu_store_wakeup_tag`：见 `Submodule` 第 27 条。
5. `global_flush`：Notify，单 lane
	- Fire来源：`global_flush.fire = flush_model.global_flush_late.fire`
		- `flush_model.global_flush_late.fire`：见 `Submodule` 第 31 条。
	- Constraint：无额外约束。
	- Payload：∅；当前拍 pulse
6. `alloc_valid[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`
	- Fire来源：`alloc_valid[s].fire = dispatch_logic.accept[s].fire`
		- `dispatch_logic.accept[s].fire`：见 `Submodule` 第 4 条。
	- Constraint：遵循 `dispatch_logic.accept[s]` 的 lane 约束。
	- Payload：`alloc_tag[s]` `TAG_W` bit；当前拍 pulse
		- `alloc_tag[s] = dependency_check.self_tag[s]`
			- `dependency_check.self_tag[s]`：见 `Submodule` 第 3 条。
7. `exec_valid[l]`：Notify，`l∈{0,...,NUM_LANES-1}`
	- Fire来源：`exec_valid[l].fire = (l=0) ? p3_arbiter_G0.writeback_valid.fire : (l=1) ? p3_arbiter_G1.writeback_valid.fire : (l=2) ? fpu_simple.writeback_valid.fire : lsu_bridge.writeback_valid.fire`
		- `p3_arbiter_G0.writeback_valid.fire`：见 `Submodule` 第 25 条。
		- `p3_arbiter_G1.writeback_valid.fire`：见 `Submodule` 第 26 条。
		- `fpu_simple.writeback_valid.fire`：见 `Submodule` 第 24 条。
		- `lsu_bridge.writeback_valid.fire`：见 `Submodule` 第 27 条。
	- Constraint：`l=0`、`1`、`2`、`3` 分别对应 G0 arbiter、G1 arbiter、FPU 和 LSU completion lane。
	- Payload：`exec_tag[l]` `TAG_W` bit；当前拍 pulse
		- `exec_tag[l] = (l=0) ? p3_arbiter_G0.tag_out : (l=1) ? p3_arbiter_G1.tag_out : (l=2) ? fpu_simple.tag_out : lsu_bridge.tag_out`
			- `p3_arbiter_G0.tag_out`：见 `Submodule` 第 25 条。
			- `p3_arbiter_G1.tag_out`：见 `Submodule` 第 26 条。
			- `fpu_simple.tag_out`：见 `Submodule` 第 24 条。
			- `lsu_bridge.tag_out`：见 `Submodule` 第 27 条。
8. `commit_valid[s]`：Notify，`s∈{0,...,ISSUE_WIDTH-1}`
	- Fire来源：`commit_valid[s].fire = CompletionScoreboard.commit_valid[s].fire`
		- `CompletionScoreboard.commit_valid[s].fire`：见 `Submodule` 第 33 条。
	- Constraint：遵循 `CompletionScoreboard.commit_valid[s]` 的 lane 约束。
	- Payload：`backend_top_commit_payload[s]`；当前拍有效
	`backend_top_commit_payload[s]`：`commit_tag` `TAG_W` bit、`commit_rd_idx` `REG_ADDR_W` bit、`commit_rd_is_fp` 1 bit、`commit_rd_write_enable` 1 bit、`commit_fflags` `FFLAGS_W` bit、`commit_data` `XLEN` bit、`trace_pc` `XLEN` bit
		- `commit_tag[s] = CompletionScoreboard.commit_tag[s]`
			- `CompletionScoreboard.commit_tag[s]`：见 `Submodule` 第 33 条。
		- `commit_rd_idx[s] = CompletionScoreboard.commit_rd_idx[s]`
			- `CompletionScoreboard.commit_rd_idx[s]`：见 `Submodule` 第 33 条。
		- `commit_rd_is_fp[s] = CompletionScoreboard.commit_rd_is_fp[s]`
			- `CompletionScoreboard.commit_rd_is_fp[s]`：见 `Submodule` 第 33 条。
		- `commit_rd_write_enable[s] = CompletionScoreboard.commit_rd_write_enable[s]`
			- `CompletionScoreboard.commit_rd_write_enable[s]`：见 `Submodule` 第 33 条。
		- `commit_fflags[s] = CompletionScoreboard.commit_fflags[s]`
			- `CompletionScoreboard.commit_fflags[s]`：见 `Submodule` 第 33 条。
		- `commit_data[s] = Buffer.commit_data[s]`
			- `Buffer.commit_data[s]`：见 `Submodule` 第 28 条。
		- `trace_pc[s] = PC_File.trace_pc[s]`
			- `PC_File.trace_pc[s]`：见 `Submodule` 第 29 条。

### Out Static Info

1. `fe_ready[s]`：1 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍有效。
	- `fe_ready[s] = IB.fe_ready[s]`
		- `IB.fe_ready[s]`：见 `Submodule` 第 1 条。
2. `accepted_slot[s]`：1 bit × `ISSUE_WIDTH`，`s∈{0,...,ISSUE_WIDTH-1}`；当前拍有效。
	- `accepted_slot[s] = IB.accepted_slot[s]`
		- `IB.accepted_slot[s]`：见 `Submodule` 第 1 条。
3. `commit_count`：`COMMIT_COUNT_W` bit；当前拍有效。
	- `commit_count = CompletionScoreboard.commit_count`
		- `CompletionScoreboard.commit_count`：见 `Submodule` 第 33 条。

### Interface Timing

1. `clk`：含时序逻辑的子模块在上升沿采样；`backend_top` 本身无时序存储。
2. `rst_n`：低有效复位输入；复位属性和复位值由各含复位输入的子模块定义。
3. `Transaction`：`fe_valid[s] ∧ fe_ready[s]` 在上升沿完成 FE 输入传输；`be_lsu_issue_valid ∧ lsu_be_issue_ready` 完成 LSU issue 传输，背压与 payload 保持由 `lsu_bridge` 定义。
4. `Notify`：输入和输出 Notify 在对应 valid/fire 拍有效，无 ready 回传。
5. `Static Info`：所有 Static Info 均为当前拍持续组合值；reset 或 flush 对其影响由对应 producer 子模块定义。
