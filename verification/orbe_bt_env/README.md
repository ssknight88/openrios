# ORBE Backend Verification Environment

This directory contains the ORBE backend verification environment used for
mock-DUT self-checks and rtl_v1 COSIM debug.

## Layout

- `tb/` contains the SystemVerilog testbench, interfaces, agents, packages, and
  DUT wrappers.
- `dpi/` contains the project-owned ISA Model DPI package, C++ wrapper, API
  notes, and platform YAML.
- `cfg/filelist/` contains source lists for mock and rtl_v1 builds.
- `mk/` and `sim/` contain the VCS build and run flow.
- `tools/verilator_cosim.sh` builds and runs the same testbench with Verilator.
- `docs/` contains architecture and bring-up notes.
- `mock_tb/` contains the older standalone FE mock flow.

Generated simulation output should stay out of git:

```text
sim/verilator_*
sim/*/build
sim/*/log
sim/*/regress
*.log
*.fsdb
simv
obj_dir
```

## External Dependencies

This open-source package does not vendor the full ISA model checkout, ISA case
ELFs, prebuilt ISA model shared library, or rtl_v1 source tree. Point the
environment at local copies before building:

```bash
export ISA_MODEL_ROOT=<path-to-isa_model-checkout>
export ISA_API_INC=$ISA_MODEL_ROOT/src/libs
export ISA_API_LIB=$ISA_MODEL_ROOT/build
export ISA_CFG=$PWD/dpi/rivai_0x80000000_1core_rom.yaml
```

The ISA model checkout is expected to provide:

```text
$ISA_API_INC/IsaApi.h
$ISA_API_LIB/lib_ISA_api.so
$ISA_MODEL_ROOT/isa_case/
```

Build the ISA model shared library from that checkout before running COSIM:

```bash
cmake -S "$ISA_MODEL_ROOT" -B "$ISA_MODEL_ROOT/build" -G Ninja
cmake --build "$ISA_MODEL_ROOT/build" --target _ISA_api
```

The default rtl_v1 filelist assumes the real RTL tree is available at this
path, relative to `orbe_bt_env`:

```text
../rtl/rtl_v1
```

If your RTL lives elsewhere, create a symlink at that location or update
`cfg/filelist/rtl_v1.f` for your local tree.

## Entry Points

Use VCS through the Makefile:

```bash
cd verification/orbe_bt_env/sim

make build DUT_KIND=rtl_v1 COSIM_ENABLE=1

make run \
  DUT_KIND=rtl_v1 \
  TC=$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv \
  COSIM_ENABLE=1 \
  PLUSARGS='+VERBOSITY=2'
```

Use Verilator through the COSIM helper:

```bash
cd verification

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind rtl_v1 \
  --tag local

orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind rtl_v1 \
  --tag local \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv" \
  --timeout 200000 \
  --verbosity 2
```

The legacy top-level `run_verilator.sh` is kept only for old mock-flow users.
New COSIM work should use `tools/verilator_cosim.sh`.

## ISA Regression Scope

The current ORBE BE/COSIM regression target is the historical 216 ELF set from
these six `isa_case` directories:

```text
rv64ui: 104  rv64um: 26  rv64ua: 38
rv64uf:  22  rv64ud: 24  rv64uc:  2
```

This is intentionally not every `.riscv` file under `isa_case/`. Privileged,
vector, bitmanip, cache-block, and model-specific ELFs are outside this
acceptance set unless they are explicitly added later.

Check the canonical count:

```bash
find "$ISA_MODEL_ROOT/isa_case/rv64ui" \
     "$ISA_MODEL_ROOT/isa_case/rv64um" \
     "$ISA_MODEL_ROOT/isa_case/rv64ua" \
     "$ISA_MODEL_ROOT/isa_case/rv64uf" \
     "$ISA_MODEL_ROOT/isa_case/rv64ud" \
     "$ISA_MODEL_ROOT/isa_case/rv64uc" \
  -maxdepth 1 -type f -name '*.riscv' -print | sort | wc -l
```

The expected result is `216`.

## Runtime Logs

Verilator logs are written under:

```text
orbe_bt_env/sim/verilator_<TAG>/log/<DUT_KIND>/<elf-name>_<SEED>/
```

VCS logs are written under:

```text
orbe_bt_env/sim/<SYS>_<TAG>/log/<elf-name>_<SEED>/
```

Important files:

```text
sim.log          # testbench transcript and COSIM mismatch/fatal lines
isa_run.log      # shared BE-side ISA model run log
isa_commit.log   # shared BE-side ISA model commit log
```

Useful grep:

```bash
rg -i "\\[COSIM\\]|\\[BE\\]\\[COSIM\\]|MISMATCH|FATAL|%Error|Assertion failed|REPORTER_SUMMARY" \
  orbe_bt_env/sim/verilator_<TAG>/log/rtl_v1/<case>_<SEED>/sim.log
```

Find the newest log for one failed rtl_v1 case:

```bash
case_name=rv64ua-v-amoadd_d
log=$(find orbe_bt_env/sim -path "*/log/rtl_v1/${case_name}_*/sim.log" -print | sort | tail -1)
printf '%s\n' "$log"

rg -n -m 1 "\\[COSIM\\]|MISMATCH|%Error|Assertion failed|Fatal" "$log"
```

After the first failure line is found, inspect local context and correlate it
with the reference commit log:

```bash
line=$(rg -n -m 1 "\\[COSIM\\]|MISMATCH|%Error|Assertion failed|Fatal" "$log" | cut -d: -f1)
start=$((line > 20 ? line - 20 : 1))
end=$((line + 20))
sed -n "${start},${end}p" "$log"

commit_log=$(dirname "$log")/isa_commit.log
rg -n "<pc>|<inst>|<rd>" "$commit_log"
```

## Runtime Print Verbosity

The testbench reporter supports three print levels through the `VERBOSITY`
plusarg. Warnings, errors, fatals, and assertion failures are always printed;
`VERBOSITY` only controls normal diagnostic prints tagged as `[L1]`, `[L2]`, or
`[L3]`.

With the Verilator COSIM script, use `--verbosity <1|2|3>`:

```bash
orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind rtl_v1 \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ua/rv64ua-v-amoadd_d.riscv" \
  --timeout 2500000 \
  --verbosity 2
```

With the VCS Makefile flow, pass the raw plusarg through `PLUSARGS`:

```bash
make -C verification/orbe_bt_env/sim run \
  DUT_KIND=rtl_v1 \
  TC=$ISA_MODEL_ROOT/isa_case/rv64ua/rv64ua-v-amoadd_d.riscv \
  COSIM_ENABLE=1 \
  PLUSARGS='+VERBOSITY=2'
```

Level meaning:

```text
VERBOSITY=1
  Base progress only. Use it for quiet pass/fail regression logs.

VERBOSITY=2
  Normal debug: level 1 plus reference init/exit, BE decode/issue/commit,
  recovery, getter responses, cache done/flush, and COSIM progress prints.
  This is the recommended first setting for a failed rtl_v1 case.

VERBOSITY=3
  Verbose trace: level 1 and 2 plus detailed FE redirect/fetch notices,
  stale-event filtering, cache queue/wakeup/memory traffic, and COSIM
  architectural-state detail. Use it on one narrowed case because logs grow
  quickly.
```

## Failure Classification

COSIM uses the ISA model as the reference side and rtl_v1, or another DUT, as
the implementation side. Do not classify a mismatch as an RTL bug only from the
final mismatch line. Classify by the first divergence:

```text
rtl_v1 internal signal is correct, but rtl_v1_obs_probe/wrapper output is wrong
  => observation/probe/wrapper issue

observation output is correct, but be_agent/COSIM consumes a different event
  => ob_if/ob_cosim_if/be_agent sampling or ordering issue

COSIM event is correct, reference input/config is correct, and architectural
state still diverges at the first failing commit
  => rtl_v1 behavior issue
```

The mock DUT is used as the environment self-check. If `mock_rtl` runs the same
216-case COSIM regression through the mock observation path and all cases pass,
the common COSIM path is considered clean enough for rtl_v1 triage. A remaining
rtl_v1-only failure should then be debugged on the rtl_v1-private side first:
RTL behavior, `rtl_v1_obs_probe`, or `rtl_v1_wrapper`.

## Verilator rtl_v1 216-Case Regression

Build once, then run the canonical 216-case set with COSIM enabled:

```bash
cd verification

export REG_TAG=rtl_v1_216_$(date +%Y%m%d_%H%M%S)
export REG_ROOT=$PWD/orbe_bt_env/sim/verilator_$REG_TAG/regress/rtl_v1_216
mkdir -p "$REG_ROOT"

find "$ISA_MODEL_ROOT/isa_case/rv64ui" \
     "$ISA_MODEL_ROOT/isa_case/rv64um" \
     "$ISA_MODEL_ROOT/isa_case/rv64ua" \
     "$ISA_MODEL_ROOT/isa_case/rv64uf" \
     "$ISA_MODEL_ROOT/isa_case/rv64ud" \
     "$ISA_MODEL_ROOT/isa_case/rv64uc" \
  -maxdepth 1 -type f -name '*.riscv' -print | sort > "$REG_ROOT/all_216.list"

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind rtl_v1 \
  --tag "$REG_TAG"

while IFS= read -r elf; do
  rel="${elf#$ISA_MODEL_ROOT/}"
  if orbe_bt_env/tools/verilator_cosim.sh run \
      --no-build \
      --dut-kind rtl_v1 \
      --tag "$REG_TAG" \
      --tc "$elf" \
      --timeout 2000000 \
      --verbosity 2; then
    printf 'PASS %s\n' "$rel"
  else
    rc=$?
    printf 'FAIL rc=%d %s\n' "$rc" "$rel"
  fi
done < "$REG_ROOT/all_216.list" | tee "$REG_ROOT/results.txt"

awk '
  $1 == "PASS" { pass++ }
  $1 == "FAIL" { fail++ }
  END { printf "SUMMARY: PASS=%d FAIL=%d TOTAL=%d\n", pass + 0, fail + 0, NR }
' "$REG_ROOT/results.txt" | tee "$REG_ROOT/final_summary.txt"
```

If `rv64ui-p-add.riscv` has already passed as a smoke case and only the
remaining 215 cases should be run, create a reduced list before the loop:

```bash
grep -vxF "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv" \
  "$REG_ROOT/all_216.list" > "$REG_ROOT/remaining_215.list"

# Then replace the loop input with:
# done < "$REG_ROOT/remaining_215.list" | tee "$REG_ROOT/results.txt"
```

## Verilator Mock COSIM Self-Check

Use the mock flow to validate the common COSIM environment before classifying
rtl_v1 failures. The mock path drives the same `ob_if/ob_cosim_if`, BE agent,
DPI adapter, and reference model path as rtl_v1, but takes its observation
bundle from `mock_obs_probe`.

Build and run one smoke case:

```bash
cd verification

export MOCK_TAG=mock_cosim_$(date +%Y%m%d_%H%M%S)

orbe_bt_env/tools/verilator_cosim.sh build \
  --dut-kind mock \
  --tag "$MOCK_TAG"

orbe_bt_env/tools/verilator_cosim.sh run \
  --no-build \
  --dut-kind mock \
  --tag "$MOCK_TAG" \
  --tc "$ISA_MODEL_ROOT/isa_case/rv64ui/rv64ui-p-add.riscv" \
  --timeout 200000 \
  --verbosity 2
```

Run the 216-case mock COSIM self-check by using the same loop above with
`--dut-kind mock` and a separate tag:

```bash
export MOCK_TAG=mock_cosim_216_$(date +%Y%m%d_%H%M%S)
```

Expected result for a clean common environment:

```text
SUMMARY: PASS=216 FAIL=0 TOTAL=216
```
