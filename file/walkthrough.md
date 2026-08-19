# Walkthrough · 裁定留痕与待落地内容

两个用途:**一**记录关键裁定的来由(不只是结果,还有为什么这么定);
**二**暂存那些已从模块文档移出、但宿主文档尚未建立的内容,防止丢失。

---

## 一、裁定记录

### 1. 模块文档只描述本模块自己

模块文档不写"别人拿这个字段去干什么",跨模块的用途与正确性论证归集成层。
**为什么**:模块文档要自足可读,混入下游用途会让改动波及面失控。

### 2. 跨文档重复陈述是刻意的,不算冗余

同一契约在多份文档各写一遍(如 `recovery_kind` 编码在 SCB 与 flush_model 各有一份)是有意为之。
**为什么**:每份文档必须能独立读懂,不靠指向别处的指针。

### 3. ① per-entry state 只放生命周期状态机

寄存器/字段清单归 ⑤,条件公式归 ③,端口清单归 ⑥,路线图与待补项都不占 ① / ②。
**为什么**:有存储 ≠ 有状态。`Buffer` / `PC_File` / `INT_ARF` / `FP_ARF` 都有存储,
① 一律写「无」;`system_instruction_handler` 的架构寄存器组同理——它的 ② 自己就写着
「架构组无阶段转移」,那三张寄存器清单占 ① 是放错节。

### 4. FU 自身的行为契约不归任何库内模块

flush 拍作废在飞工作、此后不得对旧 tag 再发 `Result_valid`、completion request 相对 issue
至少寄存一拍、各 FU 的 `FU_ready` 语义、csr_fu 的执行侧行为——全部归 **FU 微架构文档(待建)**。
**为什么**:仲裁器只做组内仲裁与转发,不该规定 FU 内部时序;而 G2/G3 直连 lane 2/3、
根本不经过仲裁器,让 G0 的仲裁器文档去管 FPU/LSU 的行为,管辖范围对不上。
按同一条规矩,`csr_fu` 也是 FU,其行为契约一并移出(2026-08-17 裁定)。

### 5. `completion` 分两层

`completion_common` 四条 lane 共用;`csr_sideband` 只在 lane 0 存在。
恒零字段**一律由 lane 驱动方(FU)自己驱动**,仲裁器不补造。
**为什么**:G2/G3 直连、没有仲裁器可以代为置 0,恒零只能落在 FU 侧;
统一到 FU 侧,四条 lane 的输入契约才是同一份。

### 6. 非法指令必须有完成路径

曾缓行的五条系统指令当时走 **ILLEGAL** 子码(固定 G0、与 ALU0/BRU 共用 requester 0),
由 lane 0 发异常 completion,不能只在译码期 trap。
**为什么**:指令一旦被接受就占住一个 tag,而 `exec_done` 只能由完成 lane 置位;
没有 FU 为它发 `Result_valid`,队头就永远等不到 `exec_done` 而死锁。

### 7. `misa` 反映当前实际,不是路线图 —— 后改为由 `ENABLE_*` 打包

原裁定:值为 RV64 **IMFD**(不含 A/C)。
**为什么**:它须与 lockstep 用的 ISS `--isa` 一致;写成 IMAFDC 会让对拍从第一条指令就错。

**IMAFDC 补全后的修订**:原则不变,实现方式改了。`misa` **不再是写死的常量**,
而是由静态配置 `ENABLE_A` / `ENABLE_C` / `ENABLE_FD` 打包出来的只读值;
同一组参数还驱动 decode、FE、LSU、FPU。**某扩展的库外契约未闭合时对应位必须为 0**,
所以"反映当前实际"这条原则反而被强化了——它现在是结构性保证,不是靠人记得改。
全启用 `64'h8000_0000_0000_112D`,仅 IMFD `…1128`。翻位前置条件见 `异常与trap语义.md` §6。

### 8. `FU_Group` 由 dispatch 导出,不经 IB

Decode→IB 不携带 `FU_Group`;dispatch 从 `exe_subop` 推出 `slot_FU_Group[0/1]` 交装配逻辑。
**为什么**:`FU_Group` 是 `exe_subop` 的纯函数,再走一遍 payload 是冗余。

### 9. `Buffer` 不接 `global_flush_late`

全库唯一有意不挂 flush 门的模块。
**为什么安全**:flush 拍写进去的 `result_data` 落在随即失效的格里,不改变任何架构状态;
该格被重新分配后,新指令的 writeback 必先于它的提交发生——提交要求 `exec_done`,
而 `exec_done` 与 Buffer 写来自**同一次 writeback**,故读出值恒与被提交的那条指令对应。
**前提**:FU 的 flush 契约成立(此后不得对旧 tag 再发 `Result_valid`),含直连 lane 2/3 的 FPU 与 LSU。

### 10. `FE` 不收 `global_flush_late`,只收 `redirect_*`

**为什么**:FE 不是投机状态的持有者,它要的是"从哪重新取指",不是"清掉什么"。
五种 `recovery_kind` 都产生 redirect,`redirect_pc` 的来源各不相同
(MISPREDICT→SCB 表项的 `mispredict_target_pc`;MRET→`mepc`;EXCEPTION/INTERRUPT→`trap_vector`)。
接线时容易误把 FE 并进 `global_flush_late` 的扇出名单,那是错的。

### 11. `serial_set` 拆成两条边而非一条直连

tag 的**计算**归 `dependency_check`(它拥有 `Buffer_tail` → `self_tag[s]` 的推导);
**触发**归 `dispatch_logic`(只有它知道 slot0 本拍是否真被 accept)。
故 tag 经 `dispatch_logic` 转发,与触发同端口同拍送达 `SerialInstructionTracker`。
**为什么不直连**:一个 Transaction 的 move 载荷与 trigger 应同源同拍;
让 `dispatch_logic` 重算 tag 会与 SCB 的 `tail` 时序脱节。

### 12. 采样口径跨模块相反,不可类推

```text
CompletionScoreboard.can_alloc_1 / can_alloc_2 / buffer_empty    拍初值
ISQ_Group_g.isq_free_for_dispatch                                含同拍 issue
IB 内部的 free_slot                                              含同拍 dequeue（见 §1.29）
```

**为什么要单独记**:单看任何一份模块文档都不会发现"它们是反的"——这是跨模块才成立的陷阱。
`isq_free_for_dispatch` 含同拍 `issue` 的代价是把 `FU_ready` 拉进了 P1 准入的同拍组合路径。

### 13. 三条边**故意不建**——建了就成组合环

```text
dependency_check 的同拍 RAW 命中若改用 accept[0]（而非 slot0_present）
    → 新增 dispatch_logic → dependency_check，与已有反向边成环

FP_read_address_mux 的选通位若改用 accept[0/1]（而非 is_fp_instruction[0]）
    → 新增 dispatch_logic → FP_read_address_mux，
      与 FP_read_address_mux → FP_tag_mapping → dependency_check → dispatch_logic 成环

dependency_check 若代 FP_read_address_mux 转发 is_fp_instruction[0]（而非 IB 直送）
    → 形成 dependency_check → FP_read_address_mux → FP_tag_mapping → dependency_check
      的模块级环（信号级无环，但环路分析要下沉到信号级才能证伪，不值当）
```

**为什么要记**:这三条在集成层的边表里表现为"不存在",而不存在的东西没法从表上看出是有意的。
后来者很可能"顺手"把它们连上。

### 14. flush 侧的跨模块约束

`flush_valid` / `flush_tag` / `recovery_kind` 三元组由 SCB 判定链产生,`flush_model` **只翻译与广播、
不重新判定**。`commit_count` **不经 `flush_model`**;`flush_model` 不得转发它、也不得另造任何
落位目标值。`flush_tag` 送到 `flush_model` 后只用来读恢复上下文,**绝不参与指针计算**。
**为什么**:判据就是 head0 优先级链,让 `flush_model` 再推一遍等于把整条链实现两份,
两份一旦漂移就是不可调的 bug。

### 15. `AUIPC` 固定 G0，ALU 不是整类可分流

**为什么**:AUIPC 要算 `pc + imm`,而 `ISQ_Group1` 的"本组不存的字段"明确丢弃 `pc`。
划分依据直接引用包里已有的两个集合——`exe_subop_pkg.sv` 的 `is_g0_alu0_subop`
含 `SUBOP_AUIPC`、`is_g1_alu1_subop` 不含,文档不另立名单。`LUI` 两集合都在,属可分流。
**曾考虑的备选**:译码期折叠成 `imm_data = pc + imm`,让 AUIPC 退化为取立即数、G0/G1 都能跑。
否掉的理由——包里已按 G0-only 实现,改折叠要动 decode 且 `imm_data` 得改名
`precomputed_alu_operand`(不能含混叫立即数);保留 G0-only 是更小、更可验证的改动。

### 16. C 扩展:保留子码、门控关闭(A 方案 2) —— 后被 §1.21 推翻

原裁定:保留编码,在 `subop_supported_now` 里与 AMO / FENCE 并列门掉。

**IMAFDC 补全时发现这个门控方式是错的**,见 §1.21。门控本身保留(改由 `ENABLE_C` 驱动),
但**位置从 `subop_supported_now` 移到 decode 的 `illegal`**。

### 17. `mip` 在 M-only 下全只读

无存储,是三根顶层电平(`MEIP`/`MTIP`/`MSIP` → `mip[11]/[7]/[3]`)的组合视图,
`csrw mip` 静默忽略。**为什么**:RISC-V 里 `mip` 可软件写的只有 S 态那几位,本实现无 S 态。
**两条容易漏的契约**:①顶层电平必须已跨时钟域同步,短脉冲须在上游锁存成 pending level,
否则漏中断;②`interrupt_cause` 必须在 SCB 选中中断的那一拍锁存进 flush/trap event,
**不得等到 `trap_entry` 拍再重新组合 `mie & mip`**——两拍之间电平可能已变,重组会取错 cause。

### 18. CSR 写是掩码落笔,不是整字覆盖

原 `apply` 写作 `CSR[addr] ← wdata`,后果是 `csrw mstatus` 能改 `MPP`,
与"`current_priv` 恒 M"及 `mret_update: current_priv ← mstatus.MPP` 互相推翻。
**裁定**:逐寄存器按可写位掩码(表在 SIH ③)。其中 `mstatus.SD` **不是存储位**,
是 `(FS == Dirty)` 的派生只读投影——原文档写成粘性累加 `SD ← SD ∨ fp_dirty` 是错的。
`mepc[1:0]` 当前恒 0(IALIGN=32),启用 C 后放宽为 `[0]` 恒 0
(补全后已改成随 `ENABLE_C` 变的两档,见 SIH ③)。

---

### 19. A 扩展靠**串行化**取得非投机性,不是靠新增通路

**问题**:AMO 在执行拍写内存 = 投机写。更早的分支误预测或异常作废了它,内存已经改了。
这台机器里只有一个办法让执行拍就非投机。

**裁定**:LR / SC / AMO 全部 `is_serial = 1`,并且 `is_store = 0`、**不走 store drain**。
`exec_done` 严格等于"不可回滚的原子事务已完成"。

**推论链**(这才是价值所在,不只是结论):

```text
is_serial ⇒ serial0_ok = buffer_empty ⇒ 发射时窗口空 ⇒
    ① 没有更早的分支 / 异常 ⇒ 写内存非投机
    ② 更早的 store 全部已 store_done ⇒ 已落内存
       ⇒ LSU 不需要为原子指令做 store-buffer forwarding
    ③ 窗口里只有它一条 ⇒ 「global_flush_late 清 reservation」是安全的（见 §1.31）
```

**代价**:AMO 排空流水线。可接受——AMO 本来就要走到内存、频率极低。

**放弃的两条备选**:
- 走 store drain 通路:旧值要随 `store_done` 回来,Buffer 得加第 5 个写口
  或让 SCB 容忍二次 `Result_valid`。明显更贵
- 执行拍读、drain 拍写:需要 LSU 为原子指令做 forwarding,复杂度进了最容易出 bug 的地方

**将来放开串行限制时必须一并改的**:③ 那条不再成立——见 §1.31 末段。

**`aq`/`rl` 一并定死**:全部按 1 实现(全 acquire+release),编码位不译码、不进 payload。
比 ISA 要求更强,合法;反正已在退休点串行化,逐指令放松也拿不到好处。
`full_decode` 因此不为 aq/rl 加位。**这是决策不是遗漏**。

### 20. 中断可以被推迟,但不可以作废已产生副作用的队头

**问题**(与助理辩论三轮后由具体轨迹定案):SCB 判定链第 4 步原本写
「非 store 的 head0 → 提交 0,flush_tag = head0」。串行 AMO 不是 store,
于是一条**已经改过内存**的 AMO 会被中断作废,handler 返回后重执行 ⇒ 内存改两次。

**裁定**:第 4 步的受保护类别从"已 drain 的 store"推广成
**"head0 已产生不可回滚的存储器副作用"**,含已 drain 的 store 与已 `exec_done` 的
LR/SC/AMO。处置与原 store 子句完全相同。

`LR` 本身没有内存写,纳入这一类只为让"原子指令"是一个整体、少一个例外;
过度保护的唯一后果是把中断推迟一拍。

**没做的更彻底方案**:助理提议让 SCB 直接输出 `trap_epc`(分三种情形算下一条架构可执行 PC),
好处是中断永远即刻可取、也顺带修掉"已 drain store 且无 head1 时中断要多等几拍"。
**否掉的理由**:`commit_count = 1 且无 head1` 那一档要算 `head0.pc + instr_len`,
需要 per-tag 存 `instr_len`(16 bit 新存储 + 新 out-event + flush_model 重做)。
而中断**没有任何时序义务**,推迟永远合法。等真测出中断延迟是问题再说。

### 21. 关掉的扩展必须走 `illegal`,不能走 `subop_supported_now`

**问题**:§1.16 原本把 A / C 门在 `subop_supported_now = 0` 上。但那一位的后果是
**"不得 `accept`"**——该 slot 会永远停在队头等下去。**这是挂死,不是陷入。**

**裁定**:`ENABLE_A` / `ENABLE_C` 为 0 时,由 **decode 置 `illegal = 1`**,
走 G0 的 ILLEGAL 完成路径正确报 cause 2。
`subop_supported_now = 0` 只保留给 `SUBOP_INVALID` 与真正未被任何集合覆盖的编码,
是"decode 出错"的兜底,正常运行中不该命中。

**为什么这条容易写错**:两者读起来都像"不支持这条指令",但一个是架构行为、一个是死锁。
RISC-V 要求未实现的指令报非法指令异常,只有前者做得到。

### 22. FP 的合法性检查放派遣侧，G2 永远不发异常

**问题**:`mstatus.FS == Off` 与 `rm` 取保留值都让 FP 指令非法,但 **G2 的事件字段恒 0**,
FPU 发不出异常;而且 `ISQ_Group2` 不存 `inst_bits`,即使开了通路也没有 `tval` 来源。

**裁定**:**不开 G2 异常通路**。由 `dispatch_logic` 读架构状态合成 `fp_illegal`,
命中即改道 G0 的 ILLEGAL 完成路径。

```text
frm_illegal = (frm > 3'b100)
rm_illegal  = uses_rm(exe_subop) ∧ (rm==101 ∨ rm==110 ∨ (rm==111 ∧ frm_illegal))
fp_illegal  = is_fp_instruction ∧ (!fs_enabled ∨ rm_illegal)
```

**换来三样**:G2 事件字段继续恒 0、lane 2 契约一字不改;`ISQ_Group2` 不必增存
`inst_bits`(32);`tval` 是完整的(G0 本来就有编码),而开 G2 通路只能报 `tval = 0`。
代价是两条新边 `SIH → dispatch_logic`(`fs_enabled`、`frm`)。

**在派遣拍读架构状态为什么安全**——这是本条的关键论证:

```text
FS 的全部改变来路：
  csrw mstatus            CSR 指令 is_serial ⇒ 改的那拍窗口空
  fflags_accrue 置 Dirty   只做 → Dirty，**造不出假的 Off、也解不掉真的 Off**
  trap_entry / mret        随 flush 发生，窗口被清空
frm 的全部改变来路：
  只有 csrw fcsr/frm       is_serial ⇒ 窗口空
⇒ 一条 FP 指令派遣时读到的值，与它退休时的值必然相同
```

**助理补的三条,我原方案里都错了或漏了**:
- **`uses_rm` 必须静态分类**——原方案对所有 FP 指令盲查 `rm`,会把 `FMV.X.W` / `FCLASS` /
  `FSGNJ*` / `FMIN` / 比较类误判成非法(它们编码里那三位不是舍入模式)
- **`frm == 111` 同样非法**——原方案只排了 `101/110`。`frm` 只允许 `000..100`
- **`effective_rm` 快照进 G2 entry**,比让 FPU 读实时 `frm` 稳健(entry 可能驻留多拍),
  而且顺带**消掉了 `SIH → FPU  frm` 这条边**

**同时定死的两条**:
- `FS == Off` 时访问 `fcsr`/`fflags`/`frm` 三个 CSR **必须真发 `exception_flag`**,
  只清 `csr_write_enable` 会让非法 CSR 指令被当成普通完成正常退休,软件看不到错误
- FS 脏判据加 `rd_write_enable` 限定——不写 rd 的指令上一个无意义的 `rd_is_fp` 会误置脏。
  这一条**没有采纳**助理提的独立 `commit_fp_state_dirty[k]` 通道:限定一下即可,
  不值得为它加一条 per-tag 存储与一根提交线(与 2026-08-14 那次顶回同一理由)

### 23. 库外契约有了正式宿主

原先"库外无微架构文档"被当成"库外的一切都不写",于是 FU 与 decode/FE 的**契约**
无处安放——一度只暂存在本文件 §2.1、§2.4。

**裁定**:区分**微架构**与**契约**。库外单元的内部设计不写(范围划定不变);
但后端**已经据以设计、对方不满足就会出错**的那些约定,必须有宿主:

```text
FU契约.md      通用 flush / 寄存一拍 / 恒零字段、FU_ready、各 FU 的异常义务、
               csr_fu、LSU(含 A 扩展与 reservation)、FPU、ALU/BRU/DIV/MUL
前端契约.md    三条上游不变式、IB_Payload 每个字段的产生义务、
               各指令类的译码属性、illegal 的产生义务、FE 侧取指与重定向
```

**为什么必须分出来**:IMAFDC 补全后 decode 的义务翻了一倍(22 条原子子码属性、
52 条压缩子码、`ENABLE_*` 关时置 `illegal`、SYS 分类),却仍散在 IB ⑤ 与 dispatch ④ 两处;
而三条上游不变式(`use_rs3 ⇒ rs3_is_fp`、触碰 FP RF ⇒ `is_fp_instruction`、
`fe_valid` 两位前缀)**从来没有任何一份文档拥有过**,全靠下游默默当前提用。

### 24. `bypass_valid` 只加 `!exception_flag` 一道门

**背景**:对照 v1 RTL 发现它的 lane 3 有三道门
(`!store_buffered ∧ !exception_flag ∧ !global_flush_late`),而 v2 的
`p3_arbiter` 只写 `bypass_valid = winner_valid`。

**裁定**:只补 `!exception_flag`,另两道都不加。

**`!exception_flag` 为什么必须有**:出错指令的 `result_data` 是垃圾但 `tag` 是真的,
而**出错的 load / LR / SC / AMO 都是 `use_rd = 1`**,确实有 ISQ entry 在等这个 tag,
不门掉就会捕获垃圾并置 `ready`。这一位本来就在 request 里,不需要新增边。

**为什么不加 `rd_write_enable` 限定**(助理主张加,我顶回):`use_rd = 0` 的指令
(store、ILLEGAL、SYS、FENCE)**从未在任何 tag_mapping 留下映射** ⇒ 没有任何 ISQ entry
能持有它的 `wait_tag` ⇒ 广播无消费者、无害。`rd = x0` 同理(第 0 格硬连 `{0,0}`,
解析恒走 ARF)。这条论证库里对 ILLEGAL 已经在用,是既有的承重墙。
加这道门要给仲裁器开一个按 `tag_out` 索引 SCB alloc 批的只读口 ×4 lane,
收益只是省几次无消费者的比较。

**为什么不加 `!global_flush_late`**——这条差点让我违反既定裁定:
`p3_arbiter_G1` ④ 明写「`Result_valid` 与 `bypass_valid` 都不含 flush guard,
由各消费者自己挂」,而集成层的 `global_flush_late` 扇出名单里**明确不含仲裁器**。
加它等于要一条被明确否掉的边。消费者侧已经全覆盖:ISQ 的 flush 优先级最高、
dispatch 的 `accept` 被同一根线屏蔽。**照抄 v1 之前要先看 v2 有没有更强的既有安排。**

### 25. `flush_discard_mask` 不需要——drain 窗口内不可能发生 flush

**背景**:v1 的 `fake_lsu` 收一个 16 位 `flush_discard_mask`,逐 tag 清 store buffer,
注释说「保留已开始的 committed drain,丢弃 mask 命中的投机条目」。助理主张 v2 补上。

**先说一条事实**:`flush_discard_mask` **只出现在 `fake_lsu.sv` 里,全 RTL 没有任何东西
驱动它**,而 `fake_lsu` 本身从未被例化。它不是经过验证的 v1 接口,是个没写完的占位。

**裁定**:不加。LSU 每条 STB 条目一位本地 `draining` 就够。

```text
已收到 store_drain_req 的条目  ⇒ 已提交，保留
未收到 drain_req 的条目        ⇒ 必投机，全丢
```

**充分性证明**:drain 只在 head0 发起、按序、一次一条;而判定链**第 3 步(store drain)
排在第 4 步(外部中断)之前**——head0 卡在 drain 子流程时 `commit_count = 0`、
不产生任何 flush 输出,head1 也不被评估。所以 **drain 窗口内 SCB 根本不会发 flush**,
"未收到 drain_req ⇒ 必投机"没有反例。

**AMO 不适用这套**:它 `is_store = 0`、根本不进 STB。"已完成的 AMO 不被作废"
由 SCB 判定链第 4 步保证(§1.20),不归 LSU。

**同时定下**:flush 同拍不得新接受 `store_drain_req`。

### 26. `agu_early_tag` 不移植——v2 的 missed_wakeup 判据不同

v1 有一条 `LSU → P1` 的 `agu_early_tag`,作用是**取消** stall(`(A∨B) ∧ !C`):
AGU 提前宣告"这个 tag 的数据马上来",让 P1 放行依赖它的指令,
避开"bypass 已过、commit 未到"的死锁窗口。

**裁定**:不移植。v2 的 `slot_missed_wakeup` 判据建立在 `exec_done` 上,
而在 LSU 里在飞的 load **`exec_done` 还是 0**,根本不触发 stall,豁免也就无从谈起。
即便触发,v2 的 stall 也一定会在该指令提交时解除——是慢不是死。

**记下来是为了防止后来者"发现" v1 有这条而以为 v2 漏了。**

### 27. 取指故障走 `FETCH_FAULT` 子码,`IB_Payload` 一位不加

**问题**(对照真实环境的 FE 接口 `beta_be_interface_20260818/` 时发现):
那边的 `fe_be_info_t` 有 `excp_vld` 字段、顶层有 `fe_be_instr_excp_d`,
而**我们全库没有任何取指异常通路** —— `异常与trap语义.md` 写着 cause 1 的产生方是 FE,
但 `IB_Payload` 没有异常字段、`FE → IB` 那条边没有异常载荷,
全库也没有一处说"一条取指就失败的指令怎么走完后端"。

**这是三轮盲核都没抓到的缺口**,因为它是**缺一整条通路**,不是"两处矛盾"——
盲核的判据是"能同时引出两处互相矛盾的原文",而一条从不存在的通路没有第二处可引。

**裁定**:decode 产出 **`FETCH_FAULT` 子码**,与 `ILLEGAL` 同形。

```text
相同   route_class = BRU 固定 G0、requester 0、use_rs/rd = 0、is_serial = 0
唯二不同  cause = 1（指令访问故障）、tval = pc（不是 inst_bits）
```

**两条被否掉的备选**:
- 塞成 `illegal = 1` —— cause 必须是 1 不是 2,而口径是"cause 由子码硬编码"
- 在 `IB_Payload` 里加一位异常标志让 FU 去选 —— 那等于**把 cause 搬进 payload**,
  与既定口径直接冲突。而且刚为 `csr_write_intent` 动过一次冻结 ABI,不该再动

**因此 `IB_Payload` 一位都不加**:FE 告知 decode,decode 转成子码,到 IB 时它已经是
一条普通指令了。它的 `inst_bits` 是垃圾(根本没取回来),但没有消费者——`tval` 取 `pc`。

**检出与通路要分开**:检出归 FE、要等内存映射;**通路与检出无关,现在就得定**——
否则一条取指失败的指令进了后端就无人给它 `exec_done`,队头挂死。
和 §1.21「关掉的扩展必须走 `illegal` 而不是 `subop_supported_now`」是同一条道理。

### 28. 分支预测器只做 resolve 侧训练,不做 commit 侧

真实环境的 FE 接口有**两条**训练通路:`be_resolve_bp_update*`(执行拍)与
`be_commit_bp_update*`(提交拍)。我一度认为我们也该补 commit 侧。

**裁定**:只做 resolve 侧,commit 侧不做。

**为什么**(算我们自己的账,不照抄别人的接口):
- **ROB 只有 16 项** ⇒ 执行到退休最多隔十几条指令,投机训练的污染窗口极小
- **payload 里没有 `ct_type`** ⇒ **没有 RAS**。而"顺序敏感结构宁可等 commit"
  正是 commit 侧存在的主要理由,对我们不成立
- **代价不对称**:resolve 侧白送(BRU 执行拍手里什么都有);commit 侧要 SCB
  **逐格新增 `actual_taken` 存储**——它现在只存 `mispredict_target_pc`

**留痕的意义**:我第一次看那份接口时说"应补",是照着别人的接口做模式匹配、
没回头算自己的账。**参照实现能提示你缺什么,但不能替你决定该有什么。**

**但 `cf_class[1:0]` 要保留**(写接口简报时又辩了一轮,我原本主张删):
我当时的理由是"BHT/BTB 都按 PC 索引,给了 PC / taken / target 就够了"——**漏了
"该更新哪个结构"**。无条件跳转的 `actual_taken` **恒为 1**,喂进方向预测器是污染;
而 FE 光靠 `branch_pc` 分不出类别,除非回去重新取指译码,比传 2 bit 贵得多。

```text
cf_class = 00 COND_BRANCH / 01 DIRECT_JUMP / 10 INDIRECT_JUMP / 11 保留
           由 BRU 从 exe_subop 直接产生，不需要把 exe_subop 送回 FE
```

**它明确不含 call/return**——那要看 `rd`/`rs1` 是不是 `x1`/`x5`,而 ISQ payload
没有这两个寄存器号。这与 §1.28"没有 RAS"是同一件事的两面:
**不是不想做 RAS,是 payload 结构上就供不出判据**。将来要做,
得在派遣侧预算 `ras_action`,或把 `rd_idx`/`rs1_idx` 补进 payload。

**顺带定死一组容易混的名字**:

```text
actual_target      taken 时的控制流目标            训练目标预测用
mispredict_target  actual_taken ? actual_target
                                : pc + 指令长度    重定向用
redirect_pc        = mispredict_target
```

一条"预测 taken、实际 not-taken"的分支,`redirect_pc` 是 **fall-through**,
而 `actual_target` 是那个**没走成的**目标。拿前者去训练目标预测就学错了。

### 29. `free_slot` 不导出给 FE,且口径改为含同拍 dequeue

**用户裁定,两件事一起定的。**

**(一) 砍掉 `IB → FE  free_slot` 这条边。** FE 不需要、也不应当知道 IB 还剩几格。
协议是**盲发 + 读回实收 + 滑窗**:

```text
1  FE 手上有几条就摆几条，置 fe_valid
2  IB 同拍回 accepted_slot（结合自己的容量与本拍出队）
3  FE 下一拍按 accepted_slot 滑窗：收 2 就推进 2；收 1 就把原 slot1 挪到 slot0
   再补一条；收 0 就整组保持、下拍重试
```

**为什么这条我一直没发现**:集成层 §4 的核对清单第一条就是
「每条 out-event 字段、每条 Static Info **是否真有消费者**」——
`free_slot` 唯一的消费者是 FE,而 FE 盲发就不需要它。**我把这条清单漏跑在这根信号上了。**
更直接的原因是:我写接口简报时在**誊抄库内已有的边**,没有回头质询"接收方到底要不要"。

**还有一条比"没用"更重的理由**(用户给的):按一个**滞后**的容量提示去自我限流,
是**净亏**——拍初余量为 1、但本拍恰好出队 1 条时,盲发 2 条本可全收,
照提示只发 1 条就白丢一条。

### (二) 口径从"只用拍初空位"改成"含同拍 dequeue"

```text
原   free_slot = 8 - valid_count                  上一拍满 ⇒ 本拍必不收，吃一个气泡
新   free_slot = 8 - (valid_count - deq_count)    上一拍满、本拍出队 2 ⇒ 本拍即收 2
```

**代价要记住**:`deq_count` ← `accept[s]` ← `isq_free_for_dispatch`(含同拍 issue)
← 各 FU 的 `FU_ready`。于是
`FU_ready → accept → deq_count → free_slot → accepted_slot` 成为一条
**穿到 FE 接口的组合路径**,而 `FU_ready` 里含**库外 LSU** 的反压。
§1.12 当初记的"含同拍 issue 把 `FU_ready` 拉进 P1 组合路径",现在延伸到了芯片边界。
**功能无误,时序收敛时须重点核。**

**两条已核实的安全性**:
- **无环**:`deq_count` 只依赖 IB **拍初**的 `inst_valid`,不依赖本拍的 `enq_count`
- **同格读写安全**:满队列同拍收发时写入的正是本拍被读出的队头格,
  而队头输出是持续组合值、本拍已被下游取走,边沿写入不破坏该次读出

**口径表因此变了**:IB 从"拍初值"那一侧挪到了"含同拍"那一侧,与
`isq_free_for_dispatch` 同侧;只剩 SCB 的 `can_alloc_*` / `buffer_empty` 还是拍初值。

### 30. FENCE.I 的提交流程 —— SCB 必须能认出它,否则功能根本不发生

**起因**:用户问"FENCE.I 提交时具体流程是什么"。我把流程从头走一遍,
才发现自己**加了 `recovery_kind = FENCE_I` 和 `frontend_icache_invalidate`,
却没给 SCB 任何识别手段** —— 这个枚举值当时是产生不出来的。

**完整流程**:

```text
派遣   is_serial=1 ⇒ 退休窗口空 ⇒ 所有更早的 store 都已 store_done、已落内存
发射   进 G3
完成   LSU 确认「前序代码 store 已对取指可见」后，才驱动 lane 3 完成 → exec_done
退休   FENCE.I 在 head0 且 done，判定链第 5 步同拍定三件事：
         ① 提交它        commit_count=1、minstret+=1
         ② 清更年轻的     flush_valid=1、flush_tag=head0_tag
         ③ 告诉前端      recovery_kind=FENCE_I
翻译   flush_model 同拍：global_flush_late=1
                        redirect_pc = PC_File[flush_tag].inst_pc + 4
                        frontend_icache_invalidate = 1
                        trap_state_write.valid = 0   ← 不是 trap，不动架构态
重取   FE 先清 I-cache/预取，再从 redirect_pc 取指
```

**为什么 SCB 躲不掉**——关键不在"标注 kind",在 ② 那一步:
SCB 能触发 flush 的谓词只有 `exception_flag` / `mispredict_flag` / `is_mret` / 外部中断,
**一个都不匹配 FENCE.I**。没有识别手段,它会落到第 6 步「其余,正常提交」——
**flush 与重取根本不会发生**,那些在 I-cache 失效之前就取好的更年轻指令继续执行,
而它们可能是旧代码。**这不是标签问题,是功能不发生。**

**核过的三条绕不开**:
- 让 LSU 直接给 FE 发 invalidate、SCB 照常提交 —— invalidate 本身确实幂等保守,
  但 **younger flush 还是没人发**,旧代码照样执行
- FENCE.I 不提交、重定向到自己的 PC —— 会永远重执行
- LSU 冒充 `mispredict_flag=1` + `target=pc+4` —— 功能能跑通,但打破"G3 事件字段恒 0"、
  污染分支误预测计数与调试语义,且 `frontend_icache_invalidate` 仍无来源

**裁定**:`is_fence_i` 进 **SCB 的 alloc 批**,由 **`dispatch_logic` 导出**
(`is_fence_i[s] = (exe_subop[s] == SUBOP_FENCEI)`)。

- **不进 IB_Payload**:它是 `exe_subop` 的纯函数,按 §1.8 对 `FU_Group` 的同一条先例
- **不进事件批**:事件批只在 `exec_done=1` 时有效,而判定链第 5 步本就排在第 1 步
  (`head0_done`)之后 ⇒ **两种放法时序等价**;那就选便宜的——alloc 批不动完成通路,
  **保住"G3 事件字段恒 0"这条不变量**

**两条自洽性已核**:
- **中断抢占安全**:第 4 步排在第 5 步前,done 但未提交的 FENCE.I 会被中断作废、
  重执行。LSU 侧的可见性工作是**幂等**的;而 `frontend_icache_invalidate` 由
  flush_model 在提交拍产生,那一拍没发生就没清,**不存在"清了却没重取"的中间态**
- **不进第 4 步的"不可作废"类**:原子指令要保护是因为改了内存不可回滚;
  FENCE.I 什么也没改,作废重来完全等价

### 31. reservation 是 LSU 内部事务,后端不送任何相关信号

**起因**:用户问"LR/SC 不是 cache 内部自己解决的事吗?后端只管发 ld/sd"。
他是对的,而我之前把助理设计的 LSU 内部机制当成了接口。

**被撤销的**:`SCB → g3_lsu_iface  commit_valid[k] / commit_tag[k]` 这条边,
以及配套的"LR 完成先建 pending、等按 tag 提升才生效"整套机制。

**为什么当初会加**:LR 完成 ≠ LR 退休,中间可能被中断作废;若作废的 LR 留下有效
reservation,后续 SC 会**错误成功**。而"退休了没有"是 LSU 自己推不出来的,
所以助理提出让后端告诉它。**推理没错,但结论越界了** —— 它是在替 LSU 设计内部机制。

**裁定**:改成保守做法——**`global_flush_late` 到达时清除尚未被 SC 消费的 reservation**。

```text
代价   被作废的 LR 的 reservation 跟着没掉 ⇒ 后续 SC 偶发失败 ⇒ 软件重试一轮
合法   RISC-V 明确允许 reservation 偶发失效
换来   接口少一条边；LSU 少一套 pending/提升机制；reservation 完全自洽于 LSU 内部
```

**为什么不担心活锁**:受约束的 LR/SC 序列**不允许有任意分支**,LR 与 SC 之间基本不会有
误预测引起的 flush;真来的多半是中断,而中断间隔比那几条指令长几个数量级。
**这是推理不是实测** —— 若将来测出活锁,那是接口要重新裁定的信号。

**这条也顺带解决了另一个洞**:全库原先**没有任何一处**写"对该地址的写要让 reservation
失效"。改成"内部事务"之后,那条本来就该由 LSU 自己保证,不再是我们文档的缺项。

**更一般的教训**:接口应当只规定"对方必须对我表现出什么行为",不规定"对方内部怎么实现"。
助理给的机制推理链是对的,我采纳时**没问"这归不归 LSU 管"**。

---

### 32. access fault 的通路是实的,"恒 0 保留"这个写法本身是错的

**问题**:cause 1 / 5 / 7 的**检出**要等内存映射。此前把 5 / 7 写成"未实现、留空",
把 `store_done_exception` / `_cause` 写成"保留未实现,预期恒 0"。

**裁定**:检出可以为空,**通路不许为空**。删掉全部"恒 0"表述,
5 / 7 进正式号段表,`store_done_exception` / `_cause` / `_tval` 成为功能信号。

**为什么"恒 0"不是无害的占位**:下游会按恒 0 去化简。SCB 的判定链会少一个分支、
`flush_model` 的 kind 选择会退化、`tval` 的多路选择会被优化掉。等映射真到位时,
接上的**不是一根线,而是一次重新裁定**——SCB 自己就写着这句话
("将来若要支持,这条前提失效,判定链要重新裁定")。现在裁,代价是一段文字;
那时裁,代价是回头改判定链。这和 §27 取指故障"通路先定好"是同一条道理。

**cause 7 是唯一有两个上报时机的 cause**:

```text
执行拍检出    lane 3 的 exception_flag/cause/tval,与 cause 6 同形 ⇒ 这条 store 永不 drain
drain 拍检出  store_done_exception/_cause/_tval ⇒ 写进该 tag 的事件批
```

**drain 拍这条不新增判定链分支**——这是本次裁定里唯一需要想的地方,
而现成的判定链次序恰好把三件事一起办了:

```text
第二步(exception)排在第三步(store drain)之前
    ⇒ 事件批一有异常,第三步永远到不了      不会重发 drain,不会死循环
    ⇒ 由现成的 exception 分支处置          不新增分支,不改 flush kind
故障时不置 store_drain_done
    ⇒ 这条 store 不属于「不可作废」类别      而它的写本来就没发生
```

最后一条靠一个**LSU 侧的硬性义务**成立:`store_done_exception = 1` 时**内存不得被修改**。
没有这条,一条已写进内存的 store 会被中断作废、重执行时写两次。

**代价**:事件批多一个写者(执行拍的 writeback 之外加上 store_done)。
两者对同一 tag 严格先后,且只可能把"无异常"升级为"有异常",不存在竞争。
故障晚一拍才被处置,无所谓——异常本来就在退休拍按序发生。

**8 / 9(U/S 态 ecall)与 12 / 13 / 15(page fault)不比照办理**:
它们缺的不只是判据,还缺特权态 / 地址翻译这些**结构**,通路无从谈起。

---

## 二、暂存内容(等宿主文档建立后迁入)

### 2.1 FU 与前端的契约 —— **已迁出，本节只留指针**

原暂存于此的全部内容已迁入正式宿主（裁定见 §1.23）：

```text
FU契约.md      通用 FU 契约（flush / 寄存一拍 / 恒零字段）、各组 FU_ready 语义、
               各 FU 的异常义务、csr_fu 行为契约、LSU（含 A 扩展与 reservation）、
               FPU、ALU0/BRU/DIV/ALU1/MUL
前端契约.md    三条上游不变式、IB_Payload 每个字段的产生义务、
               各指令类的译码属性表、illegal 的产生义务、FE 侧取指与重定向
```

`g3_lsu_iface` 的完整双向边集已落进 `FU契约.md` §5.5。仍留一条余地：
G3 那条 `FU_ready` 语义是按"反压全折进 `FU_ready`"写的；若 LSU 另有独立的 issue 侧约束
（如 store buffer 满须单独挡 store），`ISQ_Group3` 的 `issue` 判据要相应增项。

---

### 2.2 系统指令待补挂点

原写在 `system_instruction_handler` ①,后移至该文档文末,现移入本文件。
系统指令的 charter 归 `system_instruction_handler`,但这些项既不是状态也不是 schema。

- ~~`mstatus.FS == Off` 的 FP 禁用检查、`rm` 保留值的非法检查~~ —— **已闭合**。
  当初以为"两者都要给 G2 开异常通路",后来发现不必:改由派遣侧读架构状态判、
  命中即改道 G0 的 ILLEGAL 路径,**G2 的事件字段继续恒 0**。裁定见 §1.22
- U 态特权检查与 ECALL cause 细则（8 / 11 之分）——M-only 下恒 11
- SFENCE.VMA：S 态 + MMU,远期

**ECALL / EBREAK / WFI / FENCE / FENCE.I 五条已不在待补之列**（IMAFDC 补全时落地）,
宿主分别是 `IB微架构文档.md` ⑤（译码属性）、`ISQ_Group3微架构文档.md` ⑤（FENCE 的组内位置）、
`flush_model微架构文档.md` ④（FENCE_I 的重取）、`异常与trap语义.md`（cause 3 / 11）。
留在这里的只有一句仍然成立的老话：
**"TRAP"只作 ILLEGAL / ECALL / EBREAK 的统称,不是 RTL 子码名。**

---

### 2.3 第二批：验证环启用前必须落地的五条

**分界**：第一批(已完成)让机器**算得对**；这五条让机器**可被验证**。
它们**不阻塞库内 20 模块的 RTL 编码**，但在 Gate#2(Verilator + Spike 逐指令锁步对拍)之前
必须全部到位。每条附 v1 RTL 的既有处置作参照——那套代码跑过 lockstep，有真实答案。

**当前状态**：④ 的 PC 侧、⑦、②、③ 四条已落地(IMAFDC 补全时一并做完)；
④ 的 CSR / trap 两路与 ⑧ 的验证环部分仍未定。

#### ④ retire trace 出口（**PC 侧已落地**；CSR / trap 两路仍待定）

**缺什么**：lockstep 在提交点比"哪条指令 + 它改了什么"。
`rd_idx` / `rd_is_fp` / `rd_write_enable` / `commit_data` 已在 commit 总线上；
**PC 与原始指令编码都没有出口**——`PC_File` 原先只有 `flush_tag` 一个读口，
`inst_bits` 只进 `ISQ_Group0`、到不了提交。

**定案：只补 PC，不补编码。`PC_File` 加读口、不加存储。**

```text
PC_File   加 2 个组合读口，地址取 SCB 的 head0_tag / head1_tag
          → trace_pc[k](64×2)，随 commit_valid[k] 有效
          存储不变，仍是 16 entry × 64 bit，仍只存 inst_pc
inst_bits 不做提交口——不进 SCB、不另建阵列、不并进 PC_File
SCB       零改动：head0_tag / head1_tag 本来就是它的 out-event（现驱动 Buffer 读地址），
          多接一个目的端是纯扇出，由集成层 §1.3 登记
```

**为什么不补编码**：对拍真正比的是 **PC 序列 + 架构态写入**。补上 `trace_pc` 之后
RVFI 那套字段就齐了（`pc_wdata` 由下一条 retire 的 PC 得到，不必单出）。编码本身**不增加
检出能力**——没有自修改代码，PC 唯一决定编码，比对方拿 ELF 一查即得；C 将来放开也不破，
先读 2 字节看 `[1:0] != 2'b11` 就知道长度。

**这一条推翻了此前"助理否掉 PC 反查 ELF"的结论。** 助理当时的三条反对（压缩指令 /
重定向 / 双发射）针对的是"重建整条 PC 流"这个弱版本；而 trace 里**每条 retire 自带自己的
PC**，不做任何重建，三条都不成立。

**残余风险与兜底**：编码提交口能多抓一种失效——**取指路径取错了指令、但 PC 是对的**
（如 `add x1,x2,x3` 被破坏成 `add x1,x3,x2`，恰逢 `x2==x3` 时结果也一样）。
这个**不该在提交点抓，该在取指口抓**：`inst_bits` 本来就在 `FE → IB` 这条边上，
对拍环在那儿和 ELF 比即可——后端零成本、零新端口，且定位更准。

**仍未定的两路**（不在本次改动内）：
- CSR apply 需不需要带 tag 的 trace sideband
- 异常不算普通 retire，是否另出 `trap_event{pc, cause, tval}`

> **v1 参照**：`rtl/be_code/rob_sidearray.sv` 按 tag 存 `alloc_pc`（`alloc_valid` /
> `alloc_tag_0/1` / `alloc_pc[1:0]` 入口俱全），存储结构与 `PC_File` 同款，可直接对照。
> 另注：v1 的 `commit_unit` ⑥ 曾有 `inst_pc(64)，2 读口，仅 trace 用`，
> 因当时无消费者被当死接口删除（见本文件 §1 的裁定精神）——现在消费者出现了，
> 且落点选在 `PC_File` 而非 `commit_unit`，是重新引入而非新造。

#### ⑦ ECALL / EBREAK / WFI（**已落地**）

宿主：`IB微架构文档.md` ⑤ 的译码属性表 + `异常与trap语义.md` §1 的 cause 3 / 11。

**缺什么**：这三条连同 FENCE/FENCE.I 曾全塌缩成 `cause = 2`。Spike 按真实语义执行，
**激励里出现一条就发散**。更要命的是 **ECALL 是测试程序的标准收尾手段**
(`riscv-tests` 靠它表达 pass/fail)，没有它连"程序正常结束"都无法表达。

**定案**：

```text
ECALL   G0 requester 0，与 ILLEGAL 同路径，cause = 11（M 态 environment call）
EBREAK  同上，cause = 3
WFI     实现为正常退休的 NOP（spec 明确允许）
cause = 2 此后只留给真正的非法指令（未支持 opcode、保留 rm、FS=Off 的 FP 指令等）
```

> **v1 参照（决定性）**：`rtl/be_code/alu_simple.sv:161-162` 已经这么做了——
> ```
> exception_flag  <= is_illegal_op || is_ecall_op;
> exception_cause <= is_illegal_op ? 64'd2 : is_ecall_op ? 64'd11 : 64'd0;
> ```
> 子码侧 `exe_subop_pkg.sv:68-70` 有 `ALU_ECALL = 59` / `ALU_MRET = 60` / `ALU_ILLEGAL = 63`，
> 且 `:174` 把它们与 ALU 类归在同一分类里。**即"同一完成路径按子码选 cause"这个做法
> v1 已验证可行，v2 照搬即可。**
> v1 **没有** EBREAK 与 WFI 子码——这两条是 v2 要新增的部分。

#### ② FENCE：必须是 LSU 屏障，不能当 NOP（**已落地**）

宿主：`IB微架构文档.md` ⑤（`is_serial = 1`、G3·FENCE 分类）+ 本文件 §2.1 的 LSU 契约。

**缺什么**：有 store buffer 时 NOP 不成立。FENCE 要走 G3/LSU，等旧访存与 store drain 完成，
并阻止后续相关访存越过它。保守做成全屏障可接受。编译器会发 FENCE，跑真程序绕不开。

**落地时的简化**：`is_serial = 1` 让"更早的访存全部已退休"成为结构性事实，
LSU 侧的屏障因此退化成"排空自己的 store buffer"——比通用屏障简单得多。

> **v1 参照**：v1 的 `exe_subop_pkg.sv` 有 `fence_type_e{FENCE, FENCEI, SFENCE_*, HFENCE_*}`
> 整套枚举，但**未接进 backend 子码空间**，是纯占位——即 v1 也没有真正实现 FENCE。
> 这条没有可借鉴的现成实现，属全新工作。

#### ③ FENCE.I：要独立的 redirect 通道（**已落地**）

宿主：`flush_model微架构文档.md` ④#1/#3。

**缺什么**：文档里挂了很久的"复用 `mispredict_flag = 1` + `target = pc + 4`"这个技巧，
助理指出会污染调试、性能计数与语义归属。**更实质的问题**是它只解决了重取 PC，
**没解决 I-cache 失效**——有 I-cache 时 FENCE.I 必须让 FE 丢弃缓存。

**定案**：`flush_kind` 加宽成 `recovery_kind[2:0]`，新增第五种 `FENCE_I`；
`flush_model` 另出 `frontend_icache_invalidate = (recovery_kind == FENCE_I)` 送 FE。
`redirect_pc = PC_File[flush_tag].inst_pc + 4`。

**`+4` 是常量、不需要指令长度**：RVC 里没有 `C.FENCE.I`，这条永远是 32 位。
所以整条通路不需要任何 per-tag 的 `is_compressed`，`PC_File` 也不必多存一位——
这一点当初没想到，是写 `flush_model` 时才发现的省法。

仅在宣称 `Zifencei` 时实现——届时 ISS 的 `--isa` 要加 `zifencei`。

#### ⑧ 系统边界与验证环（新建文档，非硬件）

**缺什么**：DUT 与 ISS 在哪共享内存、复位 PC 取什么、imem/dmem 接口形态、ELF 谁加载、
比对点定在哪、测试程序如何终止。全套文档一字未提——它不属于任何一个微架构模块。

**定案**：新建一份"系统边界与验证环"文档，与 `Module.md` / 本文件同级放 `file/` 下。

**IMAFDC 补全时拆走了一半**：cause 号段表、`tval` 口径、各组能产生哪些异常、
`ENABLE_*` 的翻位前置条件，全部落进了新建的 `异常与trap语义.md`——那些是**硬件契约**，
不该和验证环混在一起。⑧ 剩下的是**纯验证环**内容：复位 PC、imem/dmem 接口形态、
ELF 谁加载、比对点与比对字段、测试程序的终止约定。这份仍未建。

> **v1 参照**：`rtl/be_code/backend_top.sv:15-27` 把整套 LSU 接口引到顶层边界，
> `fake_lsu.sv` 未被例化——说明 v1 也是把内存接口留给上层 testbench 的。
> `rtl/design_flow/standard_verification_flow.md` 有对拍方法论(seed 复现、失败根因四分类、
> 回归资产)，但没有物理边界定义。

**依赖关系**：⑦ 与 ④ 互不依赖，可并行；④ 是判 pass/fail 的前提，⑦ 是程序能收尾的前提，
**两者都到位才能跑第一个有意义的 lockstep**。②③ 只在跑编译器产物时才需要，可后置。
⑧ 与前四条并行推进，但必须早于第一次对拍。

**补全后剩下的路**：④ 的 CSR / trap 两路要等 ⑧ 定下比对协议才能定字段
（先定比对方怎么工作，才能定 DUT 出什么），所以下一步是写 ⑧。
在那之前可以先跑第一档——Spike commit-log 格式 + 离线 diff，只用现有的
`trace_pc` 与 commit 总线就能启动，不依赖 ⑧。

---

### 2.4 其他已知未闭合项

- ~~**FE / decode 侧的上游契约无宿主**~~ —— **已闭合**,三条不变式现居 `前端契约.md` §1
- ~~**`g3_lsu_iface` 待补**~~ —— **已闭合**,完整双向边集现居 `FU契约.md` §5.5
- **packed 字段顺序刻意不冻结**：`IB_Payload` = 302 bit、`ISQ_Payload` = 486 bit
  只冻结总宽度与各字段宽度,packed 顺序属实现
