# Cache/LSU Agent - openrios BE 访存接口驱动与采样

本文只描述 **BE ↔ LSU 接口**（库内代号 `g3_lsu_iface`）的信号驱动、信号采样、
时序规则与各信号的目的，不展开 LSU 内部实现，也不展开后端模块内部逻辑。

**接口的目的**：把 G3 组发射出来的访存指令交给 LSU 执行；把执行结果、访存异常、
以及"写侧已经落内存"的完成通知送回后端；并让后端在退休点控制**什么时候真正改内存**。

**规模**：G3 组只有 **1 个 entry、1 个 FU**，所以后端一拍最多向 LSU 发 **1 条**访存指令。

---

## 1. 接口全貌

```text
BE  → LSU    issue（整条交付）                              访存指令交付
BE  → LSU    store_drain_req_valid / store_drain_tag        允许该 store 真正写内存
BE  → LSU    commit_valid[k] / commit_tag[k]                reservation 的提升依据
BE  → LSU    global_flush_late                              作废在飞投机工作

LSU → BE     FU_ready                                       唯一反压通路
LSU → BE     completion_common（lane 3）                     执行结果 + 访存异常
LSU → BE     store_done_valid / store_done_tag              写侧已完成
LSU → BE     store_done_exception / store_done_cause        保留，恒 0
```

后端**没有**别的信号送 LSU。特别注意：**后端不送 flush 掩码、不送 ROB 索引范围**——
LSU 该丢什么由它本地判定，判据见 §5.4。

---

## 2. 周期边界与采样口径

本规格**不规定时钟沿约定**（由 RTL 与验证环境商定），但**规定以下三件事**，
它们不可自由选择：

| 项 | 规定 |
| --- | --- |
| `store_drain_req` 的形态 | **1 拍脉冲，LSU 无条件收下，无 ready 回送**。后端不重发 |
| `store_done` 的形态 | 同上，反向。**1 拍脉冲，后端无条件收下** |
| `FU_ready` 的口径 | 组合电平，表示"本拍能不能收一条新的访存指令" |
| 完成相对发射的最小间隔 | **completion 相对 issue 至少寄存一拍**。不得在 issue 当拍就把完成打上来 |

**因为 `store_drain_req` 无握手，LSU 必须保证单拍脉冲一定被接受。**
这是**规格定死的默认形态**，不是可选项。

若 LSU 实现上确实做不到（例如内部队列可能满），**那是一次接口变更、不是实现方可以自行决定的事**：
该信号要改成 valid/ready 事务，且后端要改成"只在握手成功后才置内部的已请求位"——
**两侧同时改**。发现这种情况请回头提，不要单方面在 LSU 侧加缓冲硬扛。

---

## 3. BE → LSU 驱动规则

| 信号 | 位宽 | 目的 | 驱动规则 |
| --- | --- | --- | --- |
| issue（整条） | 见 §7.1 | 交付一条访存指令 | 判据是"操作数齐 ∧ `FU_ready` ∧ 非 flush 拍"。同拍至多一条 |
| `store_drain_req_valid` | 1 | **允许写内存**。收到之前 LSU 不得改内存 | 1 拍脉冲。每拍至多一条，且**只对退休队头那条发** |
| `store_drain_tag` | 4 | 允许写的是哪条 | 与 valid 同拍 |
| `commit_valid[k]` | 1×2 | 该 lane 本拍有指令退休 | broadcast，2 lane |
| `commit_tag[k]` | 4×2 | 退休的是哪条 | 与 valid 同拍。**LSU 只用它做 reservation 提升**，不做别的 |
| `global_flush_late` | 1 | 作废全部在飞投机工作 | 单线脉冲，**直达 LSU，不经任何仲裁器** |

**`store_drain_req` 是这个接口的核心。** 它把"指令完成"和"内存被改"**分成两件事**：
store 可以早早执行完（算出地址与数据）、进入 LSU 的缓冲，但**必须等到它走到退休队头、
后端确认它前面再没有会出错的指令，才允许它真正改内存**。这是精确异常的前提。

---

## 4. LSU → BE 采样规则

| 信号 | 位宽 | 目的 | 采样/处理规则 |
| --- | --- | --- | --- |
| `FU_ready` | 1 | 反压 | **LSU 的一切内部反压都必须折进这一位**：地址队列、store buffer 余量、执行段占用。后端不设第二条反压通路 |
| `Result_valid` | 1 | 本拍 lane 3 有一笔完成 | 完成通知，无 ready，后端无条件收下 |
| `tag_out` | 4 | 完成的是哪条 | 与 `Result_valid` 同拍 |
| `result_data` | 64 | 回写值 | 符号扩展与 NaN-boxing **由 LSU 完成**，后端不再整形 |
| `exception_flag` | 1 | 这笔完成带异常 | 为 1 时 `result_data` 无意义 |
| `exception_cause` | 63 | 异常号 | 见 §6 |
| `exception_tval` | 64 | 出错地址 | 见 §6 |
| `store_done_valid` | 1 | 写侧已完成 | 1 拍脉冲 |
| `store_done_tag` | 4 | 完成的是哪条 | 与 valid 同拍 |
| `store_done_exception` / `store_done_cause` | 1 / 63 | **保留未实现，恒 0** | 当前口径下 drain 之后不再产生访存故障 |

**lane 3 的四个字段恒为 0**：`mispredict_flag`、`mispredict_target_pc`、`is_mret`、`fpu_fflags`。
恒零字段**由 LSU 自己驱动**，后端不代为置 0——因为 lane 3 是直连，中间没有仲裁器可以代劳。

---

## 5. 事务时序规则

### 5.1 普通 load

`issue` → LSU 算地址、取数 → 驱动 lane 3 完成（`result_data` = 取回的值）。
**没有 drain 环节**，load 不改内存。

**LSU 必须做 store-to-load forwarding。** 这是正确性要求，不是优化：
更早的 store 可能已经执行完但**还没收到 `store_drain_req`**，
它的数据还在 LSU 缓冲里、内存里是旧值。此时一条同地址的 load 若直接读内存，
读到的就是**过期数据**。后端不提供任何绕过这件事的机制——
两段式 store 的代价就是 LSU 必须自己消解这个冒险。

> **不要被 §5.3 反读**：那里说"原子指令**不**需要 forwarding"，是因为它们发射时
> 退休窗口已空、更早的 store 必然已落内存。**普通 load 没有这个前提，必须 forward。**

**FP 访存的一个负担 LSU 不用背**：`mstatus.FS == Off` 时的 FP load/store
**根本到不了 G3**——后端在派遣侧就判非法并改道了。LSU 侧**不需要任何 FS 检查**。
（此处与旧版参照实现不同：旧 RTL 在 G3 的发射点做过这个检查，实现时不要照抄。）

### 5.2 普通 store —— 两段式

```text
第一段   issue → LSU 算地址、收下数据 → 驱动 lane 3 完成
         此时**内存还没变**，数据在 LSU 缓冲里
第二段   后端确认它已走到退休队头 → 发 store_drain_req
         → LSU 真正写内存 → 回 store_done
         后端收到 store_done 之后，这条 store 才能退休
```

**顺序义务**：更老的写侧请求必须先完成。后端**只对退休队头那条发 drain**，
所以 LSU 侧不会收到乱序的 drain 请求。

### 5.3 原子指令（LR / SC / 9 种 AMO）—— **不走 drain**

这是与普通 store **最容易搞混**的一点：

```text
is_store = 0        原子指令不走 store_drain_req / store_done
exec_done 时点      = 不可回滚的原子事务**已经完成**
```

具体到每一类：

| 指令 | 完成时点的严格含义 | `result_data` |
| --- | --- | --- |
| `LR` | 已取到值，且已建立**带 tag 的 pending reservation** | load 值；`.W` 在 RV64 **必须符号扩展** |
| `SC` 成功 | reservation 检查通过、条件写**已在原子点完成** | `0` |
| `SC` 失败 | reservation 检查完成、**未发生任何写入** | `1` |
| `AMO` | 旧值读取、运算、写回三件事在**同一原子事务内**完成 | **更新前的旧值**；`.W` 必须符号扩展 |

**为什么原子指令可以在执行拍就改内存**：后端保证它们**发射时退休窗口是空的**。
所以没有更早的分支或异常能作废它，更早的 store 也必然已经 `store_done`、已落内存——
**LSU 因此不需要为原子指令做 store-buffer forwarding**。

**AMO 与成功的 SC 之后不存在第二次 `store_done`。**

### 5.4 flush 时 LSU 该丢什么

```text
已收到 store_drain_req 的条目   ⇒ 它已经提交，**保留**，继续完成
未收到 drain_req 的条目          ⇒ 一定还是投机的，**全丢**
flush 同拍                       ⇒ 不得新接受 store_drain_req
flush 之后                       ⇒ **不得再对被作废的 tag 驱动 Result_valid**
```

**最后一条是硬约束，而且是后端某个设计的承重前提。** 后端存放结果的 RAM
**有意不挂 flush 门**——flush 拍写进去的值落在随即失效的格子里，无害；
该格被重新分配后，新指令的写回必先于它的提交发生。
**这整套安全性建立在"FU 不会在 flush 之后对旧 tag 再发完成"上。**
LSU 是直连 lane 3、没有仲裁器代为拦截的，这条义务只能由 LSU 自己履行。

**后端不送掩码，因为不需要。** 依据：drain 只对退休队头发、按序、一次一条，
而后端的退休判定链把 store drain 排在中断之前——队头卡在 drain 流程时**不产生任何 flush**。
所以"未收到 drain_req ⇒ 必投机"没有反例，LSU 每条缓冲条目一位本地 `draining` 就够。

**原子指令不适用这套**：它们不进 store 缓冲。"已完成的原子指令不被作废"
由后端的退休判定链保证，不归 LSU。

### 5.5 reservation 的三条规则

```text
建立   LR 完成时只建立 pending{valid, tag, addr}，此时**还不是**有效 reservation
提升   commit_valid[k] ∧ commit_tag[k] == pending.tag  ⇒  提升为有效
作废   pending 被作废时丢弃
       **已提升的 reservation 不得被更年轻指令的 flush 清除**
```

**第三条是硬约束**：清了会让受约束的 LR/SC 循环因为更年轻指令的分支误预测而
**永远失败（livelock）**。这也是 `commit_valid[k]` / `commit_tag[k]` 要送 LSU 的
唯一理由——**不能用"退休了几条"这类无 tag 的信号代替**，它认不出是哪条。

当前原子指令在退休窗口空时才发射，窗口里只可能有那一条 LR，所以
"`global_flush_late` 清未提交的 pending"是安全的。
**将来放开这条限制时，必须换成显式的按 tag 作废接口。**

### 5.6 `FENCE` / `FENCE.I`

后端保证它们发射时**更早的访存已全部退休**，所以 LSU 侧的屏障退化成
"**排空自己的 store buffer**"。

`FENCE.I` 另须确认**前序代码 store 已对取指可见**，再放它完成；
取指侧的重新取指由后端在退休点发起，不归 LSU。

---

## 6. 异常

LSU 是以下两个异常号的**唯一产生方**，通过 lane 3 的 `exception_flag` / `cause` / `tval` 上报：

| cause | 名称 | 触发 | `tval` |
| --- | --- | --- | --- |
| 4 | load address misaligned | 普通 load **或 `LR`** 地址不对齐 | 出错地址 |
| 6 | store/AMO address misaligned | 普通 store、`SC`、`AMO` 地址不对齐 | 出错地址 |

**注意 `LR` 报 4 不是 6**——它是读操作。

**对齐要求**：普通 load/store 不对齐**报异常，不做硬件拆分**；
`LR` / `SC` / `AMO` 的地址**必须自然对齐**（`.W` 4 字节、`.D` 8 字节），
不对齐一律陷入且**不得产生任何访存副作用**。

**异常在退休拍按序发生**，LSU 只负责如实上报，不产生任何架构效应。
`exception_flag = 1` 时必须**同拍**给出有效的 `tag_out` / `cause` / `tval`。

`5` / `7`（access fault）当前未实现——要有内存映射才谈得上"哪段地址不可访问"。
届时走同一条通路，只加号不加路。

---

## 7. Payload 字段

### 7.1 issue（BE → LSU）

| 字段 | 宽度 | 接口用途 |
| --- | --- | --- |
| `self_tag` | 4 | 关联 issue、drain、done、异常、完成的唯一标识 |
| `exe_subop` | 24 | **操作类别的唯一来源**，见 §7.2 |
| `rs1_data` | 64 | 基址（普通访存）/ 地址（原子指令） |
| `rs2_data` | 64 | store 数据 / AMO 操作数 / SC 写数据 |
| `imm_valid` | 1 | 是否有偏移 |
| `imm_data` | 64 | 访存偏移。**原子指令恒 0**（它们没有 offset） |
| `is_store` | 1 | **专指"走 drain 子流程的普通缓冲 store"**，见 §7.2 |
| `mem_funct3` | 3 | 访存类型：宽度 + 符号扩展 + FP 三件事。原子指令只用其中的宽度部分 |
| `rd_is_fp` | 1 | 区分同宽度的整数与 FP load（`LW` 与 FP load 取值相同、双字同理），二者只差结果整形 |
| `full_decode` | 17 | 本组一位也不消费，非适用字段置零忽略 |

**`rd_idx` 不在接口里**：回写按 `tag_out` 寻址，目的寄存器信息在分配拍已进后端，
LSU 不需要知道写哪个寄存器。

**`store_mask` 不在接口里**：LSU 按 `(有效地址, mem_funct3)` 自己算。
前提是不对齐先报异常、不做跨 beat 写——本实现正是如此。

### 7.2 操作类别的判定

**必须由 `exe_subop` 分类，不能用 `!is_store` 推 load**：

```text
mem_class = decode(exe_subop) ∈ { LOAD, STORE, LR, SC, AMO, FENCE, FENCE_I }
```

`is_store` 只区分"走不走 drain 子流程"，**不是**"是不是访存写"。
**AMO / SC / FENCE 三类都 `is_store = 0`，但都不是 load** ——
用 `!is_store` 推会把它们全推成 load。

### 7.3 lane 3 完成（LSU → BE）

四条完成 lane 共用一份 schema，lane 3 的取值约定：

| 字段 | 宽度 | lane 3 的驱动 |
| --- | --- | --- |
| `Result_valid` | 1 | 本拍有完成 |
| `tag_out` | 4 | 哪一条 |
| `result_data` | 64 | 结果值，已完成符号扩展 / NaN-boxing |
| `exception_flag` | 1 | 见 §6 |
| `exception_cause` | 63 | 见 §6，不含中断标志位 |
| `exception_tval` | 64 | 见 §6 |
| `mispredict_flag` | 1 | **恒 0** |
| `mispredict_target_pc` | 64 | **恒 0** |
| `is_mret` | 1 | **恒 0** |
| `fpu_fflags` | 5 | **恒 0** |

### 7.4 bypass 广播

lane 3 的完成同时驱动一组 bypass 广播，供后端唤醒等待该结果的指令：

```text
bypass_valid = Result_valid ∧ !exception_flag
bypass_tag   = tag_out
bypass_data  = result_data
```

**`!exception_flag` 这道门不可省**：出错的 load / LR / SC / AMO 都是要写目的寄存器的，
确实有指令在等它的 tag；不门掉就会捕获垃圾数据并把自己标成就绪。

**bypass 是一次性广播，没有重播。** 后端有独立机制处理"错过唤醒窗口"的情况，
LSU 不需要为此做任何事。

---

## 8. LSU 侧义务清单

供实现方自查，逐条都在上文有出处：

```text
①  一切内部反压折进 FU_ready，不设第二条通路                       §4
②  completion 相对 issue 至少寄存一拍                              §2
③  普通 load 必须做 store-to-load forwarding                       §5.1
④  store 收到 drain_req 之前不得改内存                             §5.2
⑤  更老的写侧请求先完成                                            §5.2
⑥  原子指令的完成 = 不可回滚事务已完成                             §5.3
⑦  .W 的 LR/AMO 返回值在 RV64 必须符号扩展                         §5.3
⑧  flush 时保留已 drain_req 的、丢弃其余                           §5.4
⑨  **flush 之后不得再对被作废的 tag 驱动 Result_valid**            §5.4
⑩  reservation 的 pending → 按 commit_tag 提升                     §5.5
⑪  已提升的 reservation 不得被更年轻的 flush 清除                  §5.5
⑫  不对齐一律陷入，且不得产生任何访存副作用                        §6
⑬  LR 报 cause 4、SC/AMO 报 cause 6                                §6
⑭  操作类别由 exe_subop 分类，不用 !is_store 推                    §7.2
⑮  恒零字段自己驱动，lane 3 直连无仲裁器代劳                       §4
⑯  bypass 带 !exception_flag 门                                    §7.4
⑰  **不做** FS==Off 检查——那种 FP 访存到不了 G3                    §5.1
```

**其中 ③ 和 ⑨ 是"不做就出错、而且错得不明显"的两条**，优先核：
③ 漏了会读到过期数据（且只在特定 store→load 距离下才现形）；
⑨ 漏了会污染后端的结果 RAM（而那块 RAM 有意不挂 flush 门，全靠这条撑着）。

**⑭ `rd = x0` 只抑制后端的寄存器写口，不抑制访存副作用**——
`amoadd.d x0, x3, (a0)` 仍然要改内存。这一条不在 LSU 的判断范围内，
列出只为防止误读：LSU 照常执行，是后端决定不写寄存器。
