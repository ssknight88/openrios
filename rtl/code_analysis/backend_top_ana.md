# backend_top.sv 娣卞害瑙ｆ瀽 (鍚庣鏋舵瀯涓灑)

`backend_top.sv` 鏄?Orca Backend 鐗╃悊瀹炵幇鐨勬渶椤跺眰妯″潡銆傚畠涓嶅寘鍚鏉傜殑绠楁湳閫昏緫锛岃€屾槸鎵紨鐫€**鈥滀富鏉库€?(Motherboard)** 鐨勮鑹诧紝璐熻矗灏?P1 鍒?P4 鐨勬墍鏈夋帶鍒舵ā鍧椼€佺姸鎬佽〃锛圧OB, ARF, DST_REG锛夈€侀槦鍒楋紙ISQ锛夊拰鎵ц鍗曞厓锛團U锛夋纭湴鐒婃帴鍦ㄤ竴璧枫€?

---

## 1. 椤跺眰鎺ュ彛杈圭晫 (External Interfaces)
*   **鍓嶇鎺ユ敹**: 鎺ユ敹鏉ヨ嚜 Frontend 鐨?`frontend_payload` (鏈€澶氬弻鍙?锛屽苟鍙嶉 `frontend_enqueue_cnt`銆?
*   **LSU (璁垮瓨) 杈圭晫**: 鏆撮湶浜?`lsu_req`, `lsu_busy`, `lsu_wb` 绛変俊鍙枫€傚湪鎴戜滑鐨勬祴璇曠幆澧冧腑锛屽畠鐢ㄤ簬瀵规帴澶栭儴鐨?`fake_lsu`锛涘湪鐪熷疄鑺墖涓紝瀹冨鎺?L1D Cache 鎺у埗鍣ㄣ€?
*   **CSR/涓柇 杈圭晫**: 鏆撮湶浜嗚鍐欐帶鍒剁姸鎬佸瘎瀛樺櫒鐨勪笓鐢ㄧ鍙ｏ紝浠ュ強澶勭悊澶栭儴涓柇 (`ext_irq_valid`) 鐨勫紩鑴氥€?
*   **鏋舵瀯鎭㈠ (Flush) 杈圭晫**: 鏆撮湶 `global_flush_late` 鍜?`flush_target_pc` 缁欏墠绔紝鐢ㄤ簬鍦ㄥ彂鐢熷紓甯告垨鍒嗘敮棰勬祴澶辫触鏃舵寚鎸ュ墠绔啿鍒峰苟璺宠浆銆?

---

## 2. 鏍稿績鍩虹璁炬柦瀹炰緥鍖?(Infrastructures)

### 2.1 Backend-owned ISB (鎸囦护娴佺紦鍐?
妯″潡寮€澶村疄鐜颁簡涓€涓繁搴︿负 8 (`ISB_DEPTH`) 鐨勬湰鍦板悓姝?FIFO銆?
*   **浣滅敤**锛氬惛鏀跺墠绔埌鍚庣鐨勫甫瀹芥姈鍔ㄣ€傚嵆浣?P1 闃舵鍥犱负姝婚攣棰勯槻鎴?ROB 婊¤€岄樆濉烇紙Stall锛夛紝杩欎釜 ISB 涔熻兘缁х画鍚炰笅鍑犳媿鍓嶇鍙戞潵鐨勬寚浠わ紝骞虫粦娴佹按绾挎皵娉°€?

### 2.2 鐘舵€佽拷韪〃
*   **`u_rob` & `u_sidearray`**: 瀹炰緥鍖栭噸鎺掑簭缂撳瓨锛岃拷韪?16 涓潯鐩殑鐢熷懡鍛ㄦ湡鍜屽紓甯稿厓鏁版嵁銆?
*   **`u_dst_int` & `u_dst_fp`**: 瀹炰緥鍖栫墿鐞嗛噸鍛藉悕鐘舵€佽〃锛岃拷韪?32 涓暣鏁板拰娴偣瀵勫瓨鍣ㄧ殑 busy 鐘舵€併€?
*   **`u_arf_int` & `u_arf_fp`**: 瀹炰緥鍖栫湡瀹炵殑鏋舵瀯瀵勫瓨鍣ㄥ爢銆?

### 2.3 鍙戝皠闃熷垪闃靛垪 (ISQs)
閫氳繃 `generate` 璇彞渚嬪寲浜?4 涓?`isq` 妯″潡锛屽垎鍒搴?G0~G3 鍥涗釜鎵ц缁勩€?

---

## 3. P1~P4 绾ц仈鎺у埗閫昏緫

`backend_top.sv` 灏嗗鏉傜殑涔卞簭鎺у埗娴佹媶鍒嗗埌浜嗕笓鐢ㄧ殑瀛愭ā鍧椾腑锛屽苟閫氳繃瀹芥€荤嚎杩炴帴锛?
1.  **P1 闃舵**锛氭寚浠や粠 ISB 寮瑰嚭锛屾祦缁?`p1_source_resolution`锛堟壘鎿嶄綔鏁帮級銆乣p1_admission_and_backpressure`锛堟煡璧勬簮锛夈€乣p1_deadlock_prevention`锛堥槻姝婚攣锛夛紝鏈€鍚庡湪 `p1_rob_allocation_and_isq_write` 钀芥埛鍏ュ簱銆?
2.  **P2 闃舵**锛歚p2_fu_input_mux` 浠?ISQ 鍜?Bypass 鎬荤嚎涓婃崬鍙栨渶鏂扮殑 64 浣嶆暟鎹紝骞跺皢鎿嶄綔鏁板杺缁欏叿浣撶殑鎵ц鍗曞厓銆傚湪 Group 0 涓紝鏅€氱殑绠楁湳鎸囦护鍜屽垎鏀寚浠ら兘浼氳璺敱缁欏悓涓€涓珮搴﹂泦鎴愮殑 `u_alu0` 鍗曞厓锛圲nified ALU & BRU锛夈€傚湪杩欓噷锛岀珛鍗虫暟锛坄imm_data`锛夊拰棰勬祴鐩稿叧鐨勫厓鏁版嵁涔熶細琚竴鍚屽杺鍏ワ紝瀹炵幇浜嗘墽琛屽崟鍏冨簳灞傜殑纭欢澶嶇敤銆?
3.  **P3 闃舵**锛歚p3_intra_group_arbiter` 鏀堕泦鍚岀粍鍐呭涓墽琛屽崟鍏冪殑缁撴灉锛岄€夊嚭浼樿儨鑰呭箍鎾埌 `bypass_bus` 涓婏紝骞跺啓鍥?ROB銆?
4.  **P4 闃舵**锛歚p4_commit_control` 绱х洴 ROB 澶撮儴锛屽喅瀹氭槸鍙戦€?`commit_ack` 璁╂寚浠ら€€褰癸紝杩樻槸鎷旈珮 `global_flush_late` 寮曞彂鏍稿脊绾у啿鍒枫€?

## 4. Flush priority on P3 bypass

`backend_top.sv` treats `global_flush_late` as the recovery boundary for P3 publication. Group winner payloads may still be present on local arbiter wires, but the exported bypass lane masks `valid` with `!global_flush_late`:

```systemverilog
bypass_bus[g].valid = group_wb_payload[g].result_valid && !global_flush_late;
```

This prevents P1 Condition A and P2 ISQ wakeup/select from observing a same-cycle killed producer as a real forwarding event. ROB, ROB sidearray, and CSR pending state also give the flush clear/reset path priority over same-cycle P3 writes.

The important timing point is that `global_flush_late` itself comes from the P4 commit arbiter, so the masking happens in the same cycle the flush is selected. The state arrays may clear on the following clock edge, but the visibility boundary is already closed by the combinational `valid` mask.
