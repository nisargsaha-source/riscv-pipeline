`include "riscv_config.vh"
`default_nettype none

/******************************************************************************/

                     /*** E: Execute ***/

module riscv_execute (
   input  wire        clk,

   // D/E pipeline register
   input  wire        DE_nop,
   input  wire [4:0]  DE_rdId,
   input  wire [4:0]  DE_rs1Id,
   input  wire [4:0]  DE_rs2Id,
   input  wire [1:0]  DE_csrId,
   input  wire [2:0]  DE_funct3,
   input  wire [7:0]  DE_funct3_is,
   input  wire [5:5]  DE_funct7,
   input  wire [31:0] DE_IorSimm,
   input  wire        DE_isALUreg,
   input  wire        DE_isBranch,
   input  wire        DE_isJALR,
   input  wire        DE_isJAL,
   input  wire        DE_isLoad,
   input  wire        DE_isStore,
   input  wire        DE_isCSRRS,
   input  wire        DE_wbEnable,
   input  wire        DE_isJALorJALRorLUIorAUIPC,
   input  wire [31:0] DE_PCplus4orUimm,
`ifdef CONFIG_PC_PREDICT
   input  wire [31:0] DE_PCplus4orBimm,
   input  wire        DE_predictBranch,
 `ifdef CONFIG_RAS
   input  wire [31:0] DE_predictRA,
 `endif
`else
   input  wire [31:0] DE_PCplusBorJimm,
`endif

   // Register file read data (W stage, addressed by DE_rs1Id / DE_rs2Id)
   input  wire [31:0] RF_rs1,
   input  wire [31:0] RF_rs2,

   // Forwarding source from W (the M source is this stage's own EM register)
   input  wire        MW_wbEnable,
   input  wire [4:0]  MW_rdId,
   input  wire [31:0] wbData,

   output wire        E_correctPC,   // to hazard logic (flushes D and E)
   output wire        E_takeBranch,  // to D (branch predictor training)
   output wire [31:0] E_addr,        // to M (data RAM read address)

   // E/M pipeline register
   output reg         EM_nop,        // Needed by instret in W stage
   output reg  [4:0]  EM_rdId,
   output reg  [4:0]  EM_rs2Id,
   (* onehot *)
   output reg  [3:0]  EM_csrId_is,
   output reg  [2:0]  EM_funct3,
   output reg  [31:0] EM_rs2,
   output reg  [31:0] EM_Eresult,
   output reg  [31:0] EM_addr,
   output reg         EM_isStore,
   output reg         EM_isLoad,
   output reg         EM_isCSRRS,
   output reg         EM_wbEnable,
   output reg         EM_correctPC,
   output reg  [31:0] EM_PCcorrection
);

   /*********** Registrer forwarding ************************************/

   wire E_M_fwd_rs1 = EM_wbEnable && (EM_rdId == DE_rs1Id);
   wire E_W_fwd_rs1 = MW_wbEnable && (MW_rdId == DE_rs1Id);

   wire E_M_fwd_rs2 = EM_wbEnable && (EM_rdId == DE_rs2Id);
   wire E_W_fwd_rs2 = MW_wbEnable && (MW_rdId == DE_rs2Id);

   wire [31:0] E_rs1 = E_M_fwd_rs1 ? EM_Eresult :
	               E_W_fwd_rs1 ? wbData     :
	                             RF_rs1     ;

   wire [31:0] E_rs2 = E_M_fwd_rs2 ? EM_Eresult :
	               E_W_fwd_rs2 ? wbData     :
	                             RF_rs2     ;

   /*********** the ALU *************************************************/

   wire [31:0] E_aluIn1 = E_rs1;
   wire [31:0] E_aluIn2 = (DE_isALUreg | DE_isBranch) ? E_rs2 : DE_IorSimm;
   wire [4:0]  E_shamt  = DE_isALUreg ? E_rs2[4:0] : DE_rs2Id;

   wire E_minus = DE_funct7[5] & DE_isALUreg;
   wire E_arith_shift = DE_funct7[5];

   // The adder is used by both arithmetic instructions and JALR.
   wire [31:0] E_aluPlus = E_aluIn1 + E_aluIn2;

   // Use a single 33 bits subtract to do subtraction and all comparisons
   // (trick borrowed from swapforth/J1)
   wire [32:0] E_aluMinus = {1'b1, ~E_aluIn2} + {1'b0,E_aluIn1} + 33'b1;
   wire        E_LT  =
                 (E_aluIn1[31] ^ E_aluIn2[31]) ? E_aluIn1[31] : E_aluMinus[32];
   wire        E_LTU = E_aluMinus[32];
   wire        E_EQ  = (E_aluMinus[31:0] == 0);

   // Flip a 32 bit word. Used by the shifter (a single shifter for
   // left and right shifts, saves silicium !)
   function [31:0] flip32;
      input [31:0] x;
      flip32 = {x[ 0], x[ 1], x[ 2], x[ 3], x[ 4], x[ 5], x[ 6], x[ 7],
		x[ 8], x[ 9], x[10], x[11], x[12], x[13], x[14], x[15],
		x[16], x[17], x[18], x[19], x[20], x[21], x[22], x[23],
		x[24], x[25], x[26], x[27], x[28], x[29], x[30], x[31]};
   endfunction

   wire [31:0] E_shifter_in = (DE_funct3==3'b001) ? flip32(E_aluIn1) : E_aluIn1;

   /* verilator lint_off WIDTH */
   wire [31:0] E_shifter =
       $signed({E_arith_shift & E_aluIn1[31], E_shifter_in}) >>> E_aluIn2[4:0];
   /* verilator lint_on WIDTH */

   wire [31:0] E_leftshift = flip32(E_shifter);

   wire [31:0] E_aluOut =
	(DE_funct3_is[0] ? (E_minus ? E_aluMinus[31:0] : E_aluPlus) : 32'b0) |
	(DE_funct3_is[1] ? E_leftshift                              : 32'b0) |
	(DE_funct3_is[2] ? {31'b0, E_LT }                           : 32'b0) |
	(DE_funct3_is[3] ? {31'b0, E_LTU}                           : 32'b0) |
	(DE_funct3_is[4] ? E_aluIn1 ^ E_aluIn2                      : 32'b0) |
	(DE_funct3_is[5] ? E_shifter                                : 32'b0) |
	(DE_funct3_is[6] ? E_aluIn1 | E_aluIn2                      : 32'b0) |
	(DE_funct3_is[7] ? E_aluIn1 & E_aluIn2                      : 32'b0) ;

   /*********** Branch, JAL, JALR ***********************************/

   assign E_takeBranch =
        (DE_funct3_is[0] &  E_EQ ) | // BEQ
        (DE_funct3_is[1] & !E_EQ ) | // BNE
        (DE_funct3_is[4] &  E_LT ) | // BLT
        (DE_funct3_is[5] & !E_LT ) | // BGE
        (DE_funct3_is[6] &  E_LTU) | // BLTU
        (DE_funct3_is[7] & !E_LTU) ; // BGEU

   wire [31:0] E_JALRaddr = {E_aluPlus[31:1],1'b0};

`ifdef CONFIG_PC_PREDICT
 `ifdef CONFIG_RAS
   assign E_correctPC = (
	   (DE_isJALR    && (DE_predictRA != E_JALRaddr)   ) ||
           (DE_isBranch  && (E_takeBranch^DE_predictBranch))
   );
 `else
   assign E_correctPC = DE_isJALR ||
	(DE_isBranch  && (E_takeBranch^DE_predictBranch));
 `endif
   wire [31:0] E_PCcorrection = DE_isBranch ? DE_PCplus4orBimm : E_JALRaddr;
`else
   assign E_correctPC = (
			   DE_isJAL || DE_isJALR ||
			  (DE_isBranch && E_takeBranch)
			 );
   wire [31:0] E_PCcorrection =
	       DE_isJALR ? E_JALRaddr : DE_PCplusBorJimm;
`endif

   wire [31:0] E_result =
	       DE_isJALorJALRorLUIorAUIPC ? DE_PCplus4orUimm : E_aluOut;

   assign E_addr = E_rs1 + DE_IorSimm;

   /**************************************************************/

   always @(posedge clk) begin

	 EM_nop      <= DE_nop;
	 EM_rdId     <= DE_rdId;
	 EM_rs2Id    <= DE_rs2Id;
	 EM_funct3   <= DE_funct3;
	 EM_csrId_is <= 4'b0001 << DE_csrId;
	 EM_rs2      <= E_rs2;
	 EM_Eresult  <= E_result;
	 EM_addr     <= E_addr;
	 EM_isLoad   <= DE_isLoad;
	 EM_isStore  <= DE_isStore;
	 EM_isCSRRS  <= DE_isCSRRS;
	 EM_wbEnable <= DE_wbEnable && (DE_rdId != 0);
	 EM_correctPC  <= E_correctPC;
	 EM_PCcorrection <= E_PCcorrection;

   end

endmodule

`default_nettype wire
