`include "riscv_config.vh"
`default_nettype none

/******************************************************************************/

                      /***  F: Instruction fetch ***/

module riscv_fetch (
   input  wire        clk,
   input  wire        resetn,

   input  wire        F_stall,         // hold PC and FD (load-use hazard, halt)
   input  wire        D_flush,         // squash the instruction being fetched

   input  wire        D_predictPC,     // D -> F: predicted branch/jump target
   input  wire [31:0] D_PCprediction,  //   (tied to 0 without CONFIG_PC_PREDICT)
   input  wire        EM_correctPC,    // E -> F (registered): misprediction
   input  wire [31:0] EM_PCcorrection,

   output reg  [31:0] FD_PC,
   output reg  [31:0] FD_instr,
   output reg         FD_nop           // Needed because I cannot directly write
                                       // NOP to FD_instr because FD_instr is
                                       // plugged to PROGROM's output port.
);

   reg  [31:0] PC;

   reg [31:0] PROGROM[0:31]; // 32 4-bytes words
                                // 16 Kb of program ROM
//   initial begin
//      $readmemh("PROGROM.hex",PROGROM);
//   end

   integer k;
   initial begin
      for (k = 0; k < 32; k = k + 1) PROGROM[k] = 32'h00000013; // NOP (addi x0,x0,0)

      // Small test program:
      PROGROM[0] = 32'h00500093; // addi x1, x0, 5
      PROGROM[1] = 32'h00700113; // addi x2, x0, 7
      PROGROM[2] = 32'h002081B3; // add  x3, x1, x2
      PROGROM[3] = 32'h00100073; // ebreak
   end

   wire [31:0] F_PC =
	       D_predictPC  ? D_PCprediction  :
	       EM_correctPC ? EM_PCcorrection :
	                      PC;

   wire [31:0] F_PCplus4 = F_PC + 4;

   always @(posedge clk) begin

      if(!F_stall) begin
	 FD_instr <= PROGROM[F_PC[15:2]];
	 FD_PC    <= F_PC;
	 PC       <= F_PCplus4;
      end

      FD_nop <= D_flush | !resetn;

      if(!resetn) begin
	 PC <= 0;
      end

   end

endmodule

`default_nettype wire
