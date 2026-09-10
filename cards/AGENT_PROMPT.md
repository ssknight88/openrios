# RVA23 A 卡工作树：给执行 agent 的简报

你要在 `C:\Users\rivai\Desktop\规范测试\测试v5\FULL-FLOW-BUNDLE\RVA23_card_kit\TEST_NEW\` 里工作。这是 RVA23 指令 card（A 型扩展，一条指令一张 YAML）的**现行工作树**。先按顺序读下面的文件，再做【任务】。

## 1 先读什么（按顺序）

| 文件 | 是什么 | 读多细 |
|---|---|---|
| `方案.md` | 流程与判据的 SSOT：§1.2 A/B/C 三型、§2.1 七步与分界、§2.3 六条语义写法、§2.4 三条边界、§3 做卡步骤、§4 检查、§7 待定 | 全文 |
| `card.template.v1.yaml` | A 卡格式 SSOT。**头部注释 = 填写规则 + 来源 + 待定 + 变更记录**，正文 = 键骨架。每个键都在，不适用写 `null` / `[]`，不删键 | 全文，头部逐条 |
| `编码格式.md` | 编码图案记法（借 QEMU decodetree）：`0/1` 固定、`.` 字段、字段 `位置:宽度`、`s` 有符号、`<<n` 左移。只定义了 32 位；16 位压缩指令按同记法写 16 字符（缺口⑯） | 全文 |
| `落槽表示例.md` | 落槽表长什么样（Sail 每行 → 卡的槽 / 四类噪音 / 缺口） | 全文 |
| `缺口清单.md` | **所有已知填不进的东西**，编号 ①–㉑，按 Mnemonic 记「哪部分填不进、归 A/B/C 哪型、为什么」；末尾有 lint v3 的现状数字 | 全文 |
| `B_C模块问题.md` | B 型（无指令扩展）/ C 型（CSR）的问题清单，本轮**不做** B/C，只记 | 浏览 |
| `cards/I/add.yaml` `cards/I/lw.yaml` `cards/I/beq.yaml` `cards/A/amoadd.w.yaml` `cards/F/fmin.s.yaml` `cards/Zicsr` 下任一张 `cards/H/hlv.w.yaml` | 样例：ALU / 访存 / 分支 / RMW / 浮点 / CSR / 访问上下文 各一 | 逐行 |

行范围：`..\..\RVA23_Instruction_Classification.xlsx`（679 行）。排除 V/Zv\* 和 Mnemonic 为 `(behavioral/PMA)` 的行；Zfa 的 7 行 Optional 也做。现状 **318 张**，全部铺完。

## 2 golden 源（只读，一行不改）

- Sail：`..\..\_golden\sail-riscv\model\`，commit `803f192b`。execute 子句在 `extensions\<ext>\*.sail`；访存库 `sys\vmem_utils.sail`；异常类型 `core\types.sail`；`ExecutionResult` 联合 `sys\insts_begin.sail:16`
- UDB：`..\..\_golden\riscv-unified-db\spec\std\isa\{inst,ext,csr,param,profile}\`，commit `0a3a1e2`。指令 yaml `inst\<dir>\<mnemonic>.yaml`；参数 `param\<NAME>.yaml`
- 语义**逐字抄 Sail**（方案 §2.3 第 1 条），机械字段（编码 · aliases · hints · access）抄 UDB。**行号只从本地文件数**，不从网页取。找不到原文的写 `⟨待核⟩`，不许猜、不许编

## 3 硬规矩（违反任何一条 = 返工）

1. **一个 mnemonic 一张卡**，文件名 = key。aq/rl 进 `encoding.fields`。MOP 按 xlsx 一行一族（`mop.r.n` 等）
2. **目录 = 扩展，一层**：`cards\<桶>\<key>.yaml`。类型看首行 `template:`，不靠目录。`cards\_undecided\` 里 14 张系统/CSR 指令格式未定，只改机械字段不改语义
3. `operands[].type` ∈ `X | F | V | imm | csr`；`regs[].type` ∈ `X | F | V | csr`。regidx/cregidx 都是 X，位宽看 `encoding.fields`；`csr` 是 12 位地址，**不分 X/F**
4. **不改模板、不加键**（方案 §3.4）。装不下的写进卡尾注释 `# 填不进<编号>（…）` 并登记到 `缺口清单.md`；编号接着 ㉑ 往后排
5. `dynamic_check` 只收 `Illegal_Instruction | Virtual_Instruction`；其它 cause 归 `outcome.exceptions`
6. 七步之间无执行顺序；格子内列表**有序 = 优先级**，顺序抄 Sail 判定顺序（encdec 的 `when` 守卫排最前）
7. Sail 的 `if` 拆成目标槽的 `when`；套在里面的条件用 `&` 粘外层守卫；`match r { Success => {…}, failure => failure }` 成功分支正常落槽
8. 只剥四类噪音：类型/断言 · Ok/Err 与 return 包装 · 读序调整 · 非本指令分支。**其它落不进的是缺口，不是噪音**
9. kit 目录 `..\RVA23_card_kit\` 是旧副本，**不动**

## 4 工具（都在 TEST_NEW 下跑）

```
python lint.py                 # A 结构硬错误(退出码) · B 启发式缺口 · C 卡↔Sail 反向落槽 · D 卡↔UDB
python lint.py --gaps          # 逐卡列未落槽的 Sail 行（= 落槽表初稿）
python lint.py -v              # 全量明细
python tools/verify_sail.py --write   # 卡上每条表达式去 Sail 原文找；写「Sail 定位」行进卡头
python tools/udb_fill.py --write      # 按 UDB 填 aliases/hints/access；核 encoding.match / variables / definedBy
```
Windows 上加 `PYTHONUTF8=1`。**交付前 lint A 档必须 0 硬错误**；B/C/D 只报不判，但新出现的未落槽行要么落槽、要么登记。

## 5 交付

改动的卡 + `缺口清单.md` 增补（新缺口给编号、写「填不进什么 · 归哪型 · 为什么」）+ 一段汇总：动了几张、lint 四档数字前后对比、新登记了什么。**不要**改 `方案.md` 正文；要改模板先在汇总里提，等 review。

## 6 【任务】

（把要做的事写在这里。默认任务如下，可替换）

1. C 档「未分类」约 85 行逐行看：能落槽的落槽（改卡）、是噪音的说明属四类中哪一类、都不是的登记新缺口。优先 `let eff_priv = effectivePrivilege(…)` 那 18 行 —— 18 张 AMO 的 `memory.context` 现在是 null，样例卡 `cards\A\amoadd.w.yaml` 把它写在注释里，属真漏，按 H 卡（`cards\H\hlv.w.yaml`）的 `context` 写法补
2. B 档 ⑱ 抓到 77 张、卡上只标了 48 张：把没标的 29 张补上 `# 填不进⑱` 注释（`tools/verify_sail.py` 与 `lint.py -v` 的输出能定位）
3. 跑 `lint.py`，A 档 0 错，把 C 档前后数字写进汇总
