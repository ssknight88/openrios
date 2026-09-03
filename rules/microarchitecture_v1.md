# 微架构文档规范

本文档主要规范如何与AI cowork生成最终的machine readable的架构文档。

## 概念

### 定义

规范适用于任意尺度的微架构描述。只有 **module** 一个概念：module 调用别的 module，被调者即 submodule；对本层而言 submodule 退化为「一组接口 event + 数据通路上的一个端点」。分形终点是无可调用部分。
**Module包含**：
- 接口（含 output 的产生逻辑）
- 数据通路（数据流动；微架构 = 流动 + 存储，存储结构见下节）
- 控制通路（能不能流、流向哪；概念统一为广义 FSM）

### 基本规范

#### Event规范
> 可以被抽象的控制行为，存在明确的fire判据，FSM转换的condition也是一种event

**fire 判据：**
> 所有event仅当拍有效，下一拍将重新判断
> 概念分类，供理解 event 的行为差异；不作为字段写进 event 定义
- **Transaction**：
	- **valid ∧ ready 握手**
	- **credit based 握手**
- **Notify**：生产者fire-and-forget（wakeup、flush）；消费者保证 always-ready

**Static Info**：无 fire，纯信息传递，不是 event（occupancy、be_idle）

**event 实现定义**（此处只给格式；每条 event 的定义落在**产出它的 module 的输出规范**，全文档仅一处，其余各节只引用 event 名称）：
- **Fire来源**：本 event 何时 fire。**fire 即一次握手**。写法见本节的 [Fire来源拆解规范](#fire来源-拆解规范)。
- **触发来源**：（仅概念，不作为字段要求）
	- **state-driven**：由 FSM 的 state / 转移决定（Mealy 挂转移，Moore 挂状态）
	- **comb-driven**：由组合谓词决定，读一条或多条 in-event / static info 当拍算出
- **payload 来源**：逐字段写明生成逻辑，无则 ∅；
- **payload 定义**：**（全文档唯一定义点）**
	- schema
	- 位宽 / slot数 / 拍数

##### Fire来源 拆解规范

> 适用于**任何 event 的 fire**——FSM 转移的 condition 与 out-event 同规则（condition 就是 event）。

- 来源：从该 event 名出发**自顶而下**往下拆
- 拆分中间层表述：
	- 按照信号语义边界抽象，切记不要一层内容过多。
	- 标识符：`反引号`
	- 信号：使用`信号a`描述，格式可以是代码`interface_a`或者自然语言`接口信号a`，目前包含`谓词`和`leaf`和`event`
		- **`谓词` / `leaf` 判据：本节内有没有它的定义式**——有则为`谓词`，无则为`leaf`
		- `谓词`：中间描述，用于边界抽象，防止一层内容过多
			- 在**首次用到的 event 下**定义，其余处只写「见 `X`」，不重复展开
			- 某谓词只服务某条 out-event 的 Fire来源，则它随该 out-event 定义在 Output
		- `leaf`：叶子节点信号，一定源于Data structure或者Interface
			- 核对义务：leaf 全集 ⊆ Data structure ∪ Interface，差集即为漏项
		- `event`：引用event。`event.fire` 取其 fire；`event.<字段>` 取其 payload 字段，字段须在该 event 的 payload 定义里
	- 默认必须写成可求值的表达式，如`a = b ∧ ¬c`。a，b，c为信号。
		- 写不成表达式 = 该处语义未定，标 `⟨需确认⟩`
- 拆分结束：每条叶子都是 `leaf` 或 `event`；`谓词` 必须继续展开。

**example：**（虚构信号，只演示写法，不保证逻辑正确；**括号内是讲解，真实文档不写**）
```
- `cond_a[i]`: S0 -> S1（首行给名字与一句人话）
	- `cond_a[i] = pred_x[i] ∧ ¬cond_b[i]`（可求值表达式）
	- `pred_x[i]`（谓词：本节有定义式，故必须继续展开）
		- `pred_x[i] = ev_in.fire ∧ sel[i]`
		- `ev_in.fire`（event：取 fire）
		- `sel[i]`（leaf：来源 Interface，`ev_in` 的 payload）
	- `¬cond_b[i]`: 见 `cond_b[i]`（与 `cond_b` 同出 S0，两转移必须互斥）

- `cond_b[i]`: S0 -> S2
	- `cond_b[i] = pred_x[i] ∧ pred_y[i] ∧ ¬out_ev_valid`
	- `pred_x[i]`: 见 `cond_a[i]`（首次用到处已定义，此处只引用）
	- `pred_y[i]`（谓词）
		- `pred_y[i] = ∀j: flag[i][j] ∨ (ev_bus[k].tag == key[i][j])`
		- `flag[i][j]`（leaf：来源 Data structure / Header）
		- `ev_bus[k].tag`（event：取 payload 字段，`tag` 须在 `ev_bus` 的 payload 定义里）
		- `key[i][j]`（leaf：来源 Data structure / Header）
	- `¬out_ev_valid`: 见 Output（谓词只服务 out-event `out_ev` 的 Fire来源，故随它定义在 Output）

- `out_ev`: 本 module 产出（out-event 的 Fire来源，同一套写法）
	- `out_ev.fire = out_ev_valid ∧ downstream_ready`（握手在此定义，Transaction 型）
	- `out_ev_valid`（谓词）
		- `out_ev_valid = ∃i: pred_z[i]`
		- `pred_z[i]`（谓词）…
	- `downstream_ready`（leaf：来源 Interface，in static info）

- `cond_c[i]`: S1 -> S0
	- `cond_c[i] = ev_done.fire ∧ 命中判定[i]`
	- `命中判定[i]`（自然语言信号名亦可）
		- ⟨需确认⟩ 匹配键未定：`ev_done.id` 比 `entry[i].id`，还是下发时回带的 idx
```

#### 数据结构(per-entry data)
**字段三角色**（物理上全是触发器、都算广义 state，但文档角色三分；判据是消费者式的——看有没有谓词读它，可逐字段核对）：
- **state 枚举**：每个取值对应一种不同的对外行为；进 state 列，穷举
- **header 字段**：被本结构的谓词消费（比较/匹配，如 addr、age）；只出现在 guard 里，永不作为 state 维度，需要明确的更新规则（消费语义导致）
- **payload**：本结构无任何谓词读它；不出现在 FSM 描述里，只在字段 schema 表里占位——schema 定义在 event 实现定义处，此处只引用

**payload 相对性**（分形推论）：同一字段跨层换身份——payload传递之后可能在后一级变成control（state or header）

### Module骨架
#### 接口规范

> 接口**不对称**：input 由内部推导而来，output 直接定义逻辑。分类（Transaction / Notify / Static Info）见 event fire 判据，此处只管方向。

**input —— 由内部逻辑导出**

- in-event = 控制通路中所有 condition 引用的 event 的并集
- in static info = 所有谓词读到的外部静态信息的并集
- 写完内部逻辑，input 集合即完备；input 接口表可由工具生成。

**output —— 由外部依赖决定**

- out-event、out static info需要output章节声明「如何产生」
- 存在理由都在**外部**，本 module 的内部逻辑无法推导出output

##### 输出规范

**out-event**
- 本 module 产出的每条 event，按 event 实现定义的格式写全——此处即该 event 的唯一定义处

**out static info**
- 无 fire，不是 event，不上数据通路图
- 只声明 schema

#### 数据通路规范

数据通路的核心是一张数据流向图。表示起点和终点，以及对应中间的分叉路径有哪些。最佳的展现形式是带数据标定的微架构图。
> 注：数据通路不考虑分叉控制。只考虑数据的转移。
> 本节是 **event 的投影**：一条边 = 一条 payload 非空的 event，fire 一次 = 传输一次。

**端点：**
1. 存储结构（描述归数据结构规范）
2. 接口（描述归接口规范）

**数据通路连接属性：**
- 驱动 event：这条边是哪条 event 的投影，引用即可
- payload schema：引用event即可
- 源端点 → 目的端点

> demux / mux / merge / fan-out 不写，都是推论。**同终点看写向哪组 payload**：
> - 同一组 payload → 必须互斥 → **mux**，谁胜出归控制通路的仲裁
> - 不同组 payload → **merge**，可同时到达
> - 同一组 payload 而不互斥 = 错误
>
> 同起点的互斥 event = **demux**；一条 event 多个消费者 = **fan-out**。

#### 控制通路规范

控制通路统一为广义 FSM。总判据：**状态住在信息不可压缩处（凡是能通过已有信息得到的都不是状态，只是视图）**。

**FSM**：
> transition = (state, condition, next state, action/output)
- **state**：所有的entry都应该有状态，只是可能会信息压缩为structure FSM
- **condition**：**condition 就是 event**——event 的消费者。FSM 表的 condition 列只写 event 名（FREE→WAIT: allocate），fire 展开见该 event 的 Fire来源，全文档一处定义。
- **output**：out-event 中 state-driven 的那部分（Mealy 挂转移 / Moore 挂状态）；out-event 全集与定义见输出规范。

**控制形态谱系**（按 state 含量排，本质是 state 的压缩程度）：
- **一端：纯组合**（select / 仲裁 / stall / bypass）——零 state，决定每拍从输入重算；仲裁与排序策略住这里
- **中间：FSM，state 的两种存法**（压缩程度由序约束决定）：
	- **per-entry FSM**——state 不可压缩，逐 entry 存（CAM 型 / 乱序）；structure 视图（free / full / occupancy）= 聚合投影，不另存
	- **structure FSM**——state 压缩进指针 / 计数器（FIFO 型 / 序约束坍缩可达空间）；per-entry 视图（valid）= 解码投影（区间判定）
- **另一端：纯 pipeline reg**——只有触发器没有决定，字段全是 payload；控制含量为零，实为数据通路的延迟端点（1-entry 存储的退化：每拍无条件搬运）

**对偶律**：CAM 与 FIFO 互为镜像——per-entry↔指针、聚合↔解码互换。序约束越强，状态越从 per-entry 向指针集中；偏序结构（age matrix）= 混合表示。

## 配套资产

- Module 文档骨架：[`flows/spec-authoring/templates/module.md`](../flows/spec-authoring/templates/module.md)
- 控制逻辑流程示例：[`flows/spec-authoring/examples/cam-fifo.md`](../flows/spec-authoring/examples/cam-fifo.md)
