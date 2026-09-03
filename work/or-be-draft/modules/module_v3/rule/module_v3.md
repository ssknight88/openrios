# Module 文档骨架

## 总原则

- 谁写的判据只有一条：**可不可推导**。推得出来交 AI，推不出来人写。
- 零 state 的 module：`State` / `State Transition & Condition Name` / `Detailed Condition Description` 三节可全空，合法。
- Event 在【定义点】处唯一定义，其他位置只引用。
- module 文档不使用 Markdown 表格；字段、条件、接口和数据通路使用列表或代码块。
- 准入、资格、ready、select、route 和 candidate 默认属于 `Out Static Info`；只有实际捕获、出队、写入或状态更新动作属于 `Out-event`。
- 条目采用紧凑写法：`` `name`：schema；表达式/连接；时序或用途。`` 只有存在层级化 fire 展开时才继续缩进。
- 相同 schema、数量或时序只在上层声明一次；字段条目不重复堆叠相同属性。
- Module 开头只保留名称、基本 property 和 module 类型；推荐写成“`module_name`：property 的 module”。

## Submodule

- 只写 submodule 名称和文档链接；无 submodule 时只写“无”。不补充叶 module、调用关系或实现解释。

## FSM

- 保证 `State Transition & Condition Name` 全覆盖。
- `Condition Name` 手写。

### State

#### Per-entry State

- 列出本 module 的语义状态；零 state module 写“无”。
- 模板：

```text
Per-entry State: detailed statement
```

- 推荐写法：`` `STATE_A` / `STATE_B`：一句话说明行为。``

### State Transition & Condition Name

- 完备描述 `Per-entry State` 的真实转换，`Condition Name` 仅标注真实 Event 名称。
- 必须穷举每个可达的状态对 `Current -> Next`；不得用 `EMPTY/RESIDENT -> EMPTY/RESIDENT` 或“正常情况”等合并写法替代。
- 结构压缩的 occupancy、指针、计数和解码投影统一写在 `Data structure -> State`；不要把这些投影反向当成额外存储。
- 同一状态对下的多个输入组合可以归并为一个 condition name，但必须在 `Detailed Condition Description` 中给出互斥且完备的组合条件。
- Condition name 应直接使用实际 Event（如 `enqueue`、`dequeue`、`issue`、`flush`）；避免使用 `normal_*`、`dequeue_last`、`hold_or_update` 等为状态结果临时创建的抽象名称。
- 若多个 condition 导致同一 `Current -> Next`，可以合并在同一行，但必须逐个写出 condition name；若同一 `Current -> Next` 语义不同，则另起一行。
- 使用有序编号；每条只写一行 `Current State -> Next State：Event`。State Transition 的第 `N` 条必须对应 Detailed Condition 的第 `N` 个编号条目。
- 不按 Event 分组，不在 Transition 段落解释状态推导、物理复用或实现原因。
- 无 Event fire 时状态保持为默认行为，不为“无动作保持”额外创建 condition name；只有真实 Event 驱动的状态对写入 State Transition。
- 不对应 State Transition 的辅助谓词、共享计数、索引或更新式使用无编号子节，避免占用 transition 编号。
- 模板：

```text
Current Per-entry State -> Next Per-entry State: Condition Name
```

### Detailed Condition Description

- 详细描述【定义点】`Condition event` 产生的细节逻辑。
- `State Transition & Condition Name` 中出现的每个 condition name 都必须在本节有对应定义；组合条件必须展开到 Event 或最底层信号。
- 若真实 Event 的结果受计数/指针影响，在该 Event 的详细条件下定义边界信号；边界信号不是新的 Event 名。同一状态对内的计数组合无需逐项罗列。存在不可达组合时说明约束来源。
- 每个 condition 使用固定层级：有序编号、condition 名和一句话说明；`Fire来源`；fire 表达式；中间信号递归展开；最后写 payload 或 state update（若有）。
- Fire 表达式中的每个直接输入信号先用一句话说明其语义，再给出它的定义式或继续展开；不能只罗列信号名和公式。
- 语义说明使用“`signal_name`：一句话语义”格式；同一信号在本 module 文档中只在首次参与推导时说明，后续只引用名称或写“见第 N 条”。
- 公式和中间信号必须在第一次出现的 condition 下定义，后续只引用名称，不另设 Shared update/predicate 汇总小节。
- Condition 不写“谓词”“leaf”“event”标签，也不在本节解释信号来源；所需信号由 Interface 章节归档。
- Interface 必须覆盖 Condition、Output 和 Data Path 中引用的全部外部信号；来源不在 Condition 中重复标注。
- 模板：

```text
1. `condition_name`：一句话说明。
   - Fire来源：
     - `condition_name.fire = expression`
     - `signal_name`
```

## Data structure

描述真实存储的 `Data Structure`，并在此说明更新时机。

### State

- 描述真实存储的状态，以及语义状态如何被指针、计数器或其他结构压缩保存。
- 参数、常量和结构字段在首次出现处直接注明含义、位宽和取值范围。
- 如果状态被指针、计数器或其他结构压缩保存，直接在这里写明压缩方式和解码投影。
- 推荐格式：`` `IDLE / RESIDENT`：语义；压缩进 `wptr`/`rptr`；有效区间或解码关系。``

### Header

- 描述真实存储的、内部用于产生 condition 的信号。
- `Header` 区别于 `State` 和 `Payload`。
- 推荐写法：`` `header_name`：width；被 condition 使用；更新规则。``

### Payload

- 描述真实存储的 payload 信息。
- 推荐写法：先写真实存储端点，再单独定义 payload 名：

```text
`entry.payload[index]`：`Module_payload`
`Module_payload`：field_a、field_b、field_c
```

- 进入本 module 的 payload 使用 `` `<Module>_payload` ``；传给下游 module 的 payload 使用 `` `<DownstreamModule>_payload` ``；真实存储统一写作 `entry.payload`。
- 不在 `entry.payload` 行重复 payload 字段、width、depth、写入端点和读取端点；不使用 `*_storage`、`head_*`、`entry_payload` 或 `*_transfer` 作为额外语义名。
- FIFO 或寄存器阵列的组合读必须定义为 Static Info 的连续数据流；若 dequeue/read Event 的 payload 为 `∅`，Data Path 只连接该 Event 到指针或状态更新，不把 Static Info payload 画成由该 Event 触发。
- 同一数组的字段 schema 在下一行集中列出，不为每个字段重复写 storage、width 和读写端。

## Data Path

定义带有 payload 的 Event 或 Static Info 的值流连接：

```text
In-event Name -> Out-event Name
In-event Name -> Data Structure
Data Structure -> Out-event Name
Data Structure -> Data Structure
In Static Info Name -> Out Static Info Name
In Static Info Name -> Out-event Name
In Static Info Name -> Data Structure
In-event Name -> Out Static Info Name
Data Structure -> Out Static Info Name
```

空 payload Event 不形成 Data Path 边；它对指针、状态或控制寄存器的更新只写在 FSM condition 和 Data structure update 中。

每条连接使用一行箭头，随后只补充必要属性：

```text
`source` -> `destination`：payload schema；驱动 event/static info；transfer timing
```

不得使用 `Source=...; Destination=...` 的扁平键值串，也不得把 mux、demux、merge、fan-out 写成端点。

## Interface

由 FSM、Data structure 和 Data Path 推导并统一归档。Interface 是 module 对外契约的唯一输出定义点：

- In-event
- Out-event
- In/Out Static Info
- 接口时序

Interface 使用 `### In-event`、`### In Static Info`、`### Out-event`、`### Out Static Info`、`### Interface Timing` 分组；所有 Out-event 和 Out Static Info 的 schema、fire、payload、索引和时序只在这里定义。复杂 fire 只引用 FSM 中已经定义的 condition。
- Out Static Info 下的内部组合信号、guard 和 route 只作为对应对象的缩进条目，不另起四级标题。
- 同一输出对象只在对应分组定义一次；不要在 Interface 内重复建立第二个同名分组。

推荐格式：

```text
### In-event
- `event_name`：kind；payload/schema；fire；timing

### In Static Info
- `info_name`：schema、width、cardinality；source/use；validity

### Out-event
- `event_name`：kind；index/range；payload schema；fire（见 FSM）；timing

### Out Static Info
- `info_name`：schema、index/range；generation（见 FSM/Data structure）；validity

### Interface Timing
- clock/reset；采样边沿；backpressure；hold/cancel；flush/reset 行为
```
