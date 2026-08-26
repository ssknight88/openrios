# Module 文档骨架

## 总原则

- 谁写的判据只有一条：**可不可推导**。推得出来交 AI，推不出来人写。
- 零 state 的 module：`State` / `State Transition & Condition Name` / `Detailed Condition Description` 三节可全空，合法。
- Event 在【定义点】处唯一定义，其他位置只引用。

## Submodule

- 放入 submodule 文档链接即可。

## FSM

- 保证 `State Transition & Condition Name` 全覆盖。
- `Condition Name` 手写。

### State

#### Per-entry State

- 必须存在。
- 模板：

```text
Per-entry State: detailed statement
```

#### Structure State Mapping

- 描述 `Structure State` 如何 mapping 回 `Per-entry State`。
- 模板：

```text
Per-entry State: Structure State statement
```

### State Transition & Condition Name

- 完备描述存在的 `Per-entry State` 转换，`Condition Name` 仅标注名称。
- 若 `Current -> Next` 有重复，则另起一行。
- 模板：

```text
Current Per-entry State -> Next Per-entry State: Condition Name
```

### Detailed Condition Description

- 详细描述【定义点】`Condition event` 产生的细节逻辑。
- 模板：

```text
Condition: detailed statement
```

## Output

### Out-event

- 详细描述【定义点】`Out-event` 产生的细节逻辑。

### Out Static Info

- 详细描述【定义点】`Out Static Info` 产生的细节逻辑。

## Data structure

描述真实存储的 `Data Structure`，并在此说明更新时机。

### State

- 描述真实存储的 `Per-entry State` 和 `Structure State`。

### Header

- 描述真实存储的、内部用于产生 condition 的信号。
- `Header` 区别于 `State` 和 `Payload`。

### Payload

- 描述真实存储的 payload 信息。

## Data Path

定义带有 payload 的 event 的连接：

```text
In-event Name -> Out-event Name
In-event Name -> Data Structure
Data Structure -> Out-event Name
Data Structure -> Data Structure
```

## Interface

由前述定义推导并归档：

- In-event
- Out-event
- In/Out Static Info
- 接口时序
