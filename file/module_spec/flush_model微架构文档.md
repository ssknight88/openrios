# flush_model · 纯组合 · flush 边界、恢复目标与广播

### ① per-entry state

**无。** 

### ② state transition & condition（event 名）

**无。**

### ③ condition 细化

**无。** 

### ④ data path

#### 1. `global_flush_late` / `redirect_valid` / `trap_state_write.valid`(output)

```text
flush_apply            = flush_valid                       // 输入 fire，本模块不重判
global_flush_late      = flush_apply
redirect_valid         = flush_apply
trap_state_write.valid = flush_apply ∧ (flush_kind != MISPREDICT)

flush_kind 编码：0 = MISPREDICT   1 = EXCEPTION   2 = MRET   3 = INTERRUPT
```

- **`global_flush_late` 由本模块唯一生成。** 上游只给 `flush_valid` / `flush_tag` /
  `flush_kind` 三个字段，不重复定义这条式子
- **不设别名**：不为任何消费者另起名字，实现时**只允许存在一个网络**
- `flush_apply == 0` 时本模块所有输出均为 0，不修改任何结构、也不产生重定向
- **四种 kind 都产生一个前端 redirect**；只有 MISPREDICT 不产生架构特权态更新

**`flush_tag` 不是回滚边界，只是读地址**：它按 kind 指向不同对象，
且在 MISPREDICT / MRET 下指向的是**本拍已退休**的那条。
边界语义完全由提交条数承担，**本模块不转发、也不另造任何落位目标值**。

#### 2. `cause` / `is_interrupt`(output)

驱动 `trap_vector` 读口的两个参数，`trap_state_write` 也用同一个 `cause`，故只选一次：

```text
cause        = (flush_kind == EXCEPTION) ? Buffer[flush_tag].exception_cause :
               (flush_kind == INTERRUPT) ? interrupt_cause : 0
is_interrupt = (flush_kind == INTERRUPT)
```

两者用的是 `trap_vector` **读口签名里的形参名**，不另起名——名字属于读口的拥有方。

#### 3. `redirect_kind` / `redirect_pc`(output)

只按 kind 选恢复数据，**不重新判断事件位**：

```text
redirect_valid = flush_apply
redirect_kind  = flush_kind
redirect_pc    = case (flush_kind)
    MISPREDICT: Buffer[flush_tag].mispredict_target_pc
    MRET      : mepc
    其余      : trap_vector(cause, is_interrupt)
  endcase
```

- `EXCEPTION` 时 `is_interrupt = 0`，故**不走 vectored 模式**；`INTERRUPT` 传 1，才可能走
- `MRET` 的恢复 PC 来自架构寄存器 `mepc`，**不从预测字段取值**

#### 4. `trap_state_write` 的 `kind` / `epc` / `cause` / `tval`(output)

```text
trap_state_write.valid = flush_apply ∧ (flush_kind != MISPREDICT)
trap_state_write.kind  = flush_kind
trap_state_write.epc   = PCFile[flush_tag].inst_pc
trap_state_write.cause = cause
trap_state_write.tval  = (flush_kind == EXCEPTION) ? Buffer[flush_tag].exception_tval : 0
```

- `PCFile[flush_tag].inst_pc` 就是异常 / 中断的 `trap_epc`。**本模块自己持有这个读口**，
  不经提交侧转手；也不修改被读的表
- `MRET` 只消费 `kind`，`epc` / `cause` / `tval` 三个字段虽在总线上有值，**对端不采样**

### ⑤ data structure（schema + 字段三角色）

**无 per-entry 存储。**

### ⑥ 接口

**in-event** `→ flush_model`

- flush（announce）
    - broadcast；`flush_kind`(2) —— 选恢复数据与是否更新架构态，不留存
    - 触发；`flush_valid`(1) —— 本拍要不要 flush
    - 地址；`flush_tag`(4) —— 两个恢复读口的下标

- 组合读(in)
    - broadcast；`Buffer[flush_tag].mispredict_target_pc`(64)、
      `Buffer[flush_tag].exception_cause`、`Buffer[flush_tag].exception_tval` —— **1 读口**
    - broadcast；`PCFile[flush_tag].inst_pc`(64) —— **1 读口**，作 `trap_epc`
    - broadcast；`mepc`(64)、`interrupt_cause` —— MRET 与 INTERRUPT 的恢复数据来源
    - broadcast；`trap_vector(cause, is_interrupt)`(64) —— 本模块驱动参数、对方组合返回

**out-event** `flush_model →`

- `global_flush_late`；`global_flush_late`(1)
- `redirect`；`redirect_valid`(1)、`redirect_pc`(64)、`redirect_kind`(2)
- `trap_state_write`；`valid`(1)、`kind`(2)、`epc`(64)、`cause`、`tval`
- 组合读(out)；`flush_tag`(4)
- 组合读(out)；`cause`、`is_interrupt`(1)


**Static Info**

无。
