# Module `system_instruction_handler`

system_instruction_handler owns the architectural CSR file, privilege state,

## Submodule
无。

## FSM
### State
#### Per-entry State
The only speculative entry has two states:

- State=EMPTY; Representation=stage_valid_q = 0; Meaning=no CSR intent is pending
- State=STAGED; Representation=stage_valid_q = 1; Meaning=one tagged CSR intent is pending

Reset state is EMPTY; stage_tag_q, stage_addr_q, and stage_wdata_q reset to zero.
Architectural CSR registers have no speculative lifecycle.

### State Transition & Condition Name
1. `EMPTY -> STAGED`：`capture`
2. `STAGED -> EMPTY`：`apply`
3. `STAGED -> EMPTY`：`flush`

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `capture`：
   capture = completion_lane0.fire AND completion_lane0.is_csr AND
             completion_lane0.csr_write_enable AND NOT global_flush_late.fire
   
   stage_tag_hit = OR over k=0..ISSUE_WIDTH-1 of
                   (commit[k].fire AND
                    commit[k].commit_tag == stage_tag_q)
   
   apply_fire = stage_valid_q AND stage_tag_hit
   
   fflags_accrued = OR over k of
                    (commit[k].fire ? commit[k].commit_fflags : 0)
   fp_dirty = OR over k of
              (commit[k].fire AND
               ((commit[k].rd_write_enable AND commit[k].rd_is_fp) OR
                (commit[k].commit_fflags != 0)))
   
   trap_entry  = trap_state_write.fire AND
                 (kind is RECOVERY_EXCEPTION or RECOVERY_INTERRUPT)
   mret_update = trap_state_write.fire AND (kind is RECOVERY_MRET)
   sret_update = trap_state_write.fire AND (kind is RECOVERY_SRET)
   
   trap_delegated = ENABLE_S AND (current_priv_q != PRIV_M) AND
                    trap_state_write.fire AND
                    ((kind is RECOVERY_INTERRUPT AND
                      mideleg_q[trap_state_write.cause[5:0]]) OR
                     (kind is RECOVERY_EXCEPTION AND
                      medeleg_q[trap_state_write.cause[5:0]]))
   
   mcause_trap_value = {(kind is RECOVERY_INTERRUPT), trap_state_write.cause}

2. `apply`：`apply.fire = stage_valid_q ∧ stage_tag_hit`；提交时应用 staged CSR write 并清除 `stage_valid_q`。

3. `flush`：`flush.fire = global_flush_late`；清除 `stage_valid_q`。

## Data structure
### State

- Field group=stage_valid_q; Width / depth=1; Role=speculative state; Reset=0
- Field group=current_priv_q, mstatus_mpp_q; Width / depth=PRIV_W; Role=privilege state; Reset=M
- Field group=M/S status and interrupt-enable bits; Width / depth=1 each; Role=architectural control state; Reset=0
- Field group=mstatus_fs_q; Width / depth=2; Role=FP status; Reset=FS_OFF
- Field group=mip_ssip_q; Width / depth=1; Role=stored pending bit; Reset=0
- Field group=mtvec/stvec base and mode; Width / depth=XLEN-2 and 2; Role=vector state; Reset=base 0, Direct
- Field group=M/S trap, scratch, delegation, and satp registers; Width / depth=XLEN; Role=architectural state; Reset=0
- Field group=mcycle_q, minstret_q; Width / depth=XLEN; Role=counters; Reset=0
- Field group=fflags_q, frm_q; Width / depth=5 and 3; Role=FP CSR state; Reset=0 and RNE

### Header

- `stage_tag_q`：Width=TAG_W; Consumed by=stage_tag_hit; Update rule=latch on capture
- `stage_addr_q`：Width=CSR_ADDR_W; Consumed by=CSR address case; Update rule=latch on capture

### Payload

- `stage_wdata_q`：Width=XLEN; Storage location=speculative stage; Written by=capture; Read by=selected CSR write on apply_fire

mstatus_view, mip_view, mie_view, pending_bits, takeable, sstatus_view,
sie_view, sip_view, MISA_VALUE, and trap_vector are combinational views.

## Data Path
- `completion sideband` -> `csr_stage tag/addr/wdata`：csr_completion_t；驱动 completion_lane0；capture at edge
- `commit tag` -> `stage_tag_hit/apply_fire`：commit_lane_t；驱动 commit[k]；compare in cycle; apply at edge
- `fflags and rd metadata` -> `fflags_q, FS, minstret_q`：commit_lane_t；驱动 commit[k]；sticky accrue and counter increment
- `trap packet` -> `M/S trap and privilege state`：trap_state_write_t；驱动 trap_state_write；update at edge
- `flush notification` -> `stage_valid_q`：empty；驱动 global_flush_late；clear at edge
- `software read address` -> `csr_rdata`：CSR_ADDR_W to XLEN；驱动 csr_addr；combinational
- `trap_cause_in, trap_is_interrupt_in` -> `trap_vector`：trap_vector_args_t to XLEN；驱动 trap query args；combinational
- `external levels` -> `interrupt views`：one-bit levels；驱动 mip levels；combinational

## Interface

### In-event

- `completion_lane0`：Notify；tag[4], is_csr, csr_write_enable, csr_addr[12], csr_wdata[64]；sampled at edge
- `commit[k]`：Notify；commit_tag[4], commit_fflags[5], rd_is_fp, rd_write_enable；compare/accrue in cycle
- `trap_state_write`：Notify；kind[3], epc[64], cause[63], tval[64]；update at edge
- `global_flush_late`：Notify；empty；clear stage at edge

### In Static Info

- `commit_count`：COMMIT_COUNT_W；every cycle
- `csr_addr`：CSR_ADDR_W；read address
- `trap_cause_in`：EXCP_CAUSE_W；trap-vector argument
- `trap_is_interrupt_in`：1；trap-vector argument
- `mip_meip, mip_mtip, mip_msip`：1；external levels
Clock is clk; reset is asynchronous active-low rst_n. CSR and trap-vector
reads are combinational. Notifications have no backpressure.

### Out-event

- 无。

### Out Static Info

None. Outputs are static information or combinational read responses.

- **Out Static Info details**

- Name=csr_rdata; Type / Width=XLEN; Cardinality=1; Generation rule=CSR[csr_addr] read map; Validity=combinational
- Name=current_priv; Type / Width=PRIV_W; Cardinality=1; Generation rule=current_priv_q; Validity=always
- Name=frm; Type / Width=rm_e, FRM_W=3; Cardinality=1; Generation rule=rm_e'(frm_q); Validity=always
- Name=fs_enabled; Type / Width=1; Cardinality=1; Generation rule=mstatus_fs_q != FS_OFF; Validity=always
- Name=trap_vector; Type / Width=XLEN; Cardinality=1; Generation rule=trap-vector formula below; Validity=combinational query
- Name=interrupt_pending; Type / Width=1; Cardinality=1; Generation rule=OR of takeable bits; Validity=always
- Name=interrupt_cause; Type / Width=EXCP_CAUSE_W; Cardinality=1; Generation rule=highest-priority takeable bit; Validity=zero if none
- Name=mepc, sepc; Type / Width=XLEN; Cardinality=1 each; Generation rule=mepc_q, sepc_q; Validity=always
- Name=mstatus_tvm, mstatus_tw, mstatus_tsr; Type / Width=1; Cardinality=1 each; Generation rule=corresponding state bit; Validity=always

- **CSR write rules**

The address in stage_addr_q selects these writes. Other addresses are ignored.

- Address=FFLAGS; Update=fflags_q <- wdata[4:0]; set FS Dirty
- Address=FRM; Update=frm_q <- wdata[2:0]; set FS Dirty
- Address=FCSR; Update=fflags_q <- wdata[4:0]; frm_q <- wdata[7:5]; set FS Dirty
- Address=MSTATUS; Update=update MIE, MPIE, FS; clamp MPP to implemented M/S/U; when S enabled update SIE, SPIE, SPP, SUM, MXR, TVM, TW, TSR
- Address=SSTATUS; Update=when S enabled update FS, SPP, SPIE, SIE, SUM, MXR
- Address=MIE; Update=update MEIE, MTIE, MSIE and, when S enabled, SEIE, STIE, SSIE
- Address=SIE; Update=when S enabled update only delegated SEIE, STIE, SSIE
- Address=MIP; Update=when S enabled update stored SSIP; external MIP bits are views
- Address=SIP; Update=when S enabled and SSIP is delegated, update stored SSIP
- Address=MTVEC, STVEC; Update=write BASE; accept Direct or Vectored MODE, retain prior MODE otherwise; STVEC only when S enabled
- Address=MEDELEG, MIDELEG; Update=when S enabled write with the implementation masks
- Address=SATP; Update=when S enabled accept MODE 0, 8, or 9; other MODE values hold the whole register
- Address=MEPC, SEPC; Update=clear bit 0 when C is enabled, otherwise clear bits 1:0; SEPC only when S enabled
- Address=MCAUSE, MTVAL, MSCRATCH; Update=full XLEN write
- Address=SCAUSE, STVAL, SSCRATCH; Update=full XLEN write when S enabled
- Address=MCYCLE, MINSTRET; Update=full XLEN write and override the same-cycle increment

- **Architectural event actions and priority**

On every active cycle:

1. mcycle_q increments by one and minstret_q increments by commit_count.
2. fflags_q ORs fflags_accrued; fp_dirty moves FS to Dirty.
3. apply_fire performs the selected CSR write. Counter and fflags writes here
   override the corresponding increment/accrue.
4. trap_entry, mret_update, or sret_update executes last and wins over
   overlapping mstatus fields.

global_flush_late only clears the speculative stage.

Trap entry with trap_delegated = 0 writes mepc, mcause, and mtval, saves MIE
to MPIE, clears MIE, saves current privilege in MPP, and enters PRIV_M.
Trap entry with trap_delegated = 1 writes sepc, scause, and stval, saves SIE
to SPIE, clears SIE, saves SPP, and enters PRIV_S.

MRET performs MIE <- MPIE, MPIE <- 1, current_priv <- MPP, MPP <- PRIV_U.
SRET performs SIE <- SPIE, SPIE <- 1, current_priv <- (SPP ? PRIV_S : PRIV_U),
and SPP <- 0.

- **Interrupt static-information derivation**

mip_view = 0
mip_view[MEI] = mip_meip; mip_view[MTI] = mip_mtip
mip_view[MSI] = mip_msip; mip_view[SSI] = mip_ssip_q

mie_view[MEI] = mie_meie_q; mie_view[MTI] = mie_mtie_q
mie_view[MSI] = mie_msie_q; mie_view[SEI] = mie_seie_q
mie_view[STI] = mie_stie_q; mie_view[SSI] = mie_ssie_q

pending_bits = mie_view AND mip_view
m_targeted = pending_bits AND NOT mideleg_q
s_targeted = pending_bits AND mideleg_q
m_enabled = (current_priv_q == PRIV_M) ? mstatus_mie_q : 1
s_enabled = (current_priv_q == PRIV_M) ? 0 :
            (current_priv_q == PRIV_S) ? mstatus_sie_q : 1
takeable = (m_enabled ? m_targeted : 0) OR
           (s_enabled ? s_targeted : 0)
interrupt_pending = OR(takeable)

interrupt_cause priority is MEI > MSI > MTI > SEI > SSI > STI; it is zero
when takeable is zero.

- **Trap-vector read response**

mtvec_view = {mtvec_base_q, mtvec_mode_q}
stvec_view = {stvec_base_q, stvec_mode_q}
tvec_sel = trap_delegated ? stvec_view : mtvec_view
mode_sel = trap_delegated ? stvec_mode_q : mtvec_mode_q
trap_vector = (mode_sel == VECTORED AND trap_is_interrupt_in) ?
              (base(tvec_sel) + (zero_extend(trap_cause_in) << 2)) :
              base(tvec_sel)

Only interrupts use vectored mode; synchronous exceptions use the direct base.

- **CSR read map**

csr_rdata is a one-port combinational case returning FFLAGS, FRM, FCSR,
MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP,
MCYCLE/CYCLE, MINSTRET/INSTRET, SSTATUS, SIE, SIP, STVEC, SSCRATCH, SEPC,
SCAUSE, STVAL, SATP, MEDELEG, and MIDELEG from state or views.
MISA is derived from the shared build switches. MHARTID, MVENDORID, MARCHID,
MIMPID, PMPCFG0, and PMPADDR0 read zero; unimplemented addresses read zero.

CSR address map (CSR_ADDR_W = 12):

- CSR=FFLAGS; Address=0x001; CSR=FRM; Address=0x002
- CSR=FCSR; Address=0x003; CSR=MSTATUS; Address=0x300
- CSR=MISA; Address=0x301; CSR=MEDELEG; Address=0x302
- CSR=MIDELEG; Address=0x303; CSR=MIE; Address=0x304
- CSR=MTVEC; Address=0x305; CSR=MSCRATCH; Address=0x340
- CSR=MEPC; Address=0x341; CSR=MCAUSE; Address=0x342
- CSR=MTVAL; Address=0x343; CSR=MIP; Address=0x344
- CSR=MCYCLE; Address=0xB00; CSR=MINSTRET; Address=0xB02
- CSR=CYCLE; Address=0xC00; CSR=INSTRET; Address=0xC02
- CSR=SSTATUS; Address=0x100; CSR=SIE; Address=0x104
- CSR=STVEC; Address=0x105; CSR=SSCRATCH; Address=0x140
- CSR=SEPC; Address=0x141; CSR=SCAUSE; Address=0x142
- CSR=STVAL; Address=0x143; CSR=SIP; Address=0x144
- CSR=SATP; Address=0x180; CSR=MHARTID; Address=0xF14

Implemented mstatus/mip field positions are fixed at XLEN=64:

- `MIE / MPIE`：Bit(s)=3 / 7; Field=FS; Bit(s)=14:13
- `MPP`：Bit(s)=12:11; Field=SD; Bit(s)=63 (derived)
- `UXL / SXL`：Bit(s)=33:32 / 35:34; Field=MEIP / MTIP / MSIP; Bit(s)=11 / 7 / 3
- `SEIP / STIP / SSIP`：Bit(s)=9 / 5 / 1; Field=SIE / SPIE / SPP; Bit(s)=1 / 5 / 8
- `SUM / MXR / TVM`：Bit(s)=18 / 19 / 20; Field=TW / TSR; Bit(s)=21 / 22
- `SATP MODE`：Bit(s)=63:60

External MEIP, MTIP, and MSIP are read-only mip views. SSIP is the only stored
mip bit. Delegation masks expose only SEIP, STIP, SSIP for interrupts and the
implemented synchronous causes for exceptions.
- `csr_rdata`：XLEN；combinational
- `current_priv`：PRIV_W；always
- `frm`：rm_e；always
- `fs_enabled`：1；always
- `trap_vector`：XLEN；query response
- `interrupt_pending`：1；always
- `interrupt_cause`：EXCP_CAUSE_W；zero when none
- `mepc, sepc`：XLEN；always
- `mstatus_tvm, mstatus_tw, mstatus_tsr`：1；always

### Interface Timing

- 无。


