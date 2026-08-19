# 异常与 trap 语义

**本文档只回答一件事：这台机器会产生哪些异常，每一条的 `cause` / `tval` 由谁产生。**

各模块内部怎么算、怎么传播、怎么恢复——**一律不在这里**，在各自的微架构文档与集成层。

**为什么需要一份共同宿主**：`cause` 的产生方散在 BRU / LSU / decode / CSR / FPU，
其中 BRU / LSU / FPU 都是**库外**、没有微架构文档；而 `CompletionScoreboard` 只捕获、
不生成，`flush_model` 只翻译、不生成。号段本身**不属于任何单一模块**，
和集成层 §2.2 的跨级 schema 是同一类无主定义。

将来 FU 微架构文档建起来后，每个 FU 只写"我产生哪几个 cause"，**全表仍留在本文档**。

---

## 1. 异常号段

```text
cause  名称                              产生方          tval
────────────────────────────────────────────────────────────────────────────
  0    instruction address misaligned    G0 · BRU        出错的目标 PC
  1    instruction access fault          G0 · FETCH_FAULT   pc（见下）
  2    illegal instruction               见 §2           指令编码，见 §3
  3    breakpoint                        G0 · SYS        0
  4    load address misaligned           G3 · LSU        出错地址
  5    load access fault                 G3 · LSU        出错地址
  6    store/AMO address misaligned      G3 · LSU        出错地址
  7    store/AMO access fault            G3 · LSU        出错地址（两个上报时机，见 §1.1）
 11    environment call from M-mode      G0 · SYS        0
```

**access fault（1 / 5 / 7）：通路是实的，检出待内存映射。** 这两件事必须分开看：

**检出**三条共用同一个空缺：要有内存映射才谈得上"哪段地址不可访问"，当前无映射故都不触发。
**通路**三条各自不同，且全部与检出无关、现在就必须实接：

```text
cause 1   FE 告知 decode，decode 产出 FETCH_FAULT 子码，之后走与 ILLEGAL 完全同形的路
          （G0、requester 0、无源操作数、不写 rd、不串行、lane 0 发 exception_flag）
cause 5   G3 · lane 3 的 exception_flag / cause / tval，与 cause 4 完全同形
cause 7   同上，另有 drain 拍一个上报时机——见 §1.1
```

**为什么通路不能等**：一条取指失败的指令仍然要占一个 tag，而 `exec_done` 只能由完成 lane 置位；
没有 FU 为它发 `Result_valid`，队头就永远等不到 `exec_done`——**是挂死不是陷入**。
这与"关掉的扩展必须走 `illegal` 而不是 `subop_supported_now`"是同一条道理。

**因此本表不写任何一条"恒 0 保留"。** 写了"恒 0"，下游就会按恒 0 去化简——
SCB 的判定链少一个分支、`flush_model` 的 kind 选择退化、`tval` 的多路选择被优化掉；
等映射到位时接上的**不是一根线，而是一次重新裁定**。**留空的是判据，不是路径。**

**`FETCH_FAULT` 与 `ILLEGAL` 唯二的不同**：cause 是 1 不是 2；`tval` 取 **`pc`** 不是 `inst_bits`
——取指都失败了，`inst_bits` 是垃圾，而 `pc` 一定有效。两者都由**子码硬编码**、不进 payload，
`IB_Payload` 因此一位都不加。

**未实现、留空的号**：`8 / 9`（U / S 态 environment call）要等 U 态落地；
`12 / 13 / 15`（page fault）要等 MMU。这两组和 access fault 不同——
它们缺的不只是判据，还缺特权态 / 地址翻译这些**结构**，通路无从谈起。

### 1.1 cause 7 有两个上报时机

store 的写在架构上分两段：执行拍进 store buffer、退休拍 drain 落内存。
访问权限故障**两段都可能检出**，走的路不同：

```text
时机          上报通路                              后端处置
─────────────────────────────────────────────────────────────────────
执行拍检出     lane 3 的 exception_flag/cause/tval    与 cause 6 完全同形：
              （普通完成路径）                        该 tag 走到队头 ⇒ EXCEPTION flush，
                                                    这条 store 永远不会 drain
drain 拍检出   store_done_exception / _cause / _tval  写进该 tag 的事件批，
              （drain 完成脉冲上的旁路字段）           下一拍由同一个 exception 分支处置
```

**drain 拍这条是 cause 7 独有的**——load 没有 drain 阶段，cause 5 只有执行拍一个时机。

**LSU 侧的硬性义务**：`store_done_exception = 1` 时**内存不得被修改**。
后端据此不置 `store_drain_done`，那条 store 因而不属于「不可作废」类别——
这个推论只有在"没写成"为真时才成立。判定链见
`module_spec_v2/CompletionScoreboard微架构文档.md` ③ 第四步。

**中断的 cause 不在本表**——它们不由 FU 产生，由
`system_instruction_handler` 的 `interrupt_cause = priority_encode(mie & mip)` 综合，
写进 `mcause` 时另置 bit 63。见该文档 ③。

---

## 2. `cause = 2` 的四个产生方

非法指令是唯一有多个产生方的 cause。四条来路**不共用一条完成路径**——它们分在
两个组、三条路上：

```text
来路                        落点                          判定时机
─────────────────────────────────────────────────────────────────────
decode 判定编码非法          G0 · ILLEGAL 子码 · requester 0   译码期判定，执行期完成
decode 判定扩展被关          同上（ENABLE_A/C = 0 ⇒ illegal = 1）  同上
csr_fu 判定 CSR 访问非法     G0 · CSR 子码 · requester 1       执行期判定
                            未实现地址、写只读地址、特权不足
                            以及 FS == Off 时访问 fcsr / fflags / frm
                            ⇒ 报异常**并且** we = 0
dispatch 判定 FP 指令非法    G0 · ILLEGAL 子码 · requester 0   **派遣期判定**
                            FS == Off，或 rm / frm 取保留值
```

**前两条与第四条走同一条 ILLEGAL 完成路径**（`cause` 由子码硬编码、`tval` 取 `inst_bits`）；
第三条同在 G0 但走 CSR 的 requester，`cause` 由 csr_fu 驱动。

**FP 的非法检查不在 FPU，在派遣侧**——这是设计决定不是遗漏。`mstatus.FS == Off` 与
`rm` 保留值都由 `dispatch_logic` 读架构状态合成 `fp_illegal`，命中即改道 G0。
**G2 因此永远不发异常，事件字段继续恒 0。** 判据与时序论证见
`module_spec_v2/checked_file/dispatch_logic微架构文档.md` ④#1，裁定见 `walkthrough.md` §1.22。

**csr_fu 那条必须真报异常**：只把 `csr_write_enable` 清零而不发 `exception_flag`，
会让这条非法 CSR 指令被当成一次普通完成、正常退休——软件看不到任何错误。

**被静态配置关掉的扩展必须走 `illegal = 1`**，不能用 `subop_supported_now = 0`——
后者的后果是该 slot 永不 `accept`、永远停在队头，是**挂死不是陷入**。
判据见 `module_spec_v2/checked_file/dispatch_logic微架构文档.md` ④。

---

## 3. `tval` 的口径

```text
不对齐类（0 / 4 / 6）      写出错地址
非法指令（2）              写指令编码：
                             普通 32 位指令   inst_bits(32)
                             压缩指令         {48'b0, inst_bits[15:0]}
无信息类（3 / 11）         写 0
```

**指令编码从哪来**：`inst_bits` 随 `IB_Payload` / `ISQ_Payload` 走到 G0，
FU 在**执行拍**取用、算完即弃，**不经过任何 per-tag 阵列**。
提交侧的 retire trace 是另一回事，两者不共用通路——见 `walkthrough.md` §2.3 ④。

---

## 4. 各组能产生哪些异常

```text
G0   0 / 1 / 2 / 3 / 11    BRU 报 0；FETCH_FAULT 报 1；ILLEGAL 与 csr_fu 报 2；SYS 报 3 与 11
G1   无                     ALU1 / MUL 都产生不了异常
G2   无                     **事件字段恒 0**。FP 的非法情形在派遣侧就改道 G0 了
G3   4 / 5 / 6 / 7          不对齐 4 / 6 在执行拍；access fault 5 / 7，
                            其中 7 另有 drain 拍时机（§1.1）
```

**G1 一条也产生不了**，这不是巧合而是约束的来源：任何可能陷入的指令都**不得**被分流到 G1。
现有两条据此成立——`AUIPC` 固定 G0（它另有 PC 依赖）、`SYS` 类固定 G0。
将来给 G1 加指令时必须重核这一条。

**`exception_flag = 1` 时，FU 必须同拍给出有效的 `tag_out` / `exception_cause` /
`exception_tval` 三样**。`CompletionScoreboard` 只按 tag 捕获进事件批，
在该 tag 走到队头时才产生 EXCEPTION flush——**异常在退休拍按序发生，不在执行拍发生**。

---

## 5. 不对齐访问：本实现选择陷入，不做硬件拆分

普通 load / store 遇到不对齐地址时**报异常（4 / 6），不由硬件拆成多次访问**。
RISC-V 两种做法都合法；选陷入是因为 LSU 简单得多，而代价是 M 态固件需要一个
不对齐访问的模拟 handler。

**原子指令没有这个选择**：LR / SC / AMO 的地址**必须自然对齐**（`.W` 4 字节、`.D` 8 字节），
不对齐一律陷入且**不得产生任何访存副作用**。注意两者 cause 不同——
`LR` 是读操作报 **4**，`SC` / `AMO` 报 **6**。

---

## 6. `ENABLE_*` 与 `misa` 的翻位前置条件

`misa` 报告的是构建配置**已经实现**的 ISA，不是开关也不是路线图。
以下任一条未闭合，对应位必须保持 0。

### `ENABLE_A` → `misa` bit 0

```text
库内   decode 产出 22 条原子子码，置 is_serial = 1、is_store = 0、use_rd = 1
库内   dispatch 的 ATOMIC 分类落 G3
库内   SCB 判定链第 4 步的「不可作废 head0」类别已含原子指令
库外   LSU 实现原子事务：exec_done 严格等于不可回滚点已完成
库外   LSU 实现 reservation（内部事务；flush 时清未被 SC 消费的）
库外   LSU 报 cause 4 / 6（不对齐）与 5 / 7（access fault）
```

### `ENABLE_C` → `misa` bit 2

```text
库内   decode 产出 52 条 SUBOP_C_*，置 is_compressed
库内   mepc 可写位放宽到 [63:1]（IALIGN = 16）
库外   FE 支持 16 位取指粒度，以及 pc[1] = 1 时跨 32 位 fetch word 拼接一条 32 位指令
库外   BRU 的指令地址对齐判据从 [1:0] == 00 放宽到 [0] == 0
```

### `ENABLE_FD` → `misa` bit 3（D）与 bit 5（F）

**这一条此前一直被当成"已实现"，但合规检查并没有闭合。** 五项：

```text
库内   decode 产出全部 F/D 子码与 FP load/store，置 is_fp_instruction
       （必须覆盖 G3 的 FLW/FLD/FSW/FSD，不能用 rd_is_fp 代替——FP store 不写 rd）
库内   dispatch 在最终 accept 前完成 FS/rm 的非法重路由（fp_illegal → G0 ILLEGAL）
库内   G0 的 ILLEGAL 路径持有 inst_bits，产出 cause = 2 与 tval
库内   csr_fu 覆盖 FS == Off 时对 fcsr / fflags / frm 三个地址的非法访问
库内   effective_rm 快照、fflags 累加、FS 脏判据、SD 派生的提交路径闭合
库外   FPU 实现 F/D 运算与 IEEE 标志，事件字段恒 0
```

**第二、四项是新增的**——在它们闭合前，一台声称支持 F/D 的机器会在
`mstatus.FS == Off` 或 `rm` 取保留值时**静默算错而不是陷入**，不合规。

### Zifencei（`FENCE.I`）—— `misa` 没有对应位，单独记

```text
库内   flush_model 的 FENCE_I 与 frontend_icache_invalidate
库内   recovery_kind 已加宽到 3 bit
库外   LSU 确认前序代码 store 已可见，再放 FENCE.I 完成
库外   FE 消费 frontend_icache_invalidate，清 fetch queue / 预取 / I-cache
```

### 同源要求

`ENABLE_A` / `ENABLE_C` / `ENABLE_FD` 是**同一组静态参数**，同时驱动 decode、
FE、LSU、FPU 与 `misa`。三处各自为政就会出现"`misa` 说有、硬件没有"或反之，
而 lockstep 的 ISS `--isa` 又是照 `misa` 配的——发散会出现在离病灶很远的地方。

```text
全部启用   misa = 64'h8000_0000_0000_112D   ISS --isa = rv64imafdc_zicsr_zifencei
仅 IMFD    misa = 64'h8000_0000_0000_1128   ISS --isa = rv64imfd_zicsr
```
