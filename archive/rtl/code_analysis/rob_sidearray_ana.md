# rob_sidearray.sv 深度解析

`rob_sidearray.sv` (ROB 侧边数组) 在微架构设计中是一个典型的**“胖瘦拆分 (Fat-Thin Split)”**优化手段。

它本质上就是 ROB 的一个附属数据包，用于存储那些**占地面积大，但是在常规判断（如依赖检查、Ready状态推进）中根本用不到的冷门元数据。**

---

## 1. 为什么不把它合并在 `rob.sv` 里？

如果你回看 `rob.sv`，里面的 `rob_entry_t` 结构体非常紧凑。因为 ROB 里的 `done` 信号、目标寄存器 (`rd_idx`) 这些东西，每拍都会被 P1 和 P4 大量组合逻辑疯狂扫视和查阅，为了保证时序不爆炸，核心 ROB 必须尽量“瘦身”。

然而，当发生异常或分支预测失败时，我们需要记录诸如：
*   出错指令原本的 `PC` 地址。
*   BRU 算出的纠正后跳转地址 `target_pc` (64位)。
*   异常的根因代码 `exception_cause`。

这些动辄上百位的数据（Metadata），如果塞进核心 ROB，会导致极大的面积和扇出延迟。因此，我们创建了一个和核心 ROB 同样拥有 `ROB_DEPTH` 深度的平行宇宙——**Sidearray**。

---

## 2. 生命周期与同步更新

`rob_sidearray` 与主 `rob` 同生共死，唯一的接口就是靠相同的 **ROB Tag** 进行索引。

### 2.1 Alloc 阶段：初始化 PC
当 P1 阶段通知主 ROB 分配新 Tag（`alloc_tag`）时，`sidearray` 在同一拍捕捉到这个 Tag，并把这条指令初始的 `PC` 值存入对应的槽位，并将异常种类设为 `FLUSH_NONE`。

### 2.2 Writeback 阶段：捕捉异常报告
绝大多数指令都是良民，一生都不会触发这段逻辑。
但如果某个 FU（比如 BRU 或者 LSU）在 P3 写回时，将 `wb_payload.mispredict_flag` 或 `exception_flag` 置 1 了：
*   Sidearray 会通过传回来的 `tag_out` 定位到对应槽位。
*   将从 FU 随附的 `correct_pc` 等罪证记录在案，并把 `valid` 置起。

### 2.3 Commit 阶段：提供证据
如果在 P4 阶段，主 ROB 里的最老指令带有异常标记准备爆炸引发 `global_flush_late`，P4 控制器会拿着这个罪人的 Tag（`flush_tag`）向 Sidearray 索要证据。
*   组合逻辑接口：`assign flush_meta = sidearray[flush_tag];`
*   Sidearray 迅速把之前存的 `target_pc` 吐给顶层。顶层会将这个 PC 发送给前端取指模块，命令其：“从这个正确的地址重新开始执行吧！”。
## Flush priority over P3 metadata capture

If `clear_metaarray_flushvalid` is asserted in the same cycle as a P3 flush-causing `wb_payload`, the clear path wins. Same-cycle killed P3 results must not create a new `flush_valid` entry after the recovery boundary has been selected.
