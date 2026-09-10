#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""lint v3 · TEST_NEW（方案.md §4.2 五项 + 启发式缺口 + 卡↔Sail 反向落槽 + 卡↔UDB）

用法  python3 lint.py [--root DIR] [--sail MODEL_DIR] [--udb ISA_DIR] [--no-sail] [--no-udb] [-v]
退出码  0 = A 档无硬错误；1 = 有。B/C/D 只报不判。

A 卡内结构（硬错误）   键树 · 空列表项 · 枚举 · 图案 · 字段记法 · 裸引用闭合
B 卡内启发式（疑似缺口，标编号）
   ②⑥ 零语义卡 · ③ 状态名当 out · ⑬ out 与编码字段同名 / 重复 out · ⑱ 两条 op 相同 · ⑲ op 含 foreach
   ⑫ conditions 引用 calculate 的 out · ① 写回与自身异常并存 · ⑳ width 非 8/16/32/64 · 悬空 out（定义了没人用）
C 卡↔Sail 反向落槽   按卡头「Sail 定位」取子句原文，逐行去卡上找；找不到且不属四类噪音 → 未落槽（落槽表初稿）
D 卡↔UDB            encoding.match 逐位比 · RV32/RV64 分裂（⑦）· 文件缺失
"""
import argparse, collections, glob, io, os, re, sys
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
SKIP = ("decode.encoding.fields.", "memory.request.read.", "memory.request.modify.", "memory.request.write.", "update.next_pc.")
ENUM = {"operand": {"X", "F", "V", "imm", "csr"}, "reg": {"X", "F", "V", "csr"}, "mem": {"R", "W", "RMW", "LR", "SC"},
        "raise": {"Illegal_Instruction", "Virtual_Instruction"}, "retire": {"normal", "never"}}
STATE_NAMES = {"cur_privilege", "PC", "nextPC", "mstatus", "sstatus", "vsstatus", "hstatus", "fcsr", "satp", "hgatp", "mepc", "sepc"}
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_']*")
FIELD = re.compile(r"^\d+:s?\d+( \d+:\d+)*( <<\d+)?$")
LOC = re.compile(r"# Sail 定位（本地 803f192b 核对）：(\S+) execute\((.+?)\) L(\d+)–L(\d+)")
GAP_TAG = [(r"ExecuteAs\(|creg2reg_idx|cfregidx_to_fregidx", "⑭ 委托本体/压缩映射"), (r"Ext_(DataAddr|ControlAddr|CSR|XRET)|ext_(control_check_pc|data_get_addr|check_CSR|check_xret_priv)", "⑨ 扩展钩子路径"),
           (r"accrue_fflags|dirty_fd_context", "④ 条件写 CSR（函数内 if）"), (r"update_elp_state|zicfilp_", "⑧ 扩展钩子无槽"), (r"sail_barrier|flush_TLB|cancel_reservation|Enter_Wait", "②⑥ 序/事件"),
           (r"cur_privilege\s*=\s*", "③ 特权级切换"), (r"foreach|^var ", "⑲ 循环/可变量"), (r"^if .*then \{$|^\} else \{$|^else \{$|^else$", "⑥/④ if 骨架（分支体已落）"),
           (r"csr_(read|write)_callback|print_log|log_", "模拟器回调（待裁决）"), (r"if width <= xlen_bytes|X_pair|AMOCAS", "非本指令分支/宽度守卫（RV64 实例化）")]
NOISE = [(r"^\}[,;]?$|^\{$|^\)[,;]?$|^\};$", "括号"), (r"^function clause execute", "签名"), (r"RETIRE_SUCCESS|Retire_Success\(\)", "retire"),
         (r"^assert\(", "类型/断言"), (r"^Ok\(|^Err\(|^Err\(e\) => e|=> e,?$|failure => failure|^return Err|^\(Ok\(", "Ok/Err 包装"),
         (r"^match |^match\(|^Some\([^)]*\) => \{|^None\(\) => \(\)|=\s*match.*\{$|^\(rs1_lt_rs2, fflags\)|^let \(", "match 骨架"), (r"^\$\[|^let '", "类型/断言"),
         (r"^[A-Z][A-Z0-9_]+\s*=>", "非本指令分支"),
         (r"=\s*match.*\{$|^let \(|^\(rs1_lt_rs2, fflags\)", "match 骨架"),
         (r"^let (access|acc).*(Atomic|Load\(|Store\(|LoadReserved|StoreConditional|CacheAccess|LoadExecute)", "访问类型（memory.request.type 已落）"),
         (r"^let (loaded|result|vaddr|paddr|pbmt).*=\s*match (mem_read|get_transformed_data_addr|translateAddr|vmem_)", "访存管道骨架（memory.request 已落）"),
         (r"^if taken$|^then jump_to|^else RETIRE_SUCCESS", "分支骨架（next_pc.when 已落）")]

def tree(o, p=""):
    s = set()
    if isinstance(o, dict):
        for k, v in o.items():
            q = f"{p}.{k}" if p else str(k); s.add(q); s |= tree(v, q)
    return {x for x in s if not x.startswith(SKIP)}

def norm(s): return re.sub(r"\s+", "", str(s))

def card_exprs(d):
    """卡上所有语义表达式（原样字符串）"""
    ex = []
    for c in d["calculate"]: ex.append(str(c.get("op", "")))
    m = d["memory"]["request"]
    if m:
        for k in ("address", "write"):
            v = m.get(k); ex.append(str(v["out"]) if isinstance(v, dict) else str(v))
        if isinstance(m.get("modify"), dict): ex.append(str(m["modify"].get("op", "")))
    for r in d["update"]["regs"]: ex.append(str(r.get("value", "")))
    for c in d["update"]["csr"]: ex.append(str(c.get("value", "")))
    np_ = d["update"]["next_pc"]; ex.append(str(np_["target"]) if isinstance(np_, dict) else str(np_))
    for c in d["dynamic_check"]["conditions"]: ex.append(str(c.get("when", "")))
    for e in d["outcome"]["exceptions"]: ex.append(str(e.get("when", ""))); ex.append(str(e.get("tval", "")))
    if d["memory"]["va_constraint"]: ex.append(str(d["memory"]["va_constraint"]))
    return [e for e in ex if e and e not in ("None", "null", "seq", "always")]

# ---------------------------------------------------------------- A + B
def lint_card(path, d, tmpl_keys, raw):
    err, warn = [], []
    exp = set(tmpl_keys)
    if d["memory"]["request"] is None: exp = {k for k in exp if not k.startswith("memory.request.")}
    got = tree(d)
    if exp - got: err.append(f"键缺 {sorted(exp - got)}")
    if got - exp: err.append(f"键多 {sorted(got - exp)}")
    for sec, lstv in (("conditions", d["dynamic_check"]["conditions"]), ("calculate", d["calculate"]), ("exceptions", d["outcome"]["exceptions"]),
                      ("operands", d["operand_fetch"]["operands"]), ("regs", d["update"]["regs"]), ("csr", d["update"]["csr"]),
                      ("aliases", d["decode"]["aliases"]), ("overlap", d["decode"]["overlap"]), ("reserved", d["decode"]["reserved"])):
        if any(x is None for x in (lstv or [])): err.append(f"{sec} 有空列表项（注释被当成元素）")
    for o in d["operand_fetch"]["operands"]:
        if o.get("type") not in ENUM["operand"]: err.append(f"operands.type {o.get('type')!r} ∉ X|F|V|imm|csr")
    for r in d["update"]["regs"]:
        if r.get("type") not in ENUM["reg"]: err.append(f"regs.type {r.get('type')!r} ∉ X|F|V|csr")
    m = d["memory"]["request"]
    if m:
        if m.get("type") not in ENUM["mem"]: err.append(f"memory.request.type {m.get('type')!r} ∉ R|W|RMW|LR|SC")
        if m.get("width") not in (8, 16, 32, 64, 128): warn.append(f"⑳ memory.request.width = {m.get('width')!r} 非常规位宽（参数化粒度？）")
    for c in d["dynamic_check"]["conditions"]:
        if c.get("raise") not in ENUM["raise"]: err.append(f"conditions.raise {c.get('raise')!r} ∉ Illegal|Virtual")
    for e in d["outcome"]["exceptions"]:
        cs = e.get("cause"); cs = cs if isinstance(cs, list) else [cs]
        if any(str(x) in ENUM["raise"] for x in cs): err.append("exceptions.cause 写了 Illegal/Virtual —— 该归 dynamic_check（方案 §2.1 分界）")
        if not (("when" in e) ^ ("rule" in e)): err.append("exceptions 每条要且只要 when | rule 之一")
    if d["outcome"]["retire"] not in ENUM["retire"]: err.append(f"retire {d['outcome']['retire']!r}")
    pat = norm(d["decode"]["encoding"]["pattern"])
    if len(pat) not in (16, 32): err.append(f"pattern {len(pat)} 位")
    elif len(pat) == 16: warn.append("⑯ 16 位图案：编码格式.md 无压缩记法")
    if re.search(r"[^01.\-]", pat): err.append("pattern 含非法字符")
    fields = d["decode"]["encoding"]["fields"] or {}
    for k, v in fields.items():
        if not FIELD.match(str(v)): err.append(f"fields.{k} 记法 {v!r} 不合 位置:宽度")
    # ---- out 名：定义 / 引用 ----
    defined = collections.OrderedDict()
    for k in fields: defined[k] = "field"
    outs = [str(c.get("out")) for c in d["calculate"]]
    for o in outs:
        if o in fields: warn.append(f"⑬ out {o!r} 与编码字段同名（Sail let 遮蔽）")
        if o in defined and defined[o] == "out": warn.append(f"⑬ out {o!r} 重复定义")
        if o in STATE_NAMES: warn.append(f"③ out {o!r} 是架构状态名（对状态的赋值没槽，借 calculate 记）")
        defined[o] = "out"
    if m:
        for k in ("read", "modify"):
            v = m.get(k)
            if isinstance(v, dict) and v.get("out"): defined[str(v["out"])] = "out"
    ops = [str(c.get("op")) for c in d["calculate"]]
    dup = [o for o, n in collections.Counter(ops).items() if n > 1]
    for o in dup: warn.append(f"⑱ 两条 calculate 的 op 相同（元组 let 拆开）：{o[:50]}")
    if any("foreach" in o for o in ops): warn.append("⑲ op 含 foreach（循环无槽）")
    # 裸引用必须已定义
    def bare(v, where):
        if isinstance(v, str) and IDENT.fullmatch(v) and v not in ("seq", "null", "always", "zeros") and v not in defined and v not in STATE_NAMES:
            err.append(f"{where} 引用未定义的名字 {v!r}")
    if m:
        bare(m.get("address"), "memory.address")
        w = m.get("write")
        if isinstance(w, dict): bare(w.get("out"), "memory.write.out")
    for r in d["update"]["regs"]: bare(r.get("value"), "regs.value")
    np_ = d["update"]["next_pc"]
    bare(np_["target"] if isinstance(np_, dict) else np_, "next_pc")
    for e in d["outcome"]["exceptions"]: bare(e.get("tval"), "exceptions.tval")
    # 悬空 out：定义了、其它任何槽位都没引用（排除自身那条 op）
    own = {str(c.get("out")): str(c.get("op", "")) for c in d["calculate"]}
    allx = card_exprs(d) + [str(c.get("value", "")) for c in d["update"]["csr"]]
    for o in outs:
        others = [x for x in allx if x != own.get(o)]
        if not any(o in IDENT.findall(x) for x in others) and o not in STATE_NAMES:
            warn.append(f"悬空 out {o!r}：定义了没人引用（③ 的形状）")
    # ⑫ conditions 引用 calculate 的 out
    for c in d["dynamic_check"]["conditions"]:
        hit = set(IDENT.findall(str(c.get("when", "")))) & set(outs)
        if hit: warn.append(f"⑫ conditions.when 引用了 calculate 的 out {sorted(hit)}（依赖层次倒挂）")
    # ① 写回与自身异常并存
    if d["update"]["regs"] and any("when" in e and e.get("when") != "always" for e in d["outcome"]["exceptions"]):
        warn.append("① update.regs 与 outcome.exceptions[].when 并存：卡面顺序与 Sail 嵌套相反，靠原子性规则读")
    # ②⑥ 零语义
    if (not d["calculate"] and m is None and not d["update"]["regs"] and not d["update"]["csr"] and d["update"]["next_pc"] == "seq"
            and not d["outcome"]["exceptions"]):
        warn.append("②⑥ 零语义卡：七格全空、检查全过，语义在「序」侧" + ("（另有 conditions）" if d["dynamic_check"]["conditions"] else ""))
    declared = sorted(set(re.findall(r"填不进([①-㉑])", raw)))
    return err, warn, declared

# ---------------------------------------------------------------- C：卡↔Sail 反向
def sail_reverse(raw, d, sail_dir):
    mloc = LOC.search(raw)
    if not mloc: return None
    f, clause, a, b = mloc.group(1), mloc.group(2), int(mloc.group(3)), int(mloc.group(4))
    cands = [os.path.join(sail_dir, f), os.path.join(sail_dir, "extensions", f)]
    fp = next((c for c in cands if os.path.exists(c)), None)
    if not fp: return {"err": f"找不到 {f}"}
    lines = io.open(fp, encoding="utf-8").read().splitlines()[a - 1:b]
    exprs = [norm(e) for e in card_exprs(d)]
    exprs = [e for e in exprs if len(e) >= 4]
    landed, noise, gap = [], [], []
    for ln in lines:
        t = ln.split("//")[0].strip()
        if not t: continue
        core = re.sub(r"^(let|var)\s+[A-Za-z_'][A-Za-z0-9_']*\s*(:\s*[^=]+)?=\s*", "", t)
        core = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*\([^)]*\)\s*=\s*", "", core)   # X(rd) = …
        core = re.sub(r"^[A-Za-z_][A-Za-z0-9_\[\]]*\s*=\s*", "", core)         # mstatus[MIE] = …
        core = core.rstrip(";,").strip()
        nc = norm(core); nt = norm(t)
        hit = any((len(nc) >= 4 and (nc in e or e in nc)) or (len(nt) >= 6 and nt in e) for e in exprs)
        if not hit and re.search(r"Illegal_Instruction\(\)|Virtual_Instruction\(\)", t) and d["dynamic_check"]["conditions"]: hit = True   # raise 臂落到 conditions
        mcsr = re.match(r"^(?:then |else )?([a-z]+)\[([A-Z]+)\]\s*=", t)
        if not hit and mcsr and any(str(c.get("csr")) == mcsr.group(1) and str(c.get("field")) == mcsr.group(2) for c in d["update"]["csr"]): hit = True   # CSR 字段写落到 update.csr
        if not hit and re.search(r"F_or_X_[SDH]\(rd\)|F_[SDH]\(rd\)|X\(rd\)|F\(rd\)|X\(rsd\)|F\(rsd\)", t) and d["update"]["regs"]: hit = True   # 写回落到 regs
        if hit: landed.append(t); continue
        tag = next((k for rx, k in GAP_TAG if re.search(rx, t)), None)
        if tag: gap.append((t, tag)); continue
        kind = next((k for rx, k in NOISE if re.search(rx, t)), None)
        (noise if kind else gap).append((t, kind))
    return {"clause": clause, "file": f, "n": len(landed) + len(noise) + len(gap), "landed": landed, "noise": noise, "gap": gap}

# ---------------------------------------------------------------- D：卡↔UDB
def udb_check(key, d, udb_idx):
    p = udb_idx.get(key)
    if not p: return ["UDB 无同名文件"]
    u = yaml.safe_load(io.open(p, encoding="utf-8")); e = u["encoding"]; out = []
    if "match" not in e: out.append("⑦ UDB encoding 按 RV32/RV64 分两份"); e = e["RV64"]
    cp = norm(d["decode"]["encoding"]["pattern"]).replace(".", "-")
    if cp != e["match"]: out.append(f"pattern ≠ UDB match（卡 {cp} / UDB {e['match']}）")
    return out

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--root", default=HERE); ap.add_argument("--sail", default=os.path.join(HERE, "..", "..", "_golden", "sail-riscv", "model"))
    ap.add_argument("--udb", default=os.path.join(HERE, "..", "..", "_golden", "riscv-unified-db", "spec", "std", "isa")); ap.add_argument("--no-sail", action="store_true")
    ap.add_argument("--no-udb", action="store_true"); ap.add_argument("-v", action="store_true"); ap.add_argument("--gaps", action="store_true", help="列出每张卡未落槽的 Sail 行")
    A = ap.parse_args()
    tmpl = tree(yaml.safe_load(io.open(os.path.join(A.root, "card.template.v1.yaml"), encoding="utf-8")))
    udb_idx = {os.path.basename(p)[:-5]: p for p in glob.glob(os.path.join(A.udb, "inst", "*", "*.yaml"))} if not A.no_udb and os.path.isdir(A.udb) else {}
    paths = sorted(glob.glob(os.path.join(A.root, "cards", "**", "*.yaml"), recursive=True))
    nerr = 0; wc = collections.Counter(); sail_tot = [0, 0, 0]; gapc = collections.Counter(); declared_all = collections.Counter(); udb_c = collections.Counter()
    for p in paths:
        rel = os.path.relpath(p, A.root); raw = io.open(p, encoding="utf-8").read()
        try: d = yaml.safe_load(raw)
        except Exception as ex: print(f"BAD  {rel}: 解析失败 {ex}"); nerr += 1; continue
        err, warn, declared = lint_card(p, d, tmpl, raw)
        for w in warn: wc[w.split(" ")[0]] += 1
        for g in declared: declared_all[g] += 1
        sr = None if A.no_sail else sail_reverse(raw, d, A.sail)
        uc = udb_check(d["card"]["key"], d, udb_idx) if udb_idx else []
        for u in uc: udb_c[u.split("（")[0]] += 1
        if err: nerr += 1
        if err or A.v or (A.gaps and sr and sr.get("gap")):
            print(f"{'BAD ' if err else 'ok  '} {rel}")
            for e in err: print(f"       E {e}")
            if A.v:
                for w in warn: print(f"       W {w}")
                for u in uc: print(f"       U {u}")
            if sr and "err" not in sr:
                if A.v or A.gaps:
                    print(f"       S execute({sr['clause']}) {sr['n']} 行：落槽 {len(sr['landed'])} · 噪音 {len(sr['noise'])} · 未落槽 {len(sr['gap'])}")
                    for t, tag in sr["gap"]: print(f"         ✗ [{tag or '未分类'}] {t[:100]}")
        if sr and "err" not in sr:
            sail_tot[0] += len(sr["landed"]); sail_tot[1] += len(sr["noise"]); sail_tot[2] += len(sr["gap"])
            for t, tag in sr["gap"]:
                k = tag or ("未分类：" + re.sub(r"\(.*", "(", t)[:36]); gapc[k] += 1
    print(f"\n{len(paths)} 张 · A 档硬错误 {nerr} 张")
    print("B 档疑似缺口（张次）：", dict(wc.most_common()))
    print("卡上已声明的填不进：", dict(sorted(declared_all.items())))
    if not A.no_sail:
        n = sum(sail_tot) or 1; print(f"C 档 Sail 反向：{n} 行 = 落槽 {sail_tot[0]} · 噪音 {sail_tot[1]} · 未落槽 {sail_tot[2]}（落槽率 {(sail_tot[0] + sail_tot[1]) / n * 100:.1f}% 计噪音 / {sail_tot[0] / n * 100:.1f}% 不计）")
        print("  未落槽行按缺口标签 / 未分类开头：")
        for k, v in gapc.most_common(25): print(f"    {v:4d}  {k}")
    if udb_idx: print("D 档 UDB：", dict(udb_c))
    sys.exit(1 if nerr else 0)

if __name__ == "__main__":
    main()
