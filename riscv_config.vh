// Core configuration, shared by riscv.v and every stage file.

`ifndef RISCV_CONFIG_VH
`define RISCV_CONFIG_VH

`define CONFIG_PC_PREDICT // enables D -> F path (needed by RAS and GSHARE)
`define CONFIG_RAS        // return address stack
`define CONFIG_GSHARE     // gshare branch prediction (or BTFNT if not set)

//`define CONFIG_DEBUG      // debug mode, displays execution
                            // See "debugger" section in riscv.v
                            // to define breakpoints

//`define CONFIG_INITIALIZE // initialize register file and BHT table
                            // (required by Icarus/iverilog
                            // and by some synth tools)

`endif
