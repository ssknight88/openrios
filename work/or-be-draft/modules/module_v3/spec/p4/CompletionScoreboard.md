# Module `CompletionScoreboard`

CompletionScoreboard is the sole retirement authority. It accepts allocation

## Submodule
无。

## FSM
### State
#### Per-entry State
- **Structure State**

- Stored field=head_q; Width=ROB_PTR_W (5); Meaning=oldest entry pointer, including loop bit
- Stored field=tail_q; Width=ROB_PTR_W (5); Meaning=next allocation pointer, including loop bit

The live interval is [head_q, tail_q) and

occupancy = tail_q - head_q

using modulo-32 arithmetic. Legal occupancy is 0..ROB_DEPTH.

- **Per-tag State**

- `entry_exec_done[t]`：Width / depth=1 x ROB_DEPTH; Meaning=terminal completion captured
- `entry_store_wakeup_issued[t]`：Width / depth=1 x ROB_DEPTH; Meaning=later wakeup pulse issued

Per-tag valid is decoded:

live[t] = exists i in [0, ROB_DEPTH-1] such that
          i < occupancy AND t == head_q[TAG_W-1:0] + i

### State Transition & Condition Name
无。

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `Occupancy projections`：
   occupancy = tail_q - head_q
   can_alloc_1 = (occupancy <= ROB_DEPTH - 1)
   can_alloc_2 = (occupancy <= ROB_DEPTH - 2)
   buffer_empty = (occupancy == 0)
   Buffer_tail = tail_q[TAG_W-1:0]

2. `Age-ordered scan`：
   For each i = 0..ROB_DEPTH-1:

   scan_tag = head_q[TAG_W-1:0] + i
   scan_live = (i < occupancy)
   scan_safe = NOT entry_may_flush[scan_tag] OR
               (entry_exec_done[scan_tag] AND
                NOT entry_exception_flag[scan_tag] AND
                NOT entry_mispredict_flag[scan_tag] AND
                NOT entry_is_mret[scan_tag] AND
                NOT entry_is_sret[scan_tag] AND
                NOT entry_is_fence_i[scan_tag])
   scan_is_cand = entry_is_store[scan_tag] AND
                  NOT entry_st_br_resolve[scan_tag] AND
                  NOT entry_store_wakeup_issued[scan_tag]

   For live entries, set live_mask[scan_tag], accumulate
   any_plain_store_authorized_live when
   entry_is_store[scan_tag] AND
   (entry_st_br_resolve[scan_tag] OR entry_store_wakeup_issued[scan_tag]), and
   AND scan_safe into prefix_safe_0. The first scan_is_cand is wk_tag. Its guard is

   wk_cand_ok = wk_prefix_safe AND
                NOT (entry_exec_done[wk_tag] AND entry_exception_flag[wk_tag])

   Entries before the candidate update wk_prefix_safe with scan_safe.

3. `Head qualifiers`：
   head0_tag = head_q[TAG_W-1:0]
   head1_tag = head_q[TAG_W-1:0] + 1
   head0_valid = (occupancy >= 1)
   head1_valid = (occupancy >= 2)
   head0_done = head0_valid AND entry_exec_done[head0_tag]
   head1_done = head1_valid AND entry_exec_done[head1_tag]

   h0_exception  = entry_exception_flag[head0_tag]
   h0_mispredict = entry_mispredict_flag[head0_tag]
   h0_is_mret    = entry_is_mret[head0_tag]
   h0_is_sret    = entry_is_sret[head0_tag]
   h0_is_fence_i = entry_is_fence_i[head0_tag]
   h0_fp_write   = entry_rd_write_enable[head0_tag] AND entry_rd_is_fp[head0_tag]

   h1_exception  = entry_exception_flag[head1_tag]
   h1_mispredict = entry_mispredict_flag[head1_tag]
   h1_is_fence_i = entry_is_fence_i[head1_tag]
   h1_fp_write   = entry_rd_write_enable[head1_tag] AND entry_rd_is_fp[head1_tag]

   head0_irrevocable = head0_done AND NOT h0_exception AND
                       (entry_is_store[head0_tag] OR entry_is_atomic[head0_tag])
   interrupt_take = interrupt_pending AND
                    NOT any_plain_store_authorized_live
   interrupt_boundary_ok = NOT head0_irrevocable OR head1_valid

4. `Writeback capture`：
   writeback_capture[g].fire = writeback[g].fire AND
                               NOT global_flush_late.fire

   When it fires, set entry_exec_done[tag_out[g]] and capture the four completion
   flags/fields: mispredict flag and target, exception flag/cause/tval, is_mret,
   is_sret, and fpu_fflags.

5. `Commit and flush decision chain`：
   Evaluate the following head0 branches in order:

   1. If NOT head0_valid OR NOT head0_done: no commit and do not evaluate head1.
   2. Else if h0_exception: flush_valid=1, recovery_kind=EXCEPTION,
      flush_tag=head0_tag, no commit.
   3. Else if interrupt_take AND interrupt_boundary_ok: flush_valid=1 and
      recovery_kind=INTERRUPT. If head0 is revocable, no commit and flush_tag is
      head0_tag. If irrevocable, commit lane 0 and flush_tag is head1_tag.
   4. Else if h0_is_mret OR h0_is_sret OR h0_is_fence_i OR h0_mispredict:
      commit lane 0 and flush_valid=1 at head0_tag, with kind priority
      MRET > SRET > FENCE_I > MISPREDICT.
   5. Else commit lane 0 and evaluate head1.

   When head1 is evaluated and valid/done:

   - h1_exception: flush at head1 with EXCEPTION; lane 1 does not commit.
   - h1_is_fence_i OR h1_mispredict: lane 1 commits and flushes at head1, with
     FENCE_I > MISPREDICT.
   - Otherwise lane 1 commits normally.

   Dual-FP block:

   if commit_valid[0] AND commit_valid[1] AND h0_fp_write AND h1_fp_write,
   clear commit_valid[1]. If the selected flush came from that head1 commit, also
   clear flush_valid and recovery_kind; head1 waits for the next cycle.

   flush_decided is the flush_valid value before the dual-FP block. The wakeup
   gate uses this pre-block value.

6. `Store authorization`：
   wb_hits_wakeup_tag = exists g:
                        writeback[g].fire AND
                        NOT global_flush_late.fire AND
                        tag_out[g] == wk_tag

   wk_authorize = wk_found AND wk_cand_ok AND
                  NOT flush_decided AND NOT wb_hits_wakeup_tag

   resolve_in_place = wk_authorize AND st_br_resolve_tag_valid AND
                      (st_br_resolve_tag == wk_tag)

   store_wakeup.fire = wk_authorize AND NOT resolve_in_place
   store_wakeup_tag = wk_tag

   If resolve_in_place is true, set entry_st_br_resolve[wk_tag] and emit no pulse.
   The st_br_resolve output forwards this same-cycle decision to an ISQ3 issue.

7. `Allocation-time store resolve`：
   st_br_resolve_alloc[0] = accept[0] AND is_store[0] AND prefix_safe_0
   prefix_safe_1 = prefix_safe_0 AND (NOT accept[0] OR NOT may_flush[0])
   st_br_resolve_alloc[1] = accept[1] AND is_store[1] AND prefix_safe_1

## Data structure
### State

- `head_q, tail_q`：Width / depth=ROB_PTR_W x 1 each; Role=structure state; Reset=0, 0; Update condition=head_next/tail_next
- `entry_exec_done[t]`：Width / depth=1 x ROB_DEPTH; Role=per-tag state; Reset=0; Update condition=writeback capture; clear on allocation
- `entry_store_wakeup_issued[t]`：Width / depth=1 x ROB_DEPTH; Role=per-tag state; Reset=0; Update condition=store_wakeup; clear on allocation

### Header

- `entry_rd_idx[t]`：Width / depth=REG_ADDR_W x ROB_DEPTH; Consumed by=commit payload; Update rule=allocation write
- `entry_rd_is_fp[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=FP block; Update rule=allocation write
- `entry_rd_write_enable[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=commit/irrevocable tests; Update rule=allocation write
- `entry_is_store[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=store scan/irrevocable test; Update rule=allocation write
- `entry_is_fence_i[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=flush decision/safe scan; Update rule=allocation write
- `entry_may_flush[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=safe scan; Update rule=allocation write
- `entry_is_atomic[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=irrevocable test; Update rule=allocation write
- `entry_mispredict_flag[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=head decision/safe scan; Update rule=writeback capture
- `entry_exception_flag[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=head decision/safe scan; Update rule=writeback capture
- `entry_is_mret[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=head decision/safe scan; Update rule=writeback capture
- `entry_is_sret[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=head decision/safe scan; Update rule=writeback capture
- `entry_st_br_resolve[t]`：Width / depth=1 x ROB_DEPTH; Consumed by=store candidate scan/authorization; Update rule=alloc-time or in-place resolve

Writeback flags are guarded by entry_exec_done; allocation clears exec_done, so
stale flags cannot affect a reused tag.

### Payload

- `entry_mispredict_target_pc[t]`：Width / depth=XLEN x ROB_DEPTH; Storage location=ROB entry; Written by=writeback capture; Read by / forwarded to=recovery static info
- `entry_exception_cause[t]`：Width / depth=EXCP_CAUSE_W x ROB_DEPTH; Storage location=ROB entry; Written by=writeback capture; Read by / forwarded to=recovery static info
- `entry_exception_tval[t]`：Width / depth=XLEN x ROB_DEPTH; Storage location=ROB entry; Written by=writeback capture; Read by / forwarded to=recovery static info
- `entry_fpu_fflags[t]`：Width / depth=FFLAGS_W x ROB_DEPTH; Storage location=ROB entry; Written by=writeback capture; Read by / forwarded to=commit payload

## Data Path
- `allocation payload` -> `entry header and cleared state at alloc_self_tag[s]`：scb_alloc_t；驱动 alloc[s]；write at edge on accept[s]
- `completion payload` -> `entry fields at tag_out[g]`：completion_common_t；驱动 writeback_capture[g]；write at edge when capture fires
- `ROB head entry` -> `commit lane output`：commit_lane_t；驱动 commit[k]；announce when commit_valid[k]
- `wk_tag` -> `LSU authorization`：store_wakeup_t；驱动 store_wakeup；pulse when authorized
- `selected head` -> `flush_model`：flush_announce_t；驱动 flush；announce when flush_valid
- `recovery arrays` -> `recovery outputs`：XLEN/EXCP_CAUSE_W；驱动 flush_tag view；combinational indexed read
- `entry_st_br_resolve` -> `st_br_resolve`：1；驱动 st_br_resolve_tag view；read plus same-cycle forwarding
- `pointers` -> `live/admission/head projections`：pointer views；驱动 head/tail views；combinational

## Interface

### In-event

- `alloc[s]`：Notify；self_tag[4], rd_idx[5], rd_is_fp, rd_write_enable, is_store, is_fence_i, may_flush, is_atomic；sampled at edge
- `writeback[g]`：Notify；completion_common_t；sampled at edge
- `global_flush_late`：Notify；empty；suppress capture

### In Static Info

- `interrupt_pending`：1；current handler projection
- `st_br_resolve_tag`：TAG_W；address
- `st_br_resolve_tag_valid`：1；address-valid qualifier
Clock is clk; reset is asynchronous active-low rst_n. Notifications have no
backpressure; static projections are combinational.

### Out-event

- `commit[k]`：Notify；commit_lane_t；same-cycle announce
- `store_wakeup`：Notify；store_wakeup_tag[4]；same-cycle pulse
- `flush`：Notify；flush_tag[4], recovery_kind[3]；same-cycle announce

### Out Static Info

commit

- Kind: Notify, two lanes, no backpressure.
- Fire: commit[k].fire = commit_valid[k].
- Payload schema per lane:

- `commit_tag`：Width=TAG_W; Generation rule=head0_tag for lane 0, head1_tag for lane 1 when valid; zero otherwise
- `rd_idx`：Width=REG_ADDR_W; Generation rule=entry_rd_idx[head{k}_tag]
- `rd_is_fp`：Width=1; Generation rule=entry_rd_is_fp[head{k}_tag]
- `rd_write_enable`：Width=1; Generation rule=entry_rd_write_enable[head{k}_tag]
- `commit_fflags`：Width=FFLAGS_W; Generation rule=entry_fpu_fflags[head{k}_tag]

Invalid-lane fields are placeholders and are not consumed.
commit_count = commit_valid[0] + commit_valid[1].

- **store_wakeup**

- Kind: Notify, one lane, no backpressure.
- Fire: store_wakeup.fire = store_wakeup_valid =
  wk_authorize AND NOT resolve_in_place.
- Payload: store_wakeup_tag[TAG_W] = wk_tag.
- Timing: one-cycle pulse; issued bit is set at the active edge.
- No pulse is emitted for in-place resolution.

- **flush**

- Kind: Notify, one lane, no backpressure.
- Fire: flush.fire = flush_valid.
- Payload:

- `flush_tag`：Width=TAG_W; Generation rule=selected head0/head1 recovery tag
- `recovery_kind`：Width=RECOVERY_KIND_W; Generation rule=selected by the decision chain

- Timing: same-cycle announce to flush_model.
- flush_tag is an entry address; tail rollback is internal.

- **Out Static Info details**

- Name=head0_tag; Type / Width=TAG_W; Cardinality=1; Generation rule=head_q low tag bits; Validity=always
- Name=head1_tag; Type / Width=TAG_W; Cardinality=1; Generation rule=head_q low tag bits + 1; Validity=always
- Name=recovery_mispredict_target_pc; Type / Width=XLEN; Cardinality=1; Generation rule=entry_mispredict_target_pc[flush_tag]; Validity=indexed view
- Name=recovery_exception_cause; Type / Width=EXCP_CAUSE_W; Cardinality=1; Generation rule=entry_exception_cause[flush_tag]; Validity=indexed view
- Name=recovery_exception_tval; Type / Width=XLEN; Cardinality=1; Generation rule=entry_exception_tval[flush_tag]; Validity=indexed view
- Name=st_br_resolve; Type / Width=1; Cardinality=1; Generation rule=entry_st_br_resolve[st_br_resolve_tag] OR same-cycle forwarding; Validity=static read
- Name=scoreboard_valid_bits; Type / Width=ROB_DEPTH; Cardinality=1; Generation rule=live_mask; Validity=always
- Name=scoreboard_exec_done_bits; Type / Width=ROB_DEPTH; Cardinality=1; Generation rule=entry_exec_done array; Validity=always
- Name=Buffer_tail; Type / Width=TAG_W; Cardinality=1; Generation rule=tail_q low tag bits; Validity=always
- Name=can_alloc_1; Type / Width=1; Cardinality=1; Generation rule=occupancy <= ROB_DEPTH-1; Validity=admission view
- Name=can_alloc_2; Type / Width=1; Cardinality=1; Generation rule=occupancy <= ROB_DEPTH-2; Validity=admission view
- Name=buffer_empty; Type / Width=1; Cardinality=1; Generation rule=occupancy == 0; Validity=always
- `commit_count`：COMMIT_COUNT_W；commit-valid count
- `head0_tag, head1_tag`：TAG_W；always
- `recovery_mispredict_target_pc`：XLEN；indexed view
- `recovery_exception_cause`：EXCP_CAUSE_W；indexed view
- `recovery_exception_tval`：XLEN；indexed view
- `st_br_resolve`：1；indexed view
- `scoreboard_valid_bits`：ROB_DEPTH；live projection
- `scoreboard_exec_done_bits`：ROB_DEPTH；state projection
- `Buffer_tail`：TAG_W；tail projection
- `can_alloc_1, can_alloc_2`：1；admission projections
- `buffer_empty`：1；occupancy projection

### Interface Timing

- 无。


