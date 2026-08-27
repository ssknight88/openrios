#!/usr/bin/env bash
set -euo pipefail

ISA_MODEL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OBJ_DIR=${OBJ_DIR:-$ISA_MODEL_ROOT/obj_dir_be_tb}
SIM_EXE=$OBJ_DIR/be_tb_top

if [[ -z ${ISA_MODEL_INSTALL:-} ]]; then
  shopt -s nullglob
  isa_model_install_candidates=(
    "$ISA_MODEL_ROOT"/third_party/isa_model/isa_model_install_*
  )
  shopt -u nullglob
  if [[ ${#isa_model_install_candidates[@]} -gt 0 ]]; then
    ISA_MODEL_INSTALL=${isa_model_install_candidates[${#isa_model_install_candidates[@]} - 1]}
  else
    ISA_MODEL_INSTALL=$ISA_MODEL_ROOT
  fi
fi

if [[ -r "$ISA_MODEL_INSTALL/include/IsaApi.h" ]]; then
  ISA_DPI_DIR=${ISA_DPI_DIR:-$ISA_MODEL_INSTALL/dpi}
  ISA_INCLUDE_DIR=${ISA_INCLUDE_DIR:-$ISA_MODEL_INSTALL/include}
  ISA_LIB_DIR=${ISA_LIB_DIR:-$ISA_MODEL_INSTALL/lib}
elif [[ -r "$ISA_MODEL_INSTALL/src/libs/IsaApi.h" ]]; then
  ISA_DPI_DIR=${ISA_DPI_DIR:-$ISA_MODEL_INSTALL/dpi}
  ISA_INCLUDE_DIR=${ISA_INCLUDE_DIR:-$ISA_MODEL_INSTALL/src/libs}
  ISA_LIB_DIR=${ISA_LIB_DIR:-$ISA_MODEL_INSTALL/build}
else
  ISA_DPI_DIR=${ISA_DPI_DIR:-$ISA_MODEL_ROOT/dpi}
  ISA_INCLUDE_DIR=${ISA_INCLUDE_DIR:-$ISA_MODEL_ROOT/src/libs}
  ISA_LIB_DIR=${ISA_LIB_DIR:-$ISA_MODEL_ROOT/build}
fi

ISA_CFG=${ISA_CFG:-$ISA_DPI_DIR/rivai_0x80000000_1core_rom.yaml}

RUN_ALL=${RUN_ALL:-0}
if [[ ${1:-} == "--all" ]]; then
  RUN_ALL=1
  shift
elif [[ ${1:-} == "--help" || ${1:-} == "-h" ]]; then
  cat <<'USAGE'
Usage:
  ISA_ELF=path/to/test.riscv ./run_verilator.sh [verilator plusargs]
  ./run_verilator.sh --all [verilator plusargs]
  RUN_ALL=1 ./run_verilator.sh [verilator plusargs]

Batch mode runs the plan_v2.2 ISA cases under rv64ui/rv64um/rv64ua/rv64uf/rv64ud/rv64uc.
If this repository does not carry isa_case, batch mode uses $ISA_MODEL_INSTALL/isa_case.
USAGE
  exit 0
fi
EXTRA_ARGS=("$@")

required_files=(
  "$ISA_DPI_DIR/isa_dpi_pkg.sv"
  "$ISA_DPI_DIR/isa_dpi_wrapper.cc"
  "$ISA_INCLUDE_DIR/IsaApi.h"
  "$ISA_LIB_DIR/lib_ISA_api.so"
  "$ISA_CFG"
)
for required_file in "${required_files[@]}"; do
  [[ -r "$required_file" ]] || {
    echo "missing or unreadable ISA model dependency: $required_file" >&2
    echo "Set ISA_MODEL_INSTALL to an ISA model install prefix or full checkout." >&2
    exit 2
  }
done

sources=(
  "$ISA_DPI_DIR/isa_dpi_pkg.sv"
  "$ISA_MODEL_ROOT/tb/modified_agents/cache/exe_subop_pkg.sv"
  "$ISA_MODEL_ROOT/tb/modified_agents/cache/or_be_lsu_protocol_pkg.sv"
  "$ISA_MODEL_ROOT/tb/modified_agents/cache/lsu_if.sv"
  "$ISA_MODEL_ROOT/tb/pkg/mock_rtl_pkg.sv"
  "$ISA_MODEL_ROOT/tb/modified_agents/fe/orbe_fe_if.sv"

  "$ISA_MODEL_ROOT/tb/interfaces/ob_if.sv"
  "$ISA_MODEL_ROOT/tb/interfaces/getter_if.sv"
  "$ISA_MODEL_ROOT/tb/pkg/be_tb_pkg.sv"
  "$ISA_MODEL_ROOT/tb/top/mock_rtl.sv"
  "$ISA_MODEL_ROOT/tb/top/be_tb_top.sv"
)

if [[ ${REBUILD:-0} == 1 || ! -x "$SIM_EXE" ]]; then
  verilator -Wno-fatal --binary --timing --top-module be_tb_top \
    -I"$ISA_MODEL_ROOT/tb/pkg" \
    -I"$ISA_MODEL_ROOT/tb/interfaces" \
    "${sources[@]}" \
    "$ISA_DPI_DIR/isa_dpi_wrapper.cc" \
    -CFLAGS "-I$ISA_INCLUDE_DIR" \
    -LDFLAGS "-L$ISA_LIB_DIR -Wl,-rpath,$ISA_LIB_DIR -l_ISA_api" \
    --Mdir "$OBJ_DIR" -o be_tb_top
fi

if [[ ${BUILD_ONLY:-0} == 1 ]]; then
  exit 0
fi

SIM_TIMEOUT_CYCLES=${SIM_TIMEOUT_CYCLES:-2000000}
VERBOSITY=${VERBOSITY:-1}

run_one_case() {
  local elf=$1
  local log_file=$2
  local rc

  if LD_LIBRARY_PATH="$ISA_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$SIM_EXE" \
    "+ISA_CFG=$ISA_CFG" \
    "+ISA_ELF=$elf" \
    "+SIM_TIMEOUT_CYCLES=$SIM_TIMEOUT_CYCLES" \
    "+VERBOSITY=$VERBOSITY" \
    "${EXTRA_ARGS[@]}" >"$log_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

if [[ $RUN_ALL == 1 ]]; then
  if [[ -n ${ISA_ELF:-} ]]; then
    echo "do not set ISA_ELF together with --all/RUN_ALL=1" >&2
    exit 2
  fi

  if [[ -z ${ISA_CASE_ROOT:-} ]]; then
    if [[ -d "$ISA_MODEL_ROOT/isa_case" ]]; then
      ISA_CASE_ROOT=$ISA_MODEL_ROOT/isa_case
    elif [[ -d "$ISA_MODEL_INSTALL/isa_case" ]]; then
      ISA_CASE_ROOT=$ISA_MODEL_INSTALL/isa_case
    else
      ISA_CASE_ROOT=$ISA_MODEL_ROOT/isa_case
    fi
  fi
  ISA_CASE_DIRS=${ISA_CASE_DIRS:-"rv64ui rv64um rv64ua rv64uf rv64ud rv64uc"}
  EXPECTED_CASE_COUNT=${EXPECTED_CASE_COUNT:-216}
  LOG_DIR=${LOG_DIR:-${TMPDIR:-/tmp}/isa_model_verilator_logs}
  mkdir -p "$LOG_DIR"

  read -r -a case_dirs <<< "$ISA_CASE_DIRS"
  cases=()
  for case_dir in "${case_dirs[@]}"; do
    case_path=$ISA_CASE_ROOT/$case_dir
    [[ -d "$case_path" ]] || {
      echo "missing ISA case directory: $case_path" >&2
      exit 2
    }
    while IFS= read -r case_elf; do
      cases+=("$case_elf")
    done < <(find "$case_path" -maxdepth 1 -type f -name '*.riscv' -print | sort)
  done

  total=${#cases[@]}
  if [[ $total -ne $EXPECTED_CASE_COUNT ]]; then
    echo "expected $EXPECTED_CASE_COUNT ISA cases, found $total" >&2
    echo "set EXPECTED_CASE_COUNT=$total only when intentionally using a different case set" >&2
    exit 2
  fi

  pass_count=0
  fail_count=0
  failed_cases=()
  case_index=0
  for elf in "${cases[@]}"; do
    case_index=$((case_index + 1))
    case_name=${elf#"$ISA_CASE_ROOT"/}
    log_name=${case_name//\//__}
    log_file=$LOG_DIR/$log_name.log
    if run_one_case "$elf" "$log_file"; then
      pass_count=$((pass_count + 1))
      printf '[PASS] %3d/%d %s\n' "$case_index" "$total" "$case_name"
    else
      rc=$?
      fail_count=$((fail_count + 1))
      failed_cases+=("$case_name")
      printf '[FAIL] %3d/%d %s (rc=%d, log=%s)\n' \
        "$case_index" "$total" "$case_name" "$rc" "$log_file"
    fi
  done

  printf 'SUMMARY: PASS=%d FAIL=%d TOTAL=%d\n' "$pass_count" "$fail_count" "$total"
  if [[ $fail_count -ne 0 ]]; then
    printf 'FAILED CASES:\n'
    printf '  %s\n' "${failed_cases[@]}"
    exit 1
  fi
  exit 0
fi

: "${ISA_ELF:?usage: ISA_ELF=path/to/test.riscv ./run_verilator.sh (or ./run_verilator.sh --all)}"
[[ -r "$ISA_ELF" ]] || { echo "missing or unreadable ELF: $ISA_ELF" >&2; exit 2; }
LD_LIBRARY_PATH="$ISA_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
  "$SIM_EXE" \
  "+ISA_CFG=$ISA_CFG" \
  "+ISA_ELF=$ISA_ELF" \
  "+SIM_TIMEOUT_CYCLES=$SIM_TIMEOUT_CYCLES" \
  "+VERBOSITY=$VERBOSITY" \
  "${EXTRA_ARGS[@]}"
