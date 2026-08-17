# ORBE RTL Generation Constraints

**Version:** 0.3-draft  
**Status:** Draft; subject to review  
**Scope:** `rtl/orbe_rtl/` 及其后续集成的 ORBE backend RTL

## 1. Purpose

本文件规定 ORBE RTL 的生成、修改和集成约束。它的目标是让生成的代码具备以下特征：

- 可综合，或明确限制在综合工具支持的 SystemVerilog 子集内；
- 参数、类型、接口和时序语义清晰；
- 能够在 payload 位宽尚未完全冻结时继续迭代；
- 能够被独立编译、lint、仿真和综合检查；
- 与 `golden/DEFINITIVE_SPEC.md`、`golden/Interface_SPEC.md` 以及数据/控制流规范保持一致。

本文件是 RTL 生成和代码审查规范，不替代架构规范、接口规范或实际的 `typedef`/package 定义。

## 2. Authority and Change Rules

当不同文件出现冲突时，按以下优先级处理：

1. 用户明确确认的最新架构决定；
2. `golden/DEFINITIVE_SPEC.md`；
3. `golden/Interface_SPEC.md` 和对应的数据/控制流规范；
4. 本文件；
5. 现有 RTL 实现。

如果发现规范之间存在影响功能正确性、接口字段、位宽、复位语义或时序行为的冲突，必须先报告并确认，不能自行选择其中一个版本。

本文件中的关键词含义如下：

- **MUST:** 强制要求；不满足时不能提交为正式 RTL。
- **SHOULD:** 默认要求；只有在有明确理由并记录后才能例外。
- **MAY:** 可选做法。

## 3. RTL File Organization

`rtl/orbe_rtl/` 的代码按以下角色组织：

```text
rtl/orbe_rtl/
  typedefs.sv              // 公共 package、参数、enum、packed struct
  exe_subop_pkg.sv         // 执行子操作编码；如单独维护
  backend_top.sv           // backend 集成顶层
  <leaf_module>.sv         // 独立 RTL 子模块
  filelist.f               // 编译顺序；如工程需要
  RTL_GENERATION_CONSTRAINTS.md
```

### 3.1 Common definitions

- 公共参数、枚举、跨模块 payload 和跨模块结构体 **MUST** 定义在公共 package 中。
- 公共 package 文件 **MUST** 在使用它的模块之前编译。
- `typedefs.sv` 可以先以草案形式建立；在字段语义或位宽未冻结时，必须明确标记为暂定，不能把暂定值描述为最终接口。
- 同一个全局参数 **MUST NOT** 在多个模块中分别写出互相独立的默认值。

### 3.2 Leaf modules

- 每个叶子模块 **MUST** 有清晰的单一职责和可检查的端口契约。
- 叶子模块 **MUST NOT** 依赖 `backend_top.sv` 内部信号名才能工作。
- 叶子模块内部不得复制一份与公共 package 不一致的 payload 定义。
- testbench-only model、fake black box 或验证辅助模块应与可综合生产 RTL 分开存放，或在文件头明确标注其非综合性质。

### 3.3 `backend_top.sv`

- `backend_top.sv` **MUST** 负责模块实例化、跨模块连线、全局仲裁和顶层接口收口。
- 顶层可以在早期只生成骨架，但在子模块接口未稳定前不得声称为最终集成版本。
- 顶层不得通过未记录的位切片、隐式拼接或局部临时编码绕过公共 payload 契约。
- 顶层中产生的每一条全局控制信号都应能追溯到架构规范或接口/控制流规范。

## 4. Synthesizability

生产 RTL **MUST** 使用目标综合工具支持的、可综合的 SystemVerilog 子集。

生产 RTL 中 **MUST NOT** 使用以下仿真专用行为：

- `#delay`、时间控制或基于时间的行为模型；
- `initial` 过程作为硬件状态初始化的唯一方式；
- `force`/`release`；
- 文件读写、控制台输出、DPI、随机数或随机化对象；
- `class`、动态数组、关联数组、队列或 `mailbox`；
- `real`/`shortreal` 等非硬件数据类型；
- 依赖仿真器特性的系统任务或不可综合系统函数。

以下内容若用于验证，必须与生产 RTL 分离，或通过明确的仿真宏隔离：

- immediate/concurrent assertion；
- cover property；
- `$display`、`$fatal` 等调试语句；
- 仿真模型、参考模型和协议监视器。

循环可以使用，但循环边界必须在综合时可确定。数组、内存和函数的写法应使用综合工具明确支持的形式。

## 5. Parameters and Widths

### 5.1 Parameter policy

对于尚未固定、或可能因配置而变化的硬件尺寸，**MUST** 使用参数或公共 package 参数，例如：

- `XLEN`、`FLEN`；
- ROB、buffer、queue 的深度；
- ROB tag、寄存器地址、opcode/subop 的位宽；
- 端口数量、issue width、commit width；
- cache/LSU 接口中由架构参数决定的地址、数据和 mask 宽度。

不应把上述数值散落为局部 magic number，例如直接写 `logic [63:0]`、`logic [3:0] tag` 或固定的 `16`，除非该数值本身就是协议明确规定的固定常量。

### 5.2 Parameter placement

- 模块参数用于模块可独立配置的尺寸。
- 跨模块必须一致的参数应由公共 package 或统一配置源提供。
- 参数默认值必须是当前工程有效的配置；若只是临时值，必须在注释或参数包中注明 `provisional`/“暂定”。
- 参数之间存在依赖时，**MUST** 使用明确的派生表达式，例如 `TAG_W = $clog2(ROB_DEPTH)`，不能让调用者分别填写可能互相矛盾的值。
- 不应为了形式上的参数化而参数化硬件语义。只有尺寸、容量和明确的配置项才应参数化。

### 5.3 Entry depth and index width

第一版 ORBE RTL 只支持 entry 数量为 2 的幂的数组、表、buffer、queue 和环形结构。

- 当 entry 使用完整二进制地址直接索引时，`NUM_ENTRIES` / `DEPTH` **MUST** 满足 `NUM_ENTRIES == 2**IDX_W`。
- `IDX_W` / `TAG_W` **SHOULD** 从 entry 深度派生，例如 `localparam int IDX_W = $clog2(NUM_ENTRIES)`；如因顶层接口需要保留为显式参数，必须增加静态一致性检查。
- 环形指针若依赖自然溢出回绕，深度 **MUST** 是 2 的幂。
- 第一版不支持非 2 的幂 entry 深度；如果未来支持，必须增加显式范围检查、比较/回绕逻辑和对应验证。
- 不允许出现 `NUM_ENTRIES=8` 但 `IDX_W=4` 这类会让地址访问不存在 entry 的参数组合。

### 5.4 Width and signedness

- 位宽必须能从字段语义和公共参数推导出来。
- 有符号运算必须显式声明 signed 属性或显式转换；不能依赖工具对 signed/unsigned 的隐式推断。
- 常量应尽量使用有尺寸的写法，例如 `8'd0`、`XLEN'(value)` 或 `'0`，避免无尺寸常量导致表达式扩展错误。
- 连接不同宽度的信号时，必须明确说明截断、零扩展或符号扩展的意图。
- 端口、数组、packed struct 的方向和索引约定必须保持一致；不得依靠隐式降宽来消除 lint 警告。

## 6. Payload and Type Discipline

- 跨模块 payload **SHOULD** 使用 `typedef struct packed`，而不是裸的宽向量加手工 bit slice。
- payload 字段顺序、字段名、位宽和语义一旦进入接口契约，任何修改都必须同步更新相关规范、生产者、消费者和测试。
- payload 位宽未冻结时，先冻结字段语义和生产/消费关系；位宽可以通过公共参数迭代，但不得让不同模块各自猜测字段布局。
- 模块间传递的 payload **MUST NOT** 在一个模块中重新定义成结构相同但类型不同的 struct。
- 对结构体进行整体赋值时，应确保未使用字段有明确的默认值，避免产生 X 传播或依赖未初始化字段。
- 跨模块连接优先使用命名端口连接；对宽总线的整体连接优先于无注释的位拼接。
- 如果必须使用拼接或切片，必须在附近注明字段顺序、宽度和截断/扩展意图。

## 7. Sequential and Combinational Logic

### 7.1 Sequential logic

- 时钟触发的状态更新 **MUST** 使用 `always_ff @(posedge clk)` 或项目明确规定的等价形式。
- 一个寄存器或状态变量 **MUST** 只有一个过程块负责写入。
- 同一时钟域内不得混用多个未说明的时钟或边沿。
- ORBE 第一版使用单一 `clk` 时钟域，正常状态更新在 `posedge clk` 发生。
- 全局 reset 信号命名为 `rst_n`，**MUST** 是 active-low。
- reset 策略为**active-low 异步复位，直接分发**。`backend_top.sv` 不放置 `rst_n_sync` 或 reset synchronizer；当前版本沿用 `rtl/be_code` 的直接 reset 分发方式。
- `backend_top.sv` **MUST** 将原始 `rst_n` 直接连接到各个子模块的 `rst_n` 端口；第一版不使用 `rst_n_sync`。
- 状态模块应采用 active-low 异步复位形式，典型写法为 `always_ff @(posedge clk or negedge rst_n)`。
- 复位时必须对所有会影响功能正确性的状态给出确定值，包括 valid、busy、tag、FSM state、控制寄存器、输出寄存器、指针、计数器和 flush/recovery 相关状态。
- `global_flush_late`、局部 clear、commit、alloc、writeback 等运行期控制信号 **MUST NOT** 放入异步敏感表；它们只能作为同步控制参与 `posedge clk` 状态更新。

### 7.2 Combinational logic

- 组合逻辑 **MUST** 使用 `always_comb`、连续赋值或等价的明确组合表达式。
- `always_comb` 中每个输出和临时变量在所有路径上都必须有赋值，避免 latch。
- 推荐在组合块开头设置默认值，再覆盖满足条件的分支。
- 组合逻辑不得产生组合环路；跨模块 ready/valid 互相依赖时必须明确打断环路的寄存器或仲裁边界。
- 不得在同一个组合块和时序块中同时驱动同一个变量。

### 7.3 Priority and same-cycle behavior

- 多个条件同时成立时的优先级必须显式编码，不能依赖 `if` 顺序之外的隐含行为。
- 对写回、提交、flush、异常、分支恢复、store drain 等互斥或抢占关系，必须在代码附近写出优先级依据。
- 同周期产生和消费的数据必须明确是旧值、新值、旁路值还是寄存器值。
- 对非阻塞赋值造成的时序边界，不得用组合逻辑猜测“同周期已经更新”的状态。

## 8. Interfaces and Handshakes

- 每个端口必须有明确的方向、宽度、时序关系和所有者。
- `valid/ready`、`req/ack`、`busy/enable`、`flush/clear` 等握手协议必须说明：谁产生、谁消费、保持多久、何时允许撤销、背压如何传播。
- 未定义的接口信号不得通过默认常量“先接上再说”；应标记为暂定并确认其语义。
- 端口连接必须避免隐式宽度转换、隐式 signed 转换和隐式 net 声明。
- 对外接口的保留字段或暂不使用字段必须明确 tie-off，并保证不会改变协议语义。
- 跨模块接口发生变更时，必须同时检查顶层、所有生产者、所有消费者和对应测试。

## 9. Reset, Flush and State Recovery

- reset、global flush、局部 clear 和 commit 的作用范围必须分别定义，不能用一个信号承担未说明的多种语义。
- reset 优先级 **MUST** 高于所有运行期同步控制。同步状态更新优先级为：`reset > global_flush_late / local clear > normal operation`。
- 复位期间，所有控制输出和数据输出必须为确定值；第一版要求复位输出为 0，除非接口规范明确规定其他安全值。
- ARF、Buffer、PC_File 以及无 valid 保护且会被组合读出的存储结构，第一版 **MUST** 在 reset 时严格清零。
- 纯数据通路寄存器只有在不影响系统功能、且有明确 valid/生命周期保证不会在无效时被消费的前提下，才可以不复位。
- flush 发生时，所有可能包含错误路径状态的 valid、busy、pending、queue entry、tag mapping 和旁路状态必须按照规范清除或保留。
- flush 与同周期 writeback/commit 同时发生时，优先级必须显式实现并有验证用例。
- 恢复 PC、ROB 指针、rename/tag 状态和外部请求取消行为必须能够追溯到规范。
- 任何“flush 后保留的状态”都必须在模块说明和测试中明确列出。

## 10. Naming and Readability

- 模块名、文件名和现有工程命名风格应保持一致；不得为了局部偏好随意重命名已有接口。
- 时序状态建议使用 `_q`，组合计算结果建议使用 `_d` 或有语义的名称；valid、ready、busy、enable 等控制信号应保持语义一致。
- 避免使用 `tmp`、`data1`、`sig_a` 等无法表达用途的跨模块信号名。
- 每个复杂模块文件开头或模块声明附近应简要说明职责、时钟/复位和主要接口。
- 注释解释设计意图、优先级和边界条件，不重复逐行描述语法。
- 生成代码应保持稳定格式，不应混入与本次功能无关的重排或大规模重命名。

## 11. Unfrozen Specifications

当 payload 字段、位宽、接口方向或握手语义尚未完全确定时：

1. 先列出已确定的字段语义、生产者和消费者；
2. 将可配置位宽集中到参数或 package；
3. 在代码和接口文档中标记暂定项；
4. 不得让不同模块对同一字段分别做不同假设；
5. 不得为了通过编译而删除未知字段、填入未确认的功能语义或随意选定有影响的默认值；
6. 如果不确定性会影响接口正确性、状态机行为、综合结构或验证结果，必须暂停生成并请求确认。

允许先生成以下内容：

- package 和参数骨架；
- 字段语义已知但宽度可参数化的 payload 草案；
- 子模块端口草案；
- `backend_top.sv` 的实例化和连线骨架。

不应在规格未冻结时声称以下内容已经完成：

- 最终 payload 位布局；
- 最终 `typedefs.sv` 版本；
- 最终 `backend_top.sv` 集成；
- 全局握手、flush、commit 优先级已经验证。

## 12. Verification and Acceptance

每个生成或修改的模块至少应完成与改动范围相匹配的检查：

- 语法和编译检查；
- lint 检查，重点关注宽度、signedness、latch、多驱动、未连接端口和隐式转换；
- 关键模块的定向仿真；
- 涉及状态机、握手、flush、旁路或 commit 的修改，应增加相应边界测试；
- 影响跨模块接口的修改，应重新编译并检查所有相关模块；
- 影响顶层集成的修改，应至少进行一次顶层 elaboration/compile 检查。

综合检查可分阶段进行：

- 叶子模块完成后先进行单模块综合或综合友好性检查；
- `backend_top.sv` 接口稳定后进行顶层 elaboration；
- 所有跨模块路径完成后进行完整 RTL 综合检查。

仿真通过不等于可综合。任何依赖仿真专用语句、未定义初始化或工具特定行为的代码都不能仅因仿真通过而接受。

## 13. Required Module Header Information

新增或大幅修改的模块应在文件或模块附近说明：

- 模块职责；
- 时钟和复位名称、极性及同步属性；
- 参数含义及其默认值是否暂定；
- 输入/输出接口的握手语义；
- 状态更新和输出产生的时序；
- reset、flush、异常或 clear 对内部状态的影响；
- 尚未冻结或需要上游确认的项目。

## 14. Open Items for Review

以下内容在本第一版中只建立约束方向，尚未替 ORBE 最终接口作出决定：

- payload 的最终字段集合和位宽；
- `XLEN`、`FLEN`、ROB 深度、tag 宽度和 issue/commit 宽度；
- `typedefs.sv` 与 `exe_subop_pkg.sv` 的最终拆分方式；
- `backend_top.sv` 的最终对外端口和 LSU/CSR/前端边界；
- 目标综合工具、lint 工具和项目级编译命令；
- 生产 RTL、fake black box 和 testbench 的目录划分。

在上述项目未确认前，本文件作为生成约束草案使用；不得把其中的示例参数或文件布局解释为已经冻结的微架构接口。
