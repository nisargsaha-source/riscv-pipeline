# riscv-pipeline

A 5-stage pipelined RV32I processor in Verilog, with operand forwarding, hazard detection and branch prediction. It is plain Verilog with no vendor IP, and simulates in Verilator and Icarus Verilog.

## Pipeline

| Stage | File | Does |
|---|---|---|
| F | `riscv_fetch.v` | PC selection, instruction fetch from program ROM |
| D | `riscv_decode.v` | Decode, immediates, branch prediction (GSHARE + return address stack) |
| E | `riscv_execute.v` | ALU, branch/JALR resolution, M→E and W→E forwarding |
| M | `riscv_memory.v` | Data RAM, memory-mapped IO, `cycle`/`instret` CSRs, W→M forwarding |
| W | `riscv_writeback.v` | Register file |

`riscv.v` is the top level (module `riscv`). It connects the stages and holds the stall/flush logic. Each stage module owns the pipeline register at its output (`FD_*`, `DE_*`, `EM_*`, `MW_*`).

### Hazard handling

- **Forwarding.** Results are forwarded from M and from W into E for both source operands. Store data is also forwarded from W into M.
- **Load-use.** An instruction that uses a load (or CSR read) result right after it gets one bubble. The exception is a store whose *data* comes from the load: it needs no stall, because the W→M path supplies the data in time.
- **Load after store.** A load right after a store gets one bubble, since data RAM reads start in E while writes happen in M.
- **Control.** D predicts JAL targets, branch directions and JALR return addresses, so a correct prediction costs nothing. Branches and JALR are resolved in E; a misprediction flushes D and F and costs 2 cycles.

### Configuration

`riscv_config.vh` sets the options for every file:

| Define | Effect |
|---|---|
| `CONFIG_PC_PREDICT` | Enables prediction in D. Without it every taken branch or jump costs 2 cycles, and the two options below do nothing. |
| `CONFIG_GSHARE` | GSHARE branch predictor (4096 two-bit counters, 9-bit global history). Without it: backwards-taken / forwards-not-taken. |
| `CONFIG_RAS` | 4-entry return address stack for predicting JALR returns. |
| `CONFIG_INITIALIZE` | Zeroes the register file and initialises the branch predictor table at start-up. Use it in simulation (see below). |
| `CONFIG_DEBUG` | With `BENCH`, prints the pipeline state every cycle (uses `riscv_disassembly.v`). |

## Supported instructions

RV32I integer instructions: register and immediate ALU operations, `lui`, `auipc`, `jal`, `jalr`, all branches, byte/half/word loads and stores, plus `csrrs` reads of `cycle`, `cycleh`, `instret` and `instreth`. `ebreak` halts the pipeline. There are no exceptions or interrupts, and misaligned accesses are not supported.

## Memory map

- **Program ROM:** 32 words, initialised in `riscv_fetch.v` (currently a 4-instruction test program).
- **Data RAM:** 32 words.
- **IO:** any address with bit 22 set (`0x00400000`) goes to the `IO_mem_*` ports. IO accesses are word-only (see below).

## Simulating

**Verilator (lint):**
```
verilator --lint-only -Wno-WIDTHTRUNC --top-module riscv riscv_fetch.v riscv_decode.v riscv_execute.v riscv_memory.v riscv_writeback.v riscv.v
```
`-Wno-WIDTHTRUNC` hides warnings that come from indexing the 32-word memories with full-width address fields; they go away if the memories are enlarged.

**Icarus Verilog, with the per-cycle pipeline trace** (needs a small testbench that drives `clk` and `resetn`):
```
iverilog -g2012 -DBENCH -DCONFIG_DEBUG -DCONFIG_INITIALIZE -o sim.vvp your_tb.v riscv_fetch.v riscv_decode.v riscv_execute.v riscv_memory.v riscv_writeback.v riscv.v
vvp sim.vvp
```

## Known limitations

- `x0` is not hard-wired: it reads 0 only because the register file starts at 0, as FPGA memories usually do. In simulation define `CONFIG_INITIALIZE`, or `x0` reads as X.
- IO is word-only. A byte or halfword load from IO returns the full 32-bit word, and a byte or halfword store to IO writes the whole register.
- The LUI/AUIPC decode signals in `riscv_decode.v` are wrong, so LUI and AUIPC are treated as reading `rs1`. This only causes occasional extra stall cycles, never wrong results.
- The ROM and RAM are only 32 words each.

## Credits

The core is based on the pipelined RISC-V design and tutorial in Bruno Levy's [learn-fpga](https://github.com/BrunoLevy/learn-fpga) project. This version splits it into one module per pipeline stage and reworks the forwarding and hazard logic. `riscv_disassembly.v` comes from the same project. learn-fpga is released under the BSD 3-Clause License, included here as [`LICENSE-learn-fpga`](LICENSE-learn-fpga).
