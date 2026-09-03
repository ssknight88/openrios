# Module `flush_model`

flush_model translates the scoreboard recovery decision into the global late

## Submodule
无。

## FSM
### State
#### Per-entry State
- Per-entry state: none.
- Structure state: none.
- Reset state: none; no clock or reset port exists.

### State Transition & Condition Name
无。

没有 Event fire 时状态保持。

### Detailed Condition Description
1. `condition`：
   flush_apply = flush.fire = flush_valid
   kind_sel = recovery_kind_e'(recovery_kind)
   
   flush_apply gates every output. When it is zero, all output valid bits and
   selected payload fields are zero.

## Data structure
### State

None.

### Header

None. flush_valid, recovery_kind, and flush_tag are input event fields; kind_sel
is a combinational cast.

### Payload

None. Recovery and architectural values are read through the current interfaces.

## Data Path
- `scoreboard announce` -> `global_flush_late`：empty；驱动 flush；pulse on flush_valid
- `recovery/static inputs` -> `redirect`：redirect_t；驱动 flush + recovery reads；kind-select in same cycle
- `cause/tval/PC inputs` -> `trap_state_write`：trap_state_write_t；驱动 flush + cause reads；subset fire
- `static outputs` -> `system trap-vector query`：trap_vector_args_t；驱动 cause, is_interrupt；combinational


## Interface

### In-event

- `flush`：Notify；recovery_kind[3], flush_tag[4]；current-cycle input

### In Static Info

- `mispredict_target_pc`：XLEN；read at flush_tag
- `exception_cause`：EXCP_CAUSE_W；read at flush_tag
- `exception_tval`：XLEN；read at flush_tag
- `inst_pc`：XLEN；read at flush_tag
- `mepc`：XLEN；architectural view
- `sepc`：XLEN；architectural view
- `interrupt_cause`：EXCP_CAUSE_W；current handler view
- `trap_vector`：XLEN；query response

### Out-event

- `global_flush_late`：Notify；empty；same-cycle pulse
- `redirect`：Notify；redirect_pc[64], redirect_kind[3], icache_invalidate；same-cycle pulse
- `trap_state_write`：Notify；kind[3], epc[64], cause[63], tval[64]；same-cycle pulse

### Out Static Info

global_flush_late

- Kind: Notify, payload empty.
- Fire: global_flush_late.fire = flush_apply.
- Timing: same-cycle combinational pulse.

- **redirect**

- Kind: Notify, payload redirect_t.
- Fire: redirect.fire = redirect_valid = flush_apply.
- redirect_kind = recovery_kind.
- redirect_pc selection:

- kind_sel=MISPREDICT; redirect_pc=mispredict_target_pc
- kind_sel=MRET; redirect_pc=mepc
- kind_sel=SRET; redirect_pc=sepc
- kind_sel=FENCE_I; redirect_pc=inst_pc + XLEN'(4)
- kind_sel=EXCEPTION, INTERRUPT, reserved; redirect_pc=trap_vector

frontend_icache_invalidate = (kind_sel == FENCE_I).
All redirect fields are zero when flush_apply is zero.

- **trap_state_write**

- Kind: Notify, payload trap_state_write_t.
- Fire:
  trap_state_write.fire = flush_apply AND
  (kind_sel is EXCEPTION or INTERRUPT or MRET or SRET).
- kind = kind_sel; epc = inst_pc.
- cause = exception_cause for EXCEPTION, interrupt_cause for INTERRUPT,
  otherwise zero.
- tval = exception_tval for EXCEPTION, otherwise zero.
- valid is the fire bit and is not a second payload field.

- **Out Static Info details**

- Name=cause; Type / Width=EXCP_CAUSE_W; Cardinality=1; Generation rule=exception_cause for EXCEPTION; interrupt_cause for INTERRUPT; zero otherwise; Validity=zero unless flush_apply
- Name=is_interrupt; Type / Width=1; Cardinality=1; Generation rule=kind_sel == INTERRUPT when flush_apply; Validity=zero unless flush_apply

cause and is_interrupt are the trap-vector query arguments. trap_vector is an
input static response from system_instruction_handler.
- `cause`：EXCP_CAUSE_W；selected cause
- `is_interrupt`：1；selected kind

### Interface Timing

- 无。


