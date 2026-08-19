# CAM 与 FIFO：控制逻辑双例

> [[微架构文档规范]] 的试穿场，核心是 control logic。素材来自 private_be_arch 的 D1_Stage.md / D1_IssueLogic.md。

## 描述流程（六步）

1. **定 per-entry state**：先写逻辑全枚举，不管压缩——structure state 是由访问方式决定的信息等价表示，后置
2. **定 condition**：每条转移挂一个 event 名（condition 就是 event），先开支票
3. **定 data path**：边表——运值的边入表，送信（只带谓词参数）
4. **细化 condition**：valid / ready 分解 + guard——最难的一步。guard 的复杂组合逻辑用 Kmap 收敛；**guard 引用的每个 header 必须有来源，来源完备即自然对齐了数据结构与接口**
5. **定完整的 data structure**：schema + 字段三角色核对
6. **定完整接口**：收词表——④ 里追溯到跨界的 event 收进接口词表（in / out 双向，各标 fire 判据类：Transaction / Broadcast）；层内名标等价（allocate ≡ disp 的 per-entry 分解）；聚合投影中有父层消费者的收进 Static Info。**前五步做完，这一步是收尾归档，不产生新设计**

---

## 【重写】Reservation Station（CAM 型）

> 按 [[微架构文档规范#Module文档骨架]] 重排。素材同下方「例一」，未新增设计结论。
> `⟨待填⟩` = 骨架要求、原素材没有的信息；`⟨需确认⟩` = 原素材有歧义、需你裁决。

### Submodule

无——RS 是叶 module，不调用其他 module。

### FSM

#### State

##### Per-entry State

- FREE: 表项空闲，可被 allocate 占用
- WAIT: 已占用，等待全部源操作数 ready
- INFLIGHT: 已发往下游，等待 confirm 释放或 cancel 回退

> 无 READY——spec 唤醒瞬态不落盘；ready 是每拍重算的谓词，不是状态

##### Structure State Mapping

无——CAM 无序约束，state 不可压缩、逐 entry 存；free / full / occupancy 是聚合投影，不另存。

#### State Transition & Condition Name

- FREE -> WAIT: allocate
- FREE -> INFLIGHT: direct_issue
- WAIT -> INFLIGHT: issue
- INFLIGHT -> FREE: deallocate
- INFLIGHT -> WAIT: replay
- ANY -> FREE: flush_hit

#### Detailed Condition Description

> 只定义**内部 condition**。in-event（disp / wakeup_wb / wakeup_spec / cancel / confirm / flush）不在此定义——定义在产出它的 module。
> 逐层拆到信号为止；信号从哪来（in-event / header / 聚合投影）在 Data structure 与 Interface 收口。
> `i` = entry 下标，`j` = 源操作数下标，`k` = 唤醒总线通道下标。

- `allocate[i]`: FREE -> WAIT，占表且不直发
	- `allocate[i] = alloc_hit[i] ∧ ¬direct_issue[i]`
	- `alloc_hit[i]`: 本拍 disp 的写入目标是 entry i——**写入动作，直发时同样成立**
		- `alloc_hit[i] = disp.fire ∧ alloc_sel[i]`
		- `alloc_sel[i]`: 分配器（find-first-free，纯组合）输出指向 i
			- 定义域 ⊆ `{i | state[i] == FREE}`
			- 同拍唯一：`∑ alloc_sel[i] ≤ 1`（单派遣口）
		- 表项写入与数据通路边由它驱动；`allocate[i]` 只管转移落点
	- `¬direct_issue[i]`: 与 `direct_issue[i]` 同出 FREE，一个 entry 一拍只走一条转移，故两个**转移条件**必须互斥；`alloc_hit[i]` 不受此约束

- `direct_issue[i]`: FREE -> INFLIGHT，本拍派遣的 uop 绕过 WAIT 直接发射
	- `direct_issue[i] = alloc_hit[i] ∧ disp_ready ∧ ¬issue_valid`
	- `alloc_hit[i]`: 见 `allocate[i]`
	- `disp_ready`: 入表 uop 的全部源操作数当拍可用
		- `disp_ready = ∀j: bt_rdy[j] ∨ mealy_hit_d[j] ∨ spec_hit_d[j]`
		- `bt_rdy[j]`: Busy Table 初值，随 disp 带入——此拍 `rdy[i][j]` 尚未落盘，不能读
		- `mealy_hit_d[j] = ∃k: wakeup_wb[k].tag == disp.prs[j]`
		- `spec_hit_d[j] = ∃k: wakeup_spec[k].tag == disp.prs[j]`
	- `¬issue_valid`: 本拍 age matrix 无 ready 候选，select 优先、direct 让路；`issue_valid` 见 Output

- `issue[i]`: WAIT -> INFLIGHT，被 out-event `issue` 选中
	- `issue[i] = issue.fire ∧ issue_sel[i]`
	- `issue` / `issue_sel[i]`: out-event，定义点在 Output

- `deallocate[i]`: INFLIGHT -> FREE，下游确认后释放表项
	- `deallocate[i] = (state[i] == INFLIGHT) ∧ confirm.fire ∧ confirm_hit[i]`
	- `confirm_hit[i]`: 本 entry 是被确认的那条
		- `confirm_hit[i] = (confirm.id == entry[i].rob_id)` ⟨需确认：匹配键是 rob_id，还是 issue 时下发、由下游原样回带的 entry idx⟩

- `replay[i]`: INFLIGHT -> WAIT，已发射的 uop 被取消，退回等待
	- `replay[i] = (state[i] == INFLIGHT) ∧ cancel.fire ∧ cancel_hit[i]`
	- `cancel_hit[i]`: 本 entry 是被取消的那条
		- `cancel_hit[i] = (cancel.id == entry[i].rob_id)` ⟨需确认：匹配键同 confirm，两者须一致⟩
	- 不回滚 `rdy` —— spec 唤醒从未落盘，无可回滚

- `flush_hit[i]`: ANY -> FREE，本 entry 被 flush 波及
	- `flush_hit[i] = flush.fire ∧ (flush.is_full ∨ age_kill[i])`
	- `age_kill[i]`: 比 flush 点更年轻的一律杀
		- `age_kill[i] = younger(entry[i].rob_id, flush.rob_id)`
		- `younger(a, b)`: rob_id 的环形序比较 ⟨需确认：RS 侧是否自带 wrap / loopbit，还是靠 ROB 保证 in-flight 不跨圈⟩

### Output

#### Out-event

- issue: age matrix 选中的 entry 发往 issue pipeline
	- Fire来源: `issue_valid` —— 下游 ready 属 Transaction 握手，按规范不进 Fire来源
		- `issue_valid = ∃i: req[i]`
		- `req[i]`: 本 entry 是本拍的合法候选
			- `req[i] = (state[i] == WAIT) ∧ all_ready[i] ∧ type_ok[i]`
			- `all_ready[i]`: entry i 的全部源操作数当拍可用
				- `all_ready[i] = ∀j: rdy[i][j] ∨ mealy_hit[i][j] ∨ spec_hit[i][j]`
				- `rdy[i][j]`: 已落盘的就绪位——**唯一带 action 的项**，更新式见 Data structure / Header
				- `mealy_hit[i][j]`: 本拍 wb 唤醒的同拍旁路，不等 `rdy` 落盘
					- `mealy_hit[i][j] = ∃k: wakeup_wb[k].tag == prs[i][j]`
				- `spec_hit[i][j]`: 本拍投机唤醒，只进 guard 不落盘（瞬态）
					- `spec_hit[i][j] = ∃k: wakeup_spec[k].tag == prs[i][j]`
				- 有无 `next()` 即 persistent / transient 的分界：`rdy` 落盘，两个 hit 不落盘
			- `type_ok[i]`: 类型位准入 ⟨需确认：保序策略是过滤候选集，还是只改变 select 优先级⟩
		- `issue_sel[i]`: age matrix 在 `{i | req[i]}` 中选最老
			- 两两比较 `entry[i].rob_id`，输出唯一最老 idx
			- 同拍唯一：`∑ issue_sel[i] ≤ 1`（单发射口）
	- 触发来源: comb-driven —— age matrix 纯组合，零 state
	- payload 来源: 逐字段取自 issue_sel 命中的 entry；ctrl / prd / imm 原样搬出，prs tag 不出（发射后不再匹配）
	- payload 定义: schema `{ctrl, prd, imm}` ⟨位宽待填⟩；slot 数 1（单发射）；拍数 ⟨待填⟩

#### Out Static Info

- free 计数: per-entry state 的聚合投影 `free = #{i | state[i] = FREE}`，纯组合不另存
	- schema: 计数值 ⟨位宽待填⟩
	- 外部消费者: D1 负载均衡 · disp 的 ready（`free > 0`，无独立 ready 线）

### Data structure

> **更新时机**：allocate 拍写入 header + payload；wb 唤醒拍写 rdy；issue 拍不改（副本死期 = deallocate，entry 保留备 replay）；deallocate 拍整条失效。

#### State

- `entry_state`: FREE / WAIT / INFLIGHT，逐 entry 存

#### Header

- `prs[i][j]`: 来源 disp；被 `mealy_hit` / `spec_hit` 的 CAM 匹配消费
- `rdy[i][j]`: 被 `all_ready[i]` 消费——**唯一带 action 的 header**
	- `next(rdy[i][j]) = alloc_hit[i] ? bt_rdy[j] : (rdy[i][j] ∨ mealy_hit[i][j])`
	- `alloc_hit[i]` 拍由 Busy Table 初值覆写；此后 wb 唤醒命中即置 1 并保持
	- `spec_hit[i][j]` 不进此式——瞬态，只进 guard
	- 无显式清零：`deallocate[i]` 后表项转 FREE，下次 `alloc_hit[i]` 整体覆写
- `entry[i].rob_id`: 来源 disp；被 `issue_sel` 排序 + `age_kill` / `confirm_hit` / `cancel_hit` 消费
- `type_ok[i]` 的类型位: 来源 disp；被 `req[i]` 消费

#### Payload

- ctrl / prd / imm: Full Decode 控制信号，无谓词读；schema 引用 out-event `issue` 的 payload 定义

### Data Path

> 源端点 -> 目的端点: 驱动 event；payload 引用

- disp -> entry 阵列: 驱动 `alloc_hit[i]`；payload 引用 disp（move）
	- 驱动的是**写入动作** `alloc_hit`，不是转移条件 `allocate`——直发时表项照写、仍占表项，只是状态直接落 INFLIGHT
- disp -> issue: 驱动 direct_issue；payload 引用 issue（copy，entry 同拍写入，权威副本在 entry）
- entry 阵列 -> issue: 驱动 issue；payload 引用 issue（copy，副本死期 = deallocate）

wakeup_wb / wakeup_spec 不入边表——只送 tag（谓词参数），不运值。data-capture 变体时 CDB 的 data 束才入表。

### Interface

> 全部由前面推导得到，不新增设计。

- **in-event** = Detailed Condition 与 Output 的 Fire来源 引用到的外部 event 之并集
	- disp · wakeup_wb[k] · wakeup_spec[k] · cancel · confirm · flush
- **out-event** = Output 清单
	- issue
- **in static info** = 谓词读到的外部静态信息
	- 空 ⟨需确认⟩ —— 若 Busy Table 初值随 disp 的 payload 传入则为空；若是直接读外部表，则它是一条 in static info。原素材未区分
- **out static info** = Output 清单
	- free 计数

---

## 例一：CAM 型（Reservation Station）

### ① per-entry state

`FREE / WAIT / INFLIGHT`

- 无 READY——spec 唤醒瞬态不落盘，ready 是每拍重算的谓词，不是状态
- CAM 无序约束 → state 不可压缩，逐 entry 存；**无 structure FSM**（free / full / occupancy 全是聚合投影，不另存）

### ② state transition & condition（event 名）

- FREE → WAIT：allocate
- FREE → INFLIGHT：direct issue
- WAIT → INFLIGHT：issue
- INFLIGHT → FREE：deallocate
- INFLIGHT → WAIT：replay
- ANY → FREE：flush / partial flush（谓词杀：逐 entry 判 age）

### ③ data path（边表）（condition & output）

- `disp → entry 阵列`：驱动 allocate；move（Direct Issue 时照走，"仍占表项"）
- `disp → issue pipeline`：驱动 direct issue；copy（entry 同拍写入，权威副本在 entry）
- `entry 阵列 → issue pipeline`：驱动 issue；copy（**副本死期 = deallocate**——entry 保留备 replay，confirm 才释放）
- wakeup 两族不入边表：只送 tag（谓词参数）不运值；data-capture 变体时 CDB 的 data 束才入表

### ④ condition 细化（valid ∧ ready）

- **allocate** = disp （接口传递，外部判断）
- **direct issue** = allocate ∧ 操作数真 ready（Busy Table 初值 + 本拍唤醒）∧ **issue 拉低**（select 优先、direct 让路——同拍裁决）
- **issue** = issue valid（age matrix 输入 ready entry、输出最老 idx；有 ready 候选即 valid）∧ issue pipeline ready
	- `all_ready[i] = ∀j: rdy[j] ∨ spec_hit[j](本拍) ∨ mealy_hit[j](本拍)`
	- wb 唤醒 ∧ tag 命中 → **action 写 rdy[j]**（持久）；spec 唤醒**只进 guard 不落盘**（瞬态）——有无 action = persistent / transient 的分界
- **deallocate** = confirm（E1 forwarding 成功）
- **replay** = cancel ∧ 命中（spec 唤醒从未落盘，无需回滚）

### ⑤ data structure（schema + 字段三角色）

- **state**：entry_state
- **header**（逐个标来源）：prs tag（来源 disp；CAM 匹配消费）、rdy 位（来源 Busy Table 初值 + wb 唤醒更新）、rob_id/age（来源 disp；排序 + flush 谓词）、类型位（来源 disp；保序策略）
- **payload**：Full Decode 控制信号、prd、imm——发射时无需再译码

### ⑥ 接口

- **in-event**：disp（Transaction；ready = free > 0，无独立 ready 线）、wakeup_wb[k]（Broadcast）、wakeup_spec[k]（Broadcast，瞬态）、cancel、confirm（皆 Broadcast）、flush（Broadcast，谓词参数）
- **out-event**：issue（Transaction，去 issue pipeline / RF1——下游可 stall，有否决）
- **Static Info**：occupancy / free 计数。allocate ready/有空位

### 定性

per-entry state 是本体；聚合投影（free / full）以 Static Info 喂 D1 负载均衡；仲裁与排序全为纯组合（rob_id 比较实现时零 structure 状态）。

---

## 例二：FIFO 型（ROB）

### ① per-entry state

`IDLE / WAIT / EXCEPTION / DONE`（概念全枚举）

压缩（概念状态必须，压缩是硬件优化）：
- IDLE ↔ 占用：压进 rd_ptr / wr_ptr / loopbit——entry idx 在区间内即 valid（解码投影）
- EXCEPTION：压成"最老异常一份"（bit + rob idx）——查询靠 rob_idx 比等；不想比等就 per-entry 存位，存储 vs 组合的取舍

### ② condition（event 名）

- IDLE → WAIT：allocate
- IDLE → EXCEPTION：front-end mark（随 allocate 进入，从未在纯 WAIT 呆过）
- WAIT → EXCEPTION：backend mark（随 done 写回）
- WAIT → DONE：done
- DONE → IDLE：commit
- ANY → IDLE：flush / partial flush（**指针回滚**：wr_ptr 拉回分支点，被杀 entry 经区间判定自动出局——零 per-entry 动作）

### ③ data path（边表）

- `disp → entry 阵列`：驱动 allocate；move；W slot 写口
- commit 侧多为送信（prd_old 给 free list、excp 信息给 trap），运值极少——FIFO 边表短是常态

### ④ condition 细化（valid ∧ ready）

- **allocate** ≡ disp 的分解——握手归 disp：disp valid ∧ 非满（保守判定：空闲 ≥ 单拍派遣宽度）
- **done** = 写回 event ∧ rob_idx 命中
- **commit** = **at-head（指针谓词）** ∧ done（EXCEPTION 则转 trap 流程）——per-entry 转移的 guard 引用 structure 指针，序约束进 guard 是 FIFO 型特征，CAM 型没有
- **partial flush** = wr_ptr 回滚至分支点；全 flush = 指针复位

### ⑤ data structure（schema + 字段三角色）

- state：DONE
- **header**：excp（commit guard 读）、prd_old（释放旧映射用）
- **payload**：PC 指针、指令信息——commit 才读

### ⑥ 接口

- **in-event**：
	- disp（Transaction，W slot；ready = 非满，无独立 ready 线）
	- writeback done（Broadcast，rob_idx 命中）
- **out-event**：
	- commit（Broadcast 送信：prd_old 给 free list / rename、excp 给 trap 流程）
	- flush（Broadcast；异常 / 中断在 commit 拍触发——**ROB 是 flush 的生产者**）
- **Static Info**：
	- be_idle（ROB 空；消费者 = Single Issue 机制）、非满（消费者 = D1 资源检查，即 disp 的 ready）

### 定性

指针（rd / wr / loopbit）是本体，per-entry valid = 解码投影；序约束把可达状态空间从 2^N 坍缩到 N²。

---

## 对偶收束

- 本体：per-entry state（CAM）↔ 指针（FIFO）
- 投影方向：聚合，多→一（CAM）↔ 解码，一→多（FIFO）
- 分配 / 释放：任选、乱序 ↔ 指针处、按序
- partial flush：谓词杀 ↔ 指针回滚
- 序约束：无 ↔ 全序；**序约束越强，状态越从 per-entry 向指针集中**

---

## 扩展：多写入（W slot）

> 检验：六步流程不改，只记每步增量。以 CAM（RS）为主场，FIFO（ROB）增量更少单列。

### ① per-entry state：零增量

per-entry FSM 对多写入免疫——per-entry 分解把 W slot 并发投影为每 entry 每拍 0/1 次 fire（由无冲突不变量兜底）。

### ② condition：event 升级为索引族

- FREE → WAIT：allocate[n]（任一 n 命中即转移；记法先例 wakeup_wb[k]）
- 转移行不随 W 膨胀；总名 allocate ≡ ∪ allocate[n]（组合方向的等价标注，纯别名不占定义席位）

### ③ data path：边族一行

- `disp[n] → entry 阵列`：驱动 allocate[n]；move；**slot 数 W**（n ∈ 0..W-1）
- 边族 ↔ event 族一一对应，每条边每拍 0/1 次 fire——"fire 一次 = 传一次"完好（命名消多重度）

### ④ condition 细化：判据模板 + 级联搜索器

- **allocate[n]** ≡ disp[n] 的分解——握手归 disp[n]：disp[n] valid ∧ ready[n]（模板一份，全族通用）
- **ready[n] ⇔#FREE ≥ n+1**（热温度计码，ready[n] ⇒ ready[n−1]）——#FREE 聚合投影的编码，纯状态函数，不看本拍 valid（无环义务）
- **级联搜索器**（纯组合，仲裁桶，age matrix 的写侧镜像）：输入 FREE 集，第 n+1 次 find-first-free（排除前 n 个命中）→ 输出 ready[n] + bind(n→i)，**两输出同源**
	- 义务：定义域 ⊆ FREE；同拍 idx 两两不同（级联结构 by construction）；搜索策略外部不可观测 → 实现自由
- per-entry 侧收束：allocate[i] = ∃n: allocate[n] ∧ bind(n→i)——OR 各项最多一真（无冲突保证）；entry 不知道命中自己的是哪个 slot，slot 身份只喂写数据 mux（数据通路 steering）
- **契约编码在谓词里**：per-slot fire（部分派遣）= 各 slot 引 ready[n]；组 fire（all-or-nothing）= 全组共用 ready[W−1]——保守判定"空闲 ≥ W"即其退化形（D1 现行）。跨 slot 场景合法性由谓词求值判定，无需散文条款：

| 场景 | 求值 | 判决 |
|---|---|---|
| valid={0,1}，#FREE≥2 | fire[0]=fire[1]=1 | 双双走 |
| valid={0,1}，#FREE=1 | fire[0]=1, fire[1]=0 | 部分 fire，slot 1 滞留重试 |
| valid={1}，#FREE≥2 | fire[1]=1 | 合法：独走，吃第二个空位 |
| valid={1}，#FREE=1 | fire[1]=0 | 合法但饿着（见 ⑥ 性能注） |

### ⑤ data structure：零增量

### ⑥ 接口

- disp 升级为 W slot Transaction（disp[n]，valid/ready 逐位）；**fire 判据即契约**——ready 引用哪位，就是哪种派遣语义
- 性能注：热温度计 ready 假设上游 valid 前缀压实（slot 0 最老、从低位连续填）；违反不产生非法状态，只损带宽
- idx 不出接口（唯一消费者 = 内部 demux steering，无外部谓词）
- 等价标注：allocate[n] ≡ disp[n] 的分解
- 父层账（不在本章）：原子分解跟谓词形状走——逐位合取 fire[n] = raw_valid[n] ∧ ∧ 各家 ready[n]

### FIFO 侧增量

- 绑定器退化为指针算术：bind(n) = wr_ptr + n，连续区间天然两两不同——无冲突 by 代数，零逻辑
- ready[n] = 空闲 ≥ n+1（同热温度计；保守判定 = 只看 ready[W−1]）
- structure FSM 指针步进吃多重度：wr_ptr += k（k = 本拍 fire 前缀长度）——**多重度唯一合法住所**：per-entry 侧被命名消掉，只在聚合侧显形

### 对偶补行

- 跨 entry 裁决器成对出现：写口分配器（级联 find-first-free）↔ 读口选择器（age matrix select）；FIFO 两端全退化为指针算术（连续区间 ↔ at-head）
- **序约束越强，分配/选择逻辑越向指针算术坍缩**——"状态向指针集中"的逻辑侧姊妹条
