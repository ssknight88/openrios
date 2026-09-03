# Module `isq_group_selection`

`isq_group_selection`：backend_top 内部的 ISQ group 选择。

## Submodule
无。

## FSM
### State
#### Per-entry State
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

## Data Path

- `isq_payload[s] -> isq_dispatch[g]`：`isq_payload`；由 `select_payload[g][s]` 选择。
- `isq_free_for_dispatch[g] -> isq_dispatch[g]`：credit Static Info；决定 group fire。

## Interface
### In-event
无。
### In Static Info
- `isq_payload[s]`：2 slot。
- `candidate_valid[s]`、`target_group[s]`：2 slot。
- `isq_free_for_dispatch[g]`：4 group credit。
### Out-event
- `isq_dispatch[g]`：Transaction，`g∈{0,1,2,3}`，payload=`isq_payload[g]`；fire=`∨s: select_payload[g][s]`。
### Out Static Info
- `select_payload[g][s]`：1 bit，4 x 2；`candidate_valid[s] ∧ credit[target_group[s]] ∧ (target_group[s]==g)`。
### Interface Timing
组合逻辑；每个 group 的 `select_payload[g][s]` 为 onehot0。


