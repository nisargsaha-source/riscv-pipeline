`include "riscv_config.vh"
`default_nettype none

/*** D: Instruction decode ***/

// Also holds the branch predictor (GSHARE BHT + RAS). The BHT is read here
// and trained by the branch in E, using E_takeBranch and the D/E register.

module riscv_decode (
   input  wire        clk,

   input  wire [31:0] FD_PC,
   input  wire [31:0] FD_instr,
   input  wire        FD_nop,

   input  wire        D_stall,
   input  wire        D_flush,
   input  wire        E_flush,
   input  wire        E_takeBranch,  // E -> D: outcome of the branch in E

   // to hazard detection (top)
   output wire [4:0]  D_rs1Id,
   output wire [4:0]  D_rs2Id,
   output wire        D_readsRs1,
   output wire        D_readsRs2,
   output wire        D_isLoad,
   output wire        D_isStore,

   // D -> F
   output wire        D_predictPC,
   output wire [31:0] D_PCprediction,

   // D/E pipeline register
   output reg         DE_nop,        // Needed by instret in W stage
   output reg  [4:0]  DE_rdId,
   output reg  [4:0]  DE_rs1Id,
   output reg  [4:0]  DE_rs2Id,
   output reg  [1:0]  DE_csrId,
   output reg  [2:0]  DE_funct3,
   (* onehot *)
   output reg  [7:0]  DE_funct3_is,
   output reg  [5:5]  DE_funct7,
   output reg  [31:0] DE_IorSimm,
   output reg         DE_isALUreg,
   output reg         DE_isBranch,
   output reg         DE_isJALR,
   output reg         DE_isJAL,
   output reg         DE_isLoad,
   output reg         DE_isStore,
   output reg         DE_isCSRRS,
   output reg         DE_isEBREAK,
   output reg         DE_wbEnable,   // !isBranch && !isStore && rdId != 0
   output reg         DE_isJALorJALRorLUIorAUIPC,
   output reg  [31:0] DE_PCplus4orUimm
`ifdef CONFIG_PC_PREDICT
  ,output reg  [31:0] DE_PCplus4orBimm,
   output reg         DE_predictBranch
 `ifdef CONFIG_RAS
  ,output reg  [31:0] DE_predictRA
 `endif
`else
  ,output reg  [31:0] DE_PCplusBorJimm
`endif
);

`ifdef CONFIG_INITIALIZE
   // Iteration variable for the "initial" blocks
   integer i;
`endif

   assign D_rs1Id = FD_instr[19:15];
   assign D_rs2Id = FD_instr[24:20];
   wire [4:0]  D_rdId  = FD_instr[11:7];

   // commented-out codeop recognizers are optimized below
// wire D_isJAL    = (FD_instr[6:2]==5'b11011);
// wire D_isJALR   = (FD_instr[6:2]==5'b11001);
// wire D_isAUIPC  = (FD_instr[6:2]==5'b00101);
// wire D_isLUI    = (FD_instr[6:2]==5'b01101);
// wire D_isBranch = (FD_instr[6:2]==5'b11000);
   wire D_isALUreg = (FD_instr[6:2]==5'b01100);
   wire D_isALUimm = (FD_instr[6:2]==5'b00100);
   assign D_isLoad = (FD_instr[6:2]==5'b00000);
   assign D_isStore= (FD_instr[6:2]==5'b01000);
   wire D_isSYSTEM = (FD_instr[6:2]==5'b11100);

   // optimized codop recognizers
   wire D_isJAL    = FD_instr[3];
   wire D_isJALR   = {FD_instr[6], FD_instr[3], FD_instr[2]} == 3'b101;
   wire D_isLUI    = FD_instr[6:4] == 3'b111;
   wire D_isAUIPC  = FD_instr[6:4] == 3'b101;
   wire D_isBranch = {FD_instr[6], FD_instr[4], FD_instr[2]} == 3'b100;


   wire D_isJALorJALR  = (FD_instr[2] & FD_instr[6]);
   wire D_isLUIorAUIPC = (FD_instr[4] & FD_instr[6]);


   assign D_readsRs1 = !(D_isJAL || D_isLUIorAUIPC);

   assign D_readsRs2 = (FD_instr[5] && (FD_instr[3:2] == 2'b00));
                  // <=> D_isALUreg || D_isBranch || D_isStore || D_isSYSTEM

   wire [31:0] D_Uimm = { FD_instr[31],FD_instr[30:12], {12{1'b0}}};

   wire [31:0] D_Bimm = {{20{FD_instr[31]}},
                         FD_instr[7],FD_instr[30:25],FD_instr[11:8],1'b0};

   wire [31:0] D_Jimm = {{12{FD_instr[31]}},
                         FD_instr[19:12],FD_instr[20],FD_instr[30:21],1'b0};

   // Not used by the later stages, kept as in the single-file version.
   reg DE_isALUimm;
   reg DE_isAUIPC;
   reg DE_isLUI;

`ifdef CONFIG_PC_PREDICT
 `ifdef CONFIG_GSHARE
   localparam BP_HISTO_BITS=9;
   localparam BP_ADDR_BITS=12;

   localparam BHT_INDEX_BITS=BP_ADDR_BITS;
   localparam BHT_SIZE=1<<BHT_INDEX_BITS;

   // global history
   reg [BP_HISTO_BITS-1:0] branch_history;

   // branch history table (2 bits per entry)
   reg [1:0] BHT[BHT_SIZE-1:0];

   reg [BHT_INDEX_BITS-1:0] DE_BHTindex;

`ifdef CONFIG_INITIALIZE
   initial begin
      branch_history = 0;
      for(i=0; i<BHT_SIZE; i=i+1) begin
	 BHT[i] = 2'b01; // all entries of BHT initialized as "weakly taken"
      end
   end
`endif

   // gets the index in the branch prediction table
   // from the PC
   function [BHT_INDEX_BITS-1:0] BHT_index;
      input [31:0] PC;
   /* verilator lint_off WIDTH */
      BHT_index = PC[BP_ADDR_BITS+1:2] ^
                  (branch_history << (BP_ADDR_BITS - BP_HISTO_BITS));
   /* verilator lint_on WIDTH */
   endfunction

   wire D_predictBranch = BHT[BHT_index(FD_PC)][1];

   function [1:0] incdec_sat;
      input [1:0] prev;
      input dir;
      incdec_sat =
 	   {dir, prev} == 3'b000 ? 2'b00 :
           {dir, prev} == 3'b001 ? 2'b00 :
	   {dir, prev} == 3'b010 ? 2'b01 :
	   {dir, prev} == 3'b011 ? 2'b10 :
	   {dir, prev} == 3'b100 ? 2'b01 :
	   {dir, prev} == 3'b101 ? 2'b10 :
	   {dir, prev} == 3'b110 ? 2'b11 :
	                           2'b11 ;
   endfunction

 `else
   // No GSHARE branch predictor,
   // use BTFNT (Backwards taken forwards not taken)
   // I[31]=Bimm sgn (pred bkwd branch taken)
   wire D_predictBranch = FD_instr[31];
 `endif

 `ifdef CONFIG_RAS
   // code below is equivalent (in this context) to:
   // wire D_predictPC = !FD_nop && (
   //   D_isJAL || D_isJALR || (D_isBranch && D_predictBranch)
   // );
   // JAL:    11011
   // JALR:   11001
   // Branch: 11000
   // The three start by 110, and it is the only ones
   assign D_predictPC = !FD_nop &&
	 (FD_instr[6:4] == 3'b110) && (FD_instr[2] | D_predictBranch);

   // Return address stack

   reg [31:0] RAS_0;
   reg [31:0] RAS_1;
   reg [31:0] RAS_2;
   reg [31:0] RAS_3;

   assign D_PCprediction =
                /* D_isJALR */ FD_instr[3:2] == 2'b01 ? RAS_0 :
	        (FD_PC + (D_isJAL ? D_Jimm : D_Bimm));

 `else // !`ifdef CONFIG_RAS
   assign D_predictPC = !FD_nop && (D_isJAL || (D_isBranch && D_predictBranch));
   assign D_PCprediction = (FD_PC + (D_isJAL ? D_Jimm : D_Bimm));
 `endif
`else // !`ifdef CONFIG_PC_PREDICT
   assign D_predictPC    = 1'b0;
   assign D_PCprediction = 32'b0;
`endif // `CONFIG_PC_PREDICT

   always @(posedge clk) begin


      if(!D_stall) begin

	 DE_rdId  <= D_rdId;
	 DE_rs1Id <= D_rs1Id;
	 DE_rs2Id <= D_rs2Id;

	 DE_funct3    <= FD_instr[14:12];
	 DE_funct3_is <= 8'b00000001 << FD_instr[14:12];
	 DE_funct7    <= FD_instr[30];
	 DE_csrId     <= {FD_instr[27],FD_instr[21]};

	 DE_nop <= 1'b0;


	 DE_isALUreg <= D_isALUreg;
	 DE_isALUimm <= D_isALUimm;
	 DE_isBranch <= D_isBranch;
	 DE_isJALR   <= D_isJALR;
	 DE_isJAL    <= D_isJAL;
	 DE_isAUIPC  <= D_isAUIPC;
	 DE_isLUI    <= D_isLUI;
	 DE_isLoad   <= D_isLoad;
	 DE_isStore  <= D_isStore;
	 DE_isCSRRS  <= D_isSYSTEM &&  FD_instr[13];
	 DE_isEBREAK <= D_isSYSTEM && !FD_instr[13];

	 // wbEnable = !isBranch & !isStore
	 // Note: EM_wbEnable = DE_wbEnable && (rdId != 0)
	 DE_wbEnable <= (FD_instr[5:2]  != 4'b1000);

	 DE_IorSimm <= {
			{21{FD_instr[31]}},
			D_isStore ? {FD_instr[30:25],FD_instr[11:7]} :
			             FD_instr[30:20]
			};

`ifdef CONFIG_PC_PREDICT
	 // Used in case of misprediction:
	 //    PC+Bimm if predict not taken, PC+4 if predict taken
	 DE_PCplus4orBimm <= FD_PC + (D_predictBranch ? 4 : D_Bimm);
	 DE_predictBranch <= D_predictBranch;
 `ifdef CONFIG_GSHARE
	 DE_BHTindex  <= BHT_index(FD_PC);
 `endif
 `ifdef CONFIG_RAS
	 DE_predictRA <= RAS_0;
	 if(!FD_nop && !D_flush) begin
	    if(D_isJAL && D_rdId==1) begin
	       RAS_3 <= RAS_2;
	       RAS_2 <= RAS_1;
	       RAS_1 <= RAS_0;
	       RAS_0 <= FD_PC + 4;
	    end
	    if(D_isJALR && D_rdId==0 && (D_rs1Id == 1 || D_rs1Id==5)) begin
	       RAS_0 <= RAS_1;
	       RAS_1 <= RAS_2;
	       RAS_2 <= RAS_3;
	    end
	 end
 `endif
`else
	 DE_PCplusBorJimm <= FD_PC + (D_isJAL ? D_Jimm : D_Bimm);
`endif

	 // Code below is equivalent to:
	 // DE_PCplus4orUimm =
	 //    ((isLUI ? 0 : FD_PC)) + ((isJAL | isJALR) ? 4 : Uimm)
	 // (knowing that isLUI | isAUIPC | isJAL | isJALR)
	 DE_PCplus4orUimm <= ({32{FD_instr[6:5]!=2'b01}} & FD_PC) +
                             (D_isJALorJALR ? 4 : D_Uimm);

	 DE_isJALorJALRorLUIorAUIPC <= FD_instr[2];
      end

      if(E_flush | FD_nop) begin
	 DE_nop      <= 1'b1;
	 DE_isALUreg <= 1'b0;
	 DE_isALUimm <= 1'b0;
	 DE_isBranch <= 1'b0;
	 DE_isJALR   <= 1'b0;
	 DE_isJAL    <= 1'b0;
	 DE_isAUIPC  <= 1'b0;
	 DE_isLUI    <= 1'b0;
	 DE_isLoad   <= 1'b0;
	 DE_isStore  <= 1'b0;
	 DE_isCSRRS  <= 1'b0;
	 DE_isEBREAK <= 1'b0;
	 DE_wbEnable <= 1'b0;
	 DE_isJALorJALRorLUIorAUIPC <= 1'b0;
      end

   end

`ifdef CONFIG_PC_PREDICT
 `ifdef CONFIG_GSHARE
   // Branch predictor training. DE_isBranch / DE_BHTindex describe the
   // instruction currently in E, whose outcome is E_takeBranch.
   always @(posedge clk) begin
      if(DE_isBranch) begin
	 branch_history <= {E_takeBranch,branch_history[BP_HISTO_BITS-1:1]};
	 BHT[DE_BHTindex] <= incdec_sat(BHT[DE_BHTindex], E_takeBranch);
      end
   end
 `endif
`endif

endmodule

`default_nettype wire
