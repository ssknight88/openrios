# Module Composition and Visibility v3

## 1. Purpose

本文档定义本工程如何使用 `microarchitecture_v3.md` 与 `module_v3.md` 组织微架构规格。目标是让文档成为 RTL 的正向规范源，同时保持系统结构由少量稳定的 public module 组成。

```text
public module contract
    -> integration contract
    -> generated RTL hierarchy
```

RTL、package、实例层级和组合实现均属于派生结果；它们用于一致性检查，不承担架构语义的最终定义。

## 2. Two Visibility Levels

### Public Module

Public module 是系统积木，满足以下条件：

- 出现在 stage module index；
- 拥有独立的 module 文档和对外 Interface；
- 对其他 public module 提供或消费 event、static info、payload schema；
- 可以被 `backend_top` 或其他 public module 直接引用；
- 状态、数据通路和控制通路在本边界内闭合。

当前 public module 的典型集合：

```text
top:   backend_top
p1:    IB, decode, dependency_check, dispatch_logic,
       INT_ARF, FP_ARF, INT_tag_mapping, FP_tag_mapping
p2p3:  ISQ_Group0..3, p3_arbiter_G0, p3_arbiter_G1
fu:    alu_simple, csr_unit, div_simple, mul_simple, fpu_simple
lsu:   g3_lsu_iface
p4:    Buffer, CompletionScoreboard, PC_File,
       SerialInstructionTracker, flush_model,
       system_instruction_handler
```

### Private Submodule

Private submodule 是某个 public module 的内部实现分解：

- 只被父 module 文档索引；
- 不出现在 stage module index；
- 不参与 sibling module 的 Interface 推导；
- 不拥有跨父边界的 event；
- 可以拥有局部 static info、局部 condition 和局部 data path；
- 可以是组合逻辑、局部寄存器、算法分区或选择网络。

private submodule 的实现名不是系统级引用名。父 module 对外只暴露自己的 event、static info、payload schema 和接口时序。

准入、资格、ready、select、route 和 candidate 默认是 Static Info；只有实际捕获、出队、写入或状态更新动作才在拥有该动作的 module 中定义为 Event。`dispatch_logic.accept[s]` 因此是 Static Info，不是 Event。

## 3. Document Layout

推荐目录：

```text
work/spec/module_v3/
├─ microarchitecture_v3.md
├─ module_v3.md
├─ module_composition_v3.md
├─ top/
│  └─ backend_top.md
├─ p1/
│  ├─ IB.md
│  ├─ decode.md
│  ├─ decode/
│  │  ├─ rvc_expand.md
│  │  └─ decode_logic.md
│  └─ ...
├─ p2p3/
│  ├─ ISQ_Group0.md
│  ├─ ISQ_Group1.md
│  ├─ ISQ_Group2.md
│  └─ ISQ_Group3.md
├─ fu/
├─ lsu/
└─ p4/
```

`module_v3.md` 是单个 module 的文档骨架；本文档是公共/私有层级和集成方式的工程规则；stage index 只收录 public module。

## 4. Parent and Private Submodule Contract

父 module 文档在 `Submodule` 中只记录子文档链接与局部职责：

```text
Parent: Decode
  public input : ib_payload_t
  public output: decoded_info_t, decode_index_t

  private submodule: rvc_expand
    local input : raw instruction view
    local output: canonical inst32, rvc_illegal

  private submodule: decode_logic
    local input : canonical inst32, rvc_illegal
    local output: decoded_info_t, decode_index_t
```

父模块的公共输出由父模块 `Output` 唯一定义。内部子模块只提供局部结果，父模块负责把这些结果组合成 public event 或 public static info。

## 5. Decode Example

系统级引用保持：

```text
FE -> IB -> Decode -> dependency_check / dispatch_logic
```

Decode 内部实现为：

```text
IB.raw_payload
    -> rvc_expand
    -> canonical_instruction
    -> decode_logic
    -> Decode.decoded_info / Decode.register_indices
```

`rvc_expand` 的 `inst32` 和 `rvc_illegal` 是 Decode 内部 static info。它们不出现在 `backend_top` 的公共 Interface，也不进入其他 public module 的依赖表。

将来拆分为独立实现时，有两种合法形态：

```text
Decode
├─ rvc_expand
└─ decode_logic
```

或：

```text
backend_top -> rvc_expand -> Decode
```

第二种形态需要把 `rvc_expand` 的局部契约提升为 public module 契约，并更新父模块和集成层索引；Decode 的 public output schema 可以保持不变。

## 6. ISQ Example

四个 ISQ 是四个独立 public module：

```text
backend_top -> ISQ_Group0
backend_top -> ISQ_Group1
backend_top -> ISQ_Group2
backend_top -> ISQ_Group3
```

slot 到 group 的选择属于集成层的内部组合逻辑：

```text
slot_payload[s] : isq_payload_t
dispatch_fire[s] = candidate_valid[s] ∧ credit[target_group[s]]
select_payload[g][s] = dispatch_fire[s] ∧ (target_group[s] == g)
isq_dispatch[g].fire = ∨s: select_payload[g][s]
isq_dispatch[g].payload = selected slot_payload[s]
```

每个 `ISQ_Group[g]` 只消费自己的 `isq_dispatch[g]`，并定义自己的 entry state、operand readiness、bypass 和 issue event。

`p1_ISQ_input_mux` 不作为 public module；它是上述选择关系的一种实现。`FU_input_mux` 只属于各 ISQ 的内部 operand path。

`backend_top` 的 payload assembly、ISQ group selection、FP read-address selection 和 lane aggregation 分别记录在 `top/backend_top/` 私有文档中；这些文档只被父模块引用。

## 7. Event Ownership

每条 event 的 fire、payload schema、timing、hold/cancel 只有一个定义点：

```text
producer module.Output
```

父模块可以组合多个 private submodule 的结果后产生一个 public event：

```text
private results -> parent Output event
```

private submodule 不得与父模块重复定义同名 event。跨模块引用只写 event 名称、`event.fire` 或已定义的 payload 字段。

## 8. Static Info and Data Path

Static Info 没有 fire，表示持续存在的值或状态投影，例如：

```text
IB.head_payload -> Decode input
Decode.register_indices -> dependency_check
FP read-address view -> FP_ARF / FP_tag_mapping
ISQ free projection -> dispatch credit
FU_ready -> ISQ issue guard
```

这些值必须进入 Data Path，但不登记为 event。Data Path 端点只允许是：

1. public module Interface；
2. public module Data Structure；
3. 父模块文档中明确声明的 private submodule 局部端点。

选择器、mux、demux、merge 和 fan-out 由端点、payload 分组和互斥关系推导：

```text
同一终点 + 同一 payload 组 + 互斥候选 -> mux
同一终点 + 不同 payload 组 -> merge
同起点 + 互斥目的 event -> demux
一个 event + 多个消费者 -> fan-out
```

它们不进入 public module index，也不成为额外的架构端点。

## 9. Forward Generation Order

正向生成按消费者需求从后向前闭合：

```text
1. FU / LSU
   define required issue payload and completion payload

2. ISQ_Group0..3
   define entry fields, readiness, bypass, issue outputs

3. dependency_check / ARF / tag mapping
   define operand data, ready, wait_tag, and source selection info

4. dispatch_logic
   define route, FU index, admission guards, and allocation metadata

5. Decode
   define decoded_info and register-index outputs;
   resolve RVC expansion internally or through promoted submodule

6. IB
   retain the raw payload required by Decode and downstream consumers

7. backend_top / integration layer
   connect public module contracts and own composition logic

8. RTL generation and verification
   generate hierarchy, packages, assertions, and tests from the contracts
```

## 10. Refactoring and Promotion

### Internal Split

把父模块内部逻辑拆成 private submodule时：

- 父模块 public Interface 保持不变；
- 父模块 event/schema 定义保持唯一；
- 新子文档只记录局部 Interface 和局部 Data Path；
- sibling module 和 stage index 无需改动。

### Promotion to Public Module

把 private submodule 提升为 public module 时：

1. 为它建立独立 module 文档；
2. 明确新的 public event、static info 和 payload schema；
3. 把它加入 stage index；
4. 更新父模块 `Submodule` 和 `Interface`；
5. 更新 `integration-layer` 的连接表；
6. 检查所有受影响的 fire、timing、schema 和验证项。

### Merge Back

把 public module 合并回父模块时，删除其公共连接，保留父模块原有 event/schema；只改变实现层级，不改变父模块外部契约。

## 11. Change Impact

- 修改对象=public event; 需要检查=producer、所有消费者、fire、payload、timing
- 修改对象=public static info; 需要检查=所有读取者、Data Path 和组合依赖
- 修改对象=payload schema; 需要检查=生产者、捕获子集、package、top connection
- 修改对象=private submodule; 需要检查=父模块局部契约和父模块生成 RTL
- 修改对象=public/private 边界; 需要检查=stage index、父模块 Interface、集成层连接
- 修改对象=module hierarchy; 需要检查=promotion/merge 规则和验证覆盖

