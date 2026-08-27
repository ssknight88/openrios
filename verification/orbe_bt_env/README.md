# OR BE BT Mock Testbench

This repository carries only the trimmed mock testbench:

- `tb/`
- `run_verilator.sh`
- `README.md`

It does not include the full ISA model source tree, DPI source, shared libraries,
or ISA case binaries. Those files are taken from a separate ISA model checkout.

## ISA Model Dependency

Use the compatible ISA model branch:

```sh
git clone <isa_model_repo_url> isa_model
cd isa_model
git checkout feature/general-dev
git checkout 6c408b82b969
```

The commit pin above records the version used when this package was prepared.
If the branch has moved, prefer the pinned commit unless you intentionally want
to test a newer ISA model version.

Build the ISA model shared library:

```sh
cmake -S . -B build -G Ninja
cmake --build build --target _ISA_api
```

After build, the checkout is expected to provide:

```text
<isa_model>/src/libs/IsaApi.h
<isa_model>/build/lib_ISA_api.so
<isa_model>/dpi/isa_dpi_pkg.sv
<isa_model>/dpi/isa_dpi_wrapper.cc
<isa_model>/dpi/rivai_0x80000000_1core_rom.yaml
<isa_model>/isa_case/
```

## Run

Build the Verilator simulation:

```sh
ISA_MODEL_INSTALL=/abs/path/to/isa_model BUILD_ONLY=1 ./run_verilator.sh
```

Run one ISA case:

```sh
ISA_MODEL_INSTALL=/abs/path/to/isa_model \
ISA_ELF=/abs/path/to/isa_model/isa_case/rv64ui/rv64ui-p-add.riscv \
./run_verilator.sh
```

Run the 216-case batch:

```sh
ISA_MODEL_INSTALL=/abs/path/to/isa_model ./run_verilator.sh --all
```

## Scope

The included `tb/` is the current mock testbench subset. It intentionally omits
the legacy cosim agent and P600/RRV64-specific interfaces from the full internal
tree. Do not compile by globbing every SV file from the full ISA model tree.
