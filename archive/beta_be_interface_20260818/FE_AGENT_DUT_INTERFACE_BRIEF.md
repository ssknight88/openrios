# FE Agent - DUT FE 驱动与采样时序

本文只描述 FE 接口的信号驱动、信号采样和时序规则，不展开验证环境实现细节。

## 1. 周期边界

FE 交互以 posedge 为驱动边界，并在该边沿后的组合稳定窗口采样 ready：

1. **`clk` posedge：驱动阶段。** 驱动当前待发送的 valid 和 instruction payload。
2. **`clk` 边沿后稳定窗口：采样阶段。** 采样 DUT 的 ready；`valid && ready` 的 lane 在本周期被接受。
3. **下一 posedge：** 按未接受 entry 的原程序顺序重新排列并驱动下一组。

payload 在两个 posedge 之间保持不变；未被接受的 entry 不被新指令覆盖。

## 2. FE Agent -> DUT 驱动规则

| 信号 | 驱动边沿 | 驱动规则 |
| --- | --- | --- |
| `fe_be_instr_vld_d[lane]` | `clk` posedge | 驱动当前待发送 entry 的 valid；最多同时驱动 4 个 lane。redirect 或停止状态时全 0。|
| `fe_be_instr_info_d[lane]` | `clk` posedge | 与对应 valid 同拍驱动 instruction payload；有效 lane 按程序顺序排列，空 lane payload 置 0。|
| `fe_be_instr_excp_d` | `clk` posedge | 当前驱动为 0，不发送 instruction-fetch exception。|
| `fe_be_valid[lane]`、`fe_be_pld[lane]` | `clk` posedge | 当前驱动为 0；不参与有效 FE dispatch。|

## 3. DUT -> FE Agent 采样规则

| 信号 | 采样时刻 | 采样/处理规则 |
| --- | --- | --- |
| `fe_be_ready[lane]` | posedge 后组合稳定窗口 | 仅当该 lane 的 valid=1 且 ready=1 时，entry 才被接受；ready=0 的 entry 保留并在下一 posedge 重发。|
| `be_fe_redirect_valid` | posedge | 为 1 时优先于普通 dispatch；当前待发送 group 立即作废。|
| `be_fe_redirect_pc` | 与 redirect valid 同一 posedge | redirect valid=1 时采样目标 PC；下一 posedge 从该 PC 开始驱动新 group。|

以下信号当前不参与 FE 驱动/采样时序：`be_idle`、`be_fe_redirect_type`、`be_fe_redirect_bp_info`、
`csr_resolved`、`fence_resolved`、`be_resolve_bp_update*`、`be_commit_bp_update*`。

## 4. 正常 dispatch 时序

1. 在当前 posedge，驱动一组 `fe_be_instr_vld_d` 和 `fe_be_instr_info_d`。
2. 在该边沿后的组合稳定窗口读取 `fe_be_ready`。
3. 对每个 lane 独立计算 `valid && ready`；握手成功的 entry 从当前组移除。
4. 未握手的 entry 保持原程序顺序，压缩到低 lane；新 entry 只补到队尾。
5. 压缩和补充结果在下一 posedge 才作为新 group 驱动，当前周期不重新改写接口。

## 5. Redirect 时序

1. 若 posedge 采到 `be_fe_redirect_valid=1`，该边沿不执行普通 dispatch 的压缩和补充。
2. 当前所有 `fe_be_instr_vld_d` 立即驱动为 0，当前 group 全部作废。
3. 保存 `be_fe_redirect_pc`，下一 posedge 从该 target PC 重新驱动 valid 和 instruction payload。
4. 若 redirect 连续到达，最新 target 覆盖尚未生效的旧 target。

## 6. Reset 和停止规则

| 条件 | FE 输出规则 |
| --- | --- |
| reset active | `fe_be_instr_vld_d`、`fe_be_instr_info_d`、`fe_be_instr_excp_d` 以及 legacy 通道全部驱动为 0。|
| instruction stream end | 不再产生新的 valid；已发出的 entry 仍按正常 ready 规则完成。|
| 外部停止条件 | 下一驱动边沿清零 FE 输出，不再产生新 dispatch。|

## 7. 使用的 Payload 字段

当前有效 dispatch payload 为 `fe_be_instr_info_d`；以下列出其实际交互字段。其他 FE payload 在当前
接口时序中不参与有效数据传输。

### 7.1 `fe_be_instr_info_d` (`fe_be_info_t[lane]`)

| 字段 | 接口用途 |
| --- | --- |
| `pc` | 当前指令的虚拟 PC。|
| `instr` | 送入 DUT 的 32-bit 指令编码。|
| `is_rvc` | 表示原始指令是否为压缩指令，并影响顺序 PC 步长。|
| `ct_type` | 控制转移类型字段；当前驱动为 `BP_NO_BR`。|
| `l0_hit` | L0 预测命中字段；当前驱动为 0。|
| `l1_hit` | L1 预测命中字段；当前驱动为 0。|
| `cpf_id` | 预测流/CPF 标识字段；当前驱动为 0。|
| `pred_npc` | 预测下一 PC；当前按顺序下一条指令地址驱动。|
| `pred_taken` | taken 预测字段；当前驱动为 0。|
| `excp_vld` | 指示该指令是否带异常；当前驱动为 0。|
