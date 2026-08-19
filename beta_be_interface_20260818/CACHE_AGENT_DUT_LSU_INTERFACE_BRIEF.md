# Cache Agent - DUT LSU 驱动与采样时序

本文只描述 LSU 接口的信号驱动、信号采样和时序规则，不展开验证环境实现细节。

## 1. 周期边界

一个 LSU 交互周期分为两个边沿：

1. **`clk` negedge：采样阶段。** 采样 DUT 发出的地址、store data、wakeup、flush，以及上一周期返回通道的 ready。
2. **随后 `clk` posedge：驱动阶段。** 根据采样结果驱动下一周期的 ready、forward、writeback、异常、完成和 reservation 信号。

驱动阶段的输出在整个下一个周期保持稳定；下一次 negedge 再采样输入和 ready，形成下一轮交互。

## 2. DUT -> Cache Agent 采样时序

| 信号 | 采样边沿 | 采样规则 |
| --- | --- | --- |
| `be_lsu_addr_valid[lane][dup]` | negedge | 为 1 时采样对应地址 payload；地址请求以 valid 为入口。重复 dup mirror 只保留一笔逻辑请求。|
| `be_lsu_addr_pld[lane][dup]` | negedge | 与地址 valid 同拍采样；其 ROB、操作类型、访问属性和目的寄存器在该周期内必须稳定。|
| `be_lsu_data_valid[lane][dup]` | negedge | 为 1 时采样 store data；未采到 data 的 store-side 请求不能执行写侧操作。|
| `be_lsu_data_pld[lane][dup]` | negedge | 与 data valid 同拍采样，并按 ROB index 与地址请求关联。|
| `rob_ls_wakeup_vld`、`rob_ls_wakeup_idx` | negedge | 采样 load/store 混合 wakeup；若对应请求尚未到达，wakeup 必须保留到地址请求到达。|
| `rob_st_wakeup_vld`、`rob_st_wakeup_idx` | negedge | 采样 store wakeup；规则与 `rob_ls_wakeup_*` 相同。|
| `lsu_int_reg_wr_ready` | negedge | 与上一个 posedge 呈现的整数 writeback 配对；ready=1 才完成该 writeback 握手。|
| `lsu_fp_reg_wr_ready` | negedge | 与上一个 posedge 呈现的 FP writeback 配对；ready=1 才完成该 writeback 握手。|
| `flush_all` | negedge | full flush 优先于普通 LSU 事务；采到 flush 后清除当前 LSU 未完成状态。|
| `pflush/pflush_rob_idx` | negedge | partial flush 删除指定 ROB 之后的 younger 状态；保留目标 ROB 及更老状态。|
| `rst_n` | negedge/posedge | 复位期间不采样有效事务，所有 LSU 返回保持无效。|

## 3. Cache Agent -> DUT 驱动时序

| 信号 | 驱动边沿 | 驱动规则 |
| --- | --- | --- |
| `be_lsu_addr_ready[lane]` | posedge | 复位期间驱动 0；复位解除后驱动 1 并保持。当前不动态产生 backpressure。|
| `lsu_int_fwd_valid`、`lsu_int_fwd_prd`、`lsu_int_fwd_data` | posedge | 整数 read-side 结果首次呈现时驱动一个周期；forward data/prd 与 valid 同拍有效，不等待 ready。|
| `lsu_int_reg_wr_valid`、`lsu_int_reg_wr_prd`、`lsu_int_reg_wr_data` | posedge | 整数 writeback 未握手时，每周期用相同 prd/data 重新呈现 valid；采到 ready 后停止呈现。|
| `lsu_fp_fwd_valid`、`lsu_fp_fwd_prd`、`lsu_fp_fwd_data` | posedge | FP read-side 结果首次呈现时驱动一个周期；规则与整数 forward 相同。|
| `lsu_fp_reg_wr_valid`、`lsu_fp_reg_wr_prd`、`lsu_fp_reg_wr_data` | posedge | FP writeback 未握手时重复呈现；ready 握手完成后停止。|
| `lsu_be_rob_done_vld`、`lsu_be_rob_done_idx` | posedge | 正常完成时驱动一个周期 pulse；同一完成 channel 每周期最多一笔。read-side 必须先完成 writeback。|
| `lsu_be_excp_valid`、`lsu_be_excp_idx`、`lsu_be_excp_payload` | posedge | 存在待发送异常时驱动一笔异常；无 ready，下一周期清零。|
| `lsu_reservation_clr` | posedge | 成功完成 reservation 相关写侧操作后驱动一个周期 pulse，随后清零。|
| `lsu_int_fwd_wakeup_valid`、`lsu_int_fwd_wakeup_prd`、`lsu_fp_fwd_wakeup_valid`、`lsu_fp_fwd_wakeup_prd` | posedge | 当前始终驱动 0。|
| `lsu_be_rob_replay_vld`、`lsu_be_rob_replay_idx` | posedge | 当前始终驱动 0。|

## 4. 事务时序规则

### 4.1 地址和数据

地址 valid/payload 在 negedge 被采样后，形成一个待处理请求。store、AMO、SC 还必须在后续 negedge
采到匹配的 data valid/payload；data 到达前不得执行写侧操作。

### 4.2 Store wakeup 和写侧完成

store-side 请求必须同时满足以下条件后才能完成写侧操作：

- 地址请求已经采样；
- store data 已经采样；
- `st_br_resolve` 或 ROB wakeup 已经采样；
- 更老的 store-side 请求已经完成。

写侧完成后，在后续 posedge 驱动 `lsu_be_rob_done_*`；reservation 相关请求另外产生一个
`lsu_reservation_clr` 单周期 pulse。

### 4.3 Read-side writeback

read-side 请求先在 posedge 驱动 forward 和 PRF writeback。forward 只在首次呈现时发送；PRF writeback
在 ready 未到达时按周期重复。下一 negedge 采到 ready 后，下一次 posedge 停止 writeback，并允许驱动
该请求的 `lsu_be_rob_done_*`。

### 4.4 Flush 优先级

full flush 和 partial flush 在 negedge 采样时优先于同周期普通地址、data、wakeup 事务。full flush
清除全部未完成状态；partial flush 只清除 younger 状态。flush 后的返回信号在下一个 posedge 重新按
清空后的状态驱动。

## 5. 完成 channel 的驱动时序

| channel | 完成类别 |
| --- | --- |
| 0/1 | 整数 load，地址 lane 0/1 |
| 2/3 | FP load，地址 lane 0/1 |
| 4/5 | 整数 store，地址 lane 0/1 |
| 6/7 | FP store，地址 lane 0/1 |
| 8 | LR、SC、NTL |
| 9 | AMO、fence、CMO |

每个 posedge 先清零全部 `lsu_be_rob_done_vld`，再为满足完成条件的 channel 置 1；因此 done valid
是单周期脉冲，不需要 ready。

## 6. 使用的 Payload 字段

以下只列出当前接口交互中实际使用的 payload 及字段；未列出的 payload/字段不参与当前时序。

### 6.1 `be_lsu_addr_pld` (`stgb_lsu_ls_t`)

| 字段 | 接口用途 |
| --- | --- |
| `rob_idx` | 关联地址、data、wakeup、flush、异常和完成信号的 ROB 标识。|
| `sub_op` | 确定 load/store、AMO、LR/SC、fence/CMO 等操作类别。|
| `sub_op_size` | 确定访问字节数；同时用于同一请求 mirror 的一致性检查。|
| `addr` | 地址翻译输入及异常地址信息。|
| `prd` | read-side 返回的目标物理寄存器；也用于 mirror 一致性检查。|
| `req_property.is_load` | 判定 read-side 请求。|
| `req_property.is_srq` | 判定是否进入通用 memory request 路径。|
| `req_property.is_store` | 判定 store-side，并区分普通 load/store。|
| `req_property.is_amo` | 判定 AMO 的读写双侧语义及完成类别。|
| `req_property.is_lr` | 判定 LR 语义及完成类别。|
| `req_property.is_sc` | 判定 SC 语义、写侧门控及完成类别。|
| `req_property.is_fp` | 选择整数或 FP 的 forward/writeback 通道。|
| `req_property.is_cmo` | 判定 CMO 请求。|
| `req_property.is_fence` | 判定 fence 请求。|
| `req_property.is_ntl` | 选择 NTL 完成类别。|
| `st_br_resolve` | store-side 的 wakeup/提交门控。|

### 6.2 `be_lsu_data_pld` (`stgb_lsu_st_t`)

| 字段 | 接口用途 |
| --- | --- |
| `rob_idx` | 将 store data 与地址请求关联。|
| `data` | store、AMO、SC 的写数据。|

### 6.3 `lsu_be_excp_payload` (`p600_exception_t`)

| 字段 | 接口用途 |
| --- | --- |
| `valid` | 与 `lsu_be_excp_valid` 同拍表示异常 payload 有效。|
| `cause` | 异常原因编码。|
| `tval` | 异常相关地址或翻译返回值。|
| `htval` | 当前异常接口字段，输出为 0。|
| `gva_set` | 当前异常接口字段，输出为 0。|















## 2. 时序


| 通道            | 握手                              |
|-----------------|----------------------------------|
| `be_lsu_issue`  | valid/ready。`lsu_be_issue_ready` 为组合电平,表示本拍能否锁进一条;每拍最多一条 |
| `lsu_be_wb`     | valid/ready。`lsu_be_wb_valid && be_lsu_wb_ready` 时完成一次交回;`be_lsu_wb_ready` 恒 1，握手每拍成立。相对 issue 握手至少寄存一拍 |
| `be_lsu_store_wakeup` | 一拍脉冲,无 ready,不重发   |
| `lsu_be_done` | 一拍脉冲,无 ready,不重发         |
| `lsu_be_store_done` | 一拍脉冲,无 ready,不重发   |
| `lsu_be_done_excp` | 一拍脉冲,无 ready,不重发      |
| `global_flush_late` | 一拍脉冲,直连                  |
---

### 2.1 在飞约束

LSU 内部读侧与写侧是两条通路:

```text
读侧   load / LR / SC / AMO（走 wb 通道）      最多 1 条在飞
写侧   普通 store（走 store_wakeup 通道）       在飞条数由 LSU 自行决定
       通路与读侧不同，两侧可同时在飞
```

由此:

```text
读侧反压   前一条读侧请求完成前，lsu_be_issue_ready 对新的读侧请求为 0
写侧反压   LSU 收不下更多 store 时拉低 lsu_be_issue_ready；BE 保持 payload，下一拍再试
返回顺序   读侧至多一条 ⇒ 天然按序
           写侧的 wakeup 只对退休队头逐条发出 ⇒ store_done 顺序即 wakeup 顺序
           两种情况都不产生乱序返回
每拍上限   最多一笔 wb、一个 done、一个 store_done、一个 done_excp
在飞 tag   互不相同
```

### 2.2 tag 生命周期

```text
一个 self_tag 从 issue 到完成只发一次完成脉冲
    lsu_be_done / lsu_be_store_done / lsu_be_done_excp 三者取其一
完成之后不再对该 tag 驱动任何信号
```

tag 会被后端回收给新指令。对已完成的旧 tag 补发脉冲，会被当成新指令完成。

---



### 7.5 普通 store — wakeup 之后出错

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid` | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `be_lsu_issue_pld` | 数据事件 | 1 | 1 |
| `be_lsu_store_wakeup` | 一拍脉冲 | 6 | - |
| `lsu_be_done_excp` | 一拍脉冲 | 8 | - |
| `lsu_be_done_excp_pld` | 数据事件 | 8 | 8 |

不出现:`lsu_be_store_done`。内存未被修改。

### 7.6 LR / SC / AMO — 正常

![7.6 非 store 指令](非store指令.svg)

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid` | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `be_lsu_issue_pld` | 数据事件 | 1 | 1 |
| `lsu_be_wb_valid` | 一拍脉冲 | 5 | - |
| `be_lsu_wb_ready` | 电平 | 5 | 5 |
| `lsu_be_wb_pld` | 数据事件 | 5 | 5 |
| `lsu_be_bypass_valid` | 一拍脉冲 | 5 | - |
| `lsu_be_bypass_pld` | 数据事件 | 5 | 5 |
| `lsu_be_done` | 一拍脉冲 | 5 | - |
| `lsu_be_done_tag` | 数据事件 | 5 | 5 |

不出现:`be_lsu_store_wakeup`。时序与指令无关，只有 `wb_pld.data` 不同:

```text
LR        load 值（.W 在 RV64 符号扩展）
SC 成功   0
SC 失败   1
AMO       更新前的旧值（.W 符号扩展）
```

### 7.7 LR / SC / AMO — 出错

形状同 §7.2 —— 原子指令 `is_store = 0`、不走 wakeup，**没有第二段**，因此
access fault 也只有执行拍一个时机。三类的差别只在 `done_excp_pld.cause`:

```text
LR         4（不对齐） / 5（access fault）    读操作
SC / AMO   6（不对齐） / 7（access fault）    写操作
```

不对齐时不产生任何读写、reservation 或原子副作用。

### 7.8 FENCE / FENCE.I — 正常

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid` | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `be_lsu_issue_pld` | 数据事件 | 1 | 1 |
| `lsu_be_done` | 一拍脉冲 | 9 | - |
| `lsu_be_done_tag` | 数据事件 | 9 | 9 |

不出现:`lsu_be_wb_valid`、`lsu_be_bypass_valid`、`be_lsu_store_wakeup`、`lsu_be_done_excp`

### 7.9 背靠背 load

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（tag A） | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `lsu_be_wb_valid` / `lsu_be_done`（tag A） | 一拍脉冲 | 3 | - |
| `be_lsu_issue_valid`（tag B） | 一拍脉冲 | 4 | - |
| `lsu_be_issue_ready` | 电平 | 4 | 4 |
| `lsu_be_wb_valid` / `lsu_be_done`（tag B） | 一拍脉冲 | 6 | - |

拍 2、3 的 `lsu_be_issue_ready` 为 0——读侧已有 tag A 在飞。
tag A 在拍 3 完成，ready 于拍 4 恢复，tag B 立即发出，中间没有空拍。

### 7.10 背靠背 store

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（store A） | 一拍脉冲 | 1 | - |
| `be_lsu_issue_valid`（store B） | 一拍脉冲 | 2 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 2 |
| `be_lsu_store_wakeup`（A） | 一拍脉冲 | 6 | - |
| `lsu_be_store_done`（A） | 一拍脉冲 | 8 | - |
| `be_lsu_store_wakeup`（B） | 一拍脉冲 | 9 | - |
| `lsu_be_store_done`（B） | 一拍脉冲 | 11 | - |

两条 store 连续发出，LSU 有容量就照收，不必等前一条落内存。

**wakeup 严格按序、一次一条**:B 的 wakeup 要等 A 的 `lsu_be_store_done`——
后端只对退休队头发 wakeup，A 落内存并提交之后 B 才成为队头。

若 LSU 收不下 store B，拉低 `lsu_be_issue_ready`，BE 保持 payload 下一拍再试（§7.14）。

### 7.11 load 与 store 同时在飞

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（store，tag S） | 一拍脉冲 | 1 | - |
| `be_lsu_issue_valid`（load，tag L） | 一拍脉冲 | 2 | - |
| `lsu_be_wb_valid` / `lsu_be_done`（tag L） | 一拍脉冲 | 4 | - |
| `be_lsu_store_wakeup`（tag S） | 一拍脉冲 | 7 | - |
| `lsu_be_store_done`（tag S） | 一拍脉冲 | 9 | - |

拍 2 的 `lsu_be_issue_ready` 仍为 1——tag S 占的是写侧通路，读侧是空的。
两侧各自推进，`lsu_be_done` 与 `lsu_be_store_done` 走不同的线，不会互相挤。

### 7.12 FP load / FP store

时序与 §7.1 / §7.3 完全相同，无独立通道。差别只在 payload:

```text
be_lsu_issue_pld.rd_is_fp = 1     LSU 据此对 lsu_be_wb_pld.data 做 FP 整形（NaN-boxing）
be_lsu_issue_pld.mem_funct3       给出 FP 访问宽度
```

FP store 与整数 store 一样走 §1.4 的两段式，占用同一条写侧通路。

### 7.13 Reset 释放

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `rst_n` | 电平 | 1 | 1 |
| `lsu_be_issue_ready` | 电平 | 2 | 2 |
| `be_lsu_issue_valid` | 一拍脉冲 | 2 | - |

复位期间 `lsu_be_issue_ready` 为 0、LSU 全部返回信号为 0。
拍 2 复位解除，ready 同拍为 1，BE 可在同一拍发出第一笔 issue。

### 7.14 issue 被反压

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid` | 保持至握手 | 1 | 3 |
| `be_lsu_issue_pld` | 数据事件 | 1 | 3 |
| `lsu_be_issue_ready` | 电平 | 3 | 3 |

拍 1、2 的 `lsu_be_issue_ready` 为 0，握手成立于拍 3。BE 在此期间保持同一笔 payload。

反压有两个来源:

```text
读侧   前一条读侧请求尚未完成
写侧   LSU 收不下更多 store
```

两者都由同一根 `lsu_be_issue_ready` 表示。BE 在此期间保持 valid 与 payload，逐拍重试。

### 7.15 Flush

`global_flush_late` 统一在拍 4 到达。六种情形分列如下。
类型 **不出现** 表示该信号自始至终不驱动。

#### 7.15.1 在飞的 load / LR / SC / AMO —— 丢弃

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（tag L） | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `global_flush_late` | 一拍脉冲 | 4 | - |
| `lsu_be_wb_valid`（tag L） | 不出现 | - | - |
| `lsu_be_bypass_valid`（tag L） | 不出现 | - | - |
| `lsu_be_done`（tag L） | 不出现 | - | - |
| `lsu_be_done_excp`（tag L） | 不出现 | - | - |
| `lsu_be_issue_ready` | 电平 | 5 | 5 |

tag L 本应在拍 5 前后回数据，被拍 4 的 flush 作废。读侧通路在拍 5 空出。

#### 7.15.2 在飞的 store，未收到 wakeup —— 丢弃

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（tag S） | 一拍脉冲 | 1 | - |
| `lsu_be_issue_ready` | 电平 | 1 | 1 |
| `global_flush_late` | 一拍脉冲 | 4 | - |
| `be_lsu_store_wakeup`（tag S） | 不出现 | - | - |
| `lsu_be_store_done`（tag S） | 不出现 | - | - |

内存未被修改。

#### 7.15.3 在飞的 store，已收到 wakeup —— 保留

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid`（tag S） | 一拍脉冲 | 1 | - |
| `be_lsu_store_wakeup`（tag S） | 一拍脉冲 | 3 | - |
| `global_flush_late` | 一拍脉冲 | 4 | - |
| `lsu_be_store_done`（tag S） | 一拍脉冲 | 6 | - |

wakeup 在 flush 之前到达 ⇒ 照常写内存、拍 6 回 `store_done`。
后端已把这条 store 算作提交，它的写不可回滚。

#### 7.15.4 flush 与 issue 握手同拍

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `be_lsu_issue_valid` | 一拍脉冲 | 4 | - |
| `be_lsu_issue_pld` | 数据事件 | 4 | 4 |
| `lsu_be_issue_ready` | 电平 | 4 | 4 |
| `global_flush_late` | 一拍脉冲 | 4 | - |

`lsu_be_issue_ready` 虽为 1，该笔 issue **不进入 LSU**，视为未发生。
BE 不会重发——那条指令已被 flush 作废。`be_lsu_store_wakeup` 同拍同理，不接收。

#### 7.15.5 flush 与返回信号同拍

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `lsu_be_wb_valid`（tag L） | 一拍脉冲 | 4 | - |
| `lsu_be_wb_pld`（tag L） | 数据事件 | 4 | 4 |
| `lsu_be_done`（tag L） | 一拍脉冲 | 4 | - |
| `global_flush_late` | 一拍脉冲 | 4 | - |

拍 4 已经呈现的返回**仍然有效**，后端照常接收——它落进的格子马上就要作废，无害。
`lsu_be_done_excp`、`lsu_be_store_done` 同拍同理。

**拍 5 起不得对被丢弃的 tag 驱动任何 valid**：tag 会被后端回收给新指令，
迟到的脉冲会打到复用后的那一条（§2.2）。

#### 7.15.6 flush 之后恢复

| 信号名 | 类型 | 起始拍 | 结束拍 |
| --- | --- | ---: | ---: |
| `global_flush_late` | 一拍脉冲 | 4 | - |
| `lsu_be_issue_ready` | 电平 | 5 | 5 |
| `be_lsu_issue_valid` | 一拍脉冲 | 5 | - |

被丢弃的条目在拍 4 就释放了通路，拍 5 即可接收新 issue，不需要额外恢复拍。
拍 4 时已收到 wakeup 的 store 按 §7.15.3 独立走完，不阻塞新 issue。

连续 flush 无额外语义——第一次已清空，后续 flush 只是重复同一动作。
