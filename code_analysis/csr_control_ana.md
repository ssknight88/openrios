# csr_control.sv 深度解析 (CSR 序列化与 Pending Sideband)

`csr_control.sv` 是后端全局 CSR 生命周期控制块。它不保存架构 CSR 文件本身，而是保存 CSR 的 in-flight 屏障状态和 P3 到 P4 的 pending side effect。

---

## 1. 模块定位

CSR 在本设计中同时具备两种属性：

*   **序列化屏障**：CSR 一旦被 P1 接纳，直到 P4 正常退休或全局 flush 前，后续年轻指令不能进入后端。
*   **提交期副作用**：CSR 的架构写不能在 P2/P3 发生，只能在 P4 精确 commit 时生效。

`csr_control.sv` 正是这两件事的状态载体：

*   `csr_inflight_*`: 记录当前唯一 in-flight CSR。
*   `csr_pend_*`: 记录 CSR 执行完成后等待 P4 commit 的真实 CSR 写副作用。

---

## 2. 状态寄存器

### 2.1 In-flight Tracker

```systemverilog
logic             inflight_v;
logic [TAG_W-1:0] inflight_tag;
```

含义：

*   `inflight_v=1` 表示机器中存在一个尚未退休或 flush 的 CSR 指令。
*   `inflight_tag` 是该 CSR 的 ROB tag。

P1 的 admission 逻辑读取 `csr_inflight_valid`。当该位为 1 时，所有年轻指令都必须停在 P1/ISB 边界，不能继续进入 ROB/ISQ。

### 2.2 CSR_PEND_BUF

```systemverilog
logic             pend_v;
logic [TAG_W-1:0] pend_tag;
logic [11:0]      pend_addr;
logic [XLEN-1:0]  pend_wdata;
```

含义：

*   `pend_v=1` 表示有一个 CSR 写副作用等待 P4 commit。
*   `pend_tag` 必须匹配即将 commit 的 CSR ROB tag。
*   `pend_addr/pend_wdata` 是最终写入架构 CSR 文件的地址和值。

因为 CSR 被全局序列化，本设计合法状态下最多只有一个 in-flight CSR，因此 pending buffer 不需要多 entry。

---

## 3. Set / Clear 时序

### 3.1 P1 接纳 CSR

当 `p1_csr_valid` 为 1：

```systemverilog
inflight_v   <= 1'b1;
inflight_tag <= p1_csr_tag;
```

`p1_csr_valid` 由顶层连接为 `rob_alloc_valid[0] && isb_payload[0].is_csr`，也就是说只有真正被 P1 分配进 ROB/ISQ 的 slot0 CSR 才会设置 in-flight tracker。

### 3.2 P3 捕获 CSR Pending

当 Group 0 的写回 winner 是 CSR，且：

*   `csr_write_enable == 1`
*   `exception_flag == 0`

则写入 pending sideband：

```systemverilog
pend_v     <= 1'b1;
pend_tag   <= p3_csr_payload.tag_out;
pend_addr  <= p3_csr_payload.csr_addr;
pend_wdata <= p3_csr_payload.csr_wdata;
```

只读 CSR 不分配 pending；异常 CSR 也不分配 pending。这样可以保证架构 CSR 文件不会在 speculative 阶段被污染。

### 3.3 P4 正常 CSR 退休

当 `p4_csr_retire` 为 1：

```systemverilog
inflight_v <= 1'b0;
pend_v     <= 1'b0;
```

这里使用的是 `p4_csr_retire`，不是 `p4_csr_write`。原因是只读 CSR 虽然没有 CSR 文件写副作用，也必须清除序列化屏障；写型 CSR 则同时由 `p4_csr_write` 驱动 `csr_unit.sv` 写架构 CSR 文件。

### 3.4 Global Flush

当 `clear_csr_trackers` 为 1：

```systemverilog
inflight_v <= 1'b0;
pend_v     <= 1'b0;
```

这处理 older mispredict、exception、interrupt 导致的 late flush。由于架构 CSR 文件尚未在 P2/P3 被更新，flush 不需要 CSR rollback，只需要清掉 speculative tracker。

---

## 4. 与 P4 Commit 的契约

`p4_commit_control.sv` 必须在 CSR 正常 commit 前检查：

*   `csr_inflight_valid == 1`
*   `csr_inflight_tag == commit_tag`
*   若 `ROB[head].csr_write_enable == 1`，还必须满足：
    *   `csr_pend_valid == 1`
    *   `csr_pend_tag == commit_tag`

这些条件是 CSR 精确提交的关键保护。若 pending 未准备好，P4 不应让 CSR ROB entry retire，否则可能出现 CSR entry 已退役但 `csr_inflight` 未清、后续派发永久阻塞的问题。

---

## 5. 与其他模块的关系

*   `p1_admission_and_backpressure.sv`: 读取 `csr_inflight_valid`，实现 CSR 序列化阻塞。
*   `p1_rob_allocation_and_isq_write.sv`: successful CSR allocation 产生 `p1_csr_valid`。
*   `csr_unit.sv`: 产生 `csr_write_enable/csr_addr/csr_wdata`，但不直接管理 pending state。
*   `p3_intra_group_arbiter.sv`: 决定 CSR 是否成为 Group 0 当前周期写回 winner。
*   `p4_commit_control.sv`: 根据 ROB head 和 tracker/pending 匹配情况产生 `p4_csr_retire/p4_csr_write`。
*   `backend_top.sv`: 串接上述 CSR 控制路径。

---

## 6. 典型生命周期

1.  P1 接纳 `CSRRW`，分配 ROB tag `T`，`csr_inflight_valid/tag` 置为 `1/T`。
2.  CSR 在 Group 0 发射执行，读取旧 CSR 值作为 GPR result。
3.  P3 写回 CSR result 到 ROB，同时将 `{T, csr_addr, csr_wdata}` 写入 `CSR_PEND_BUF`。
4.  P4 看到 ROB head 是 tag `T` 的 CSR，且 pending tag 匹配。
5.  P4 拉高 `p4_csr_write`，`csr_unit` 写架构 CSR 文件。
6.  P4 拉高 `p4_csr_retire`，`csr_control` 清 `inflight_v/pend_v`。
7.  下一周期 P1 才能接纳年轻指令。

只读 CSR 的生命周期类似，但第 3 步不分配 pending，第 5 步不写 CSR 文件，第 6 步仍然清 tracker。
