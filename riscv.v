`include "riscv_config.vh"
`default_nettype none

/******************************************************************************/

// 5-stage pipelined RV32I core: top level.
//
//   riscv_fetch.v     F  PC, program ROM               -> FD_ registers
//   riscv_decode.v    D  decode, branch prediction     -> DE_ registers
//   riscv_execute.v   E  ALU, branches, M/W->E fwd     -> EM_ registers
//   riscv_memory.v    M  data RAM, IO, CSRs, W->M fwd  -> MW_ registers
//   riscv_writeback.v W  register file
//
// This file wires the stages together and holds the hazard detection
// (stall / flush) logic, which needs signals from several stages.

module riscv (
    input  wire        clk,
    input  wire        resetn,
    output wire [31:0] IO_mem_addr,  // IO memory address
    input  wire [31:0] IO_mem_rdata, // data read from IO memory
    output wire [31:0] IO_mem_wdata, // data written to IO memory
    output wire        IO_mem_wr     // IO write flag
);

`ifdef BENCH
`include "riscv_disassembly.v"
`endif

/******************************************************************************/

 /*
   Reminder for the 10 RISC-V codeops
   ----------------------------------
   5'b01100 | ALUreg  | rd <- rs1 OP rs2
   5'b00100 | ALUimm  | rd <- rs1 OP Iimm
   5'b11000 | Branch  | if(rs1 OP rs2) PC<-PC+Bimm
   5'b11001 | JALR    | rd <- PC+4; PC<-rs1+Iimm
   5'b11011 | JAL     | rd <- PC+4; PC<-PC+Jimm
   5'b00101 | AUIPC   | rd <- PC + Uimm
   5'b01101 | LUI     | rd <- Uimm
   5'b00000 | Load    | rd <- mem[rs1+Iimm]
   5'b01000 | Store   | mem[rs1+Simm] <- rs2
   5'b11100 | SYSTEM  | special
 */

/******************************************************************************/

   wire F_stall;

   wire D_stall;
   wire D_flush;

   wire E_flush;

   wire halt; // Halt execution (on ebreak)

   // F -> D
   wire [31:0] FD_PC;
   wire [31:0] FD_instr;
   wire        FD_nop;

   // D -> F
   wire        D_predictPC;
   wire [31:0] D_PCprediction;

   // D -> hazard detection
   wire [4:0]  D_rs1Id;
   wire [4:0]  D_rs2Id;
   wire        D_readsRs1;
   wire        D_readsRs2;
   wire        D_isLoad;
   wire        D_isStore;

   // D -> E
   wire        DE_nop;
   wire [4:0]  DE_rdId;
   wire [4:0]  DE_rs1Id;
   wire [4:0]  DE_rs2Id;
   wire [1:0]  DE_csrId;
   wire [2:0]  DE_funct3;
   wire [7:0]  DE_funct3_is;
   wire [5:5]  DE_funct7;
   wire [31:0] DE_IorSimm;
   wire        DE_isALUreg;
   wire        DE_isBranch;
   wire        DE_isJALR;
   wire        DE_isJAL;
   wire        DE_isLoad;
   wire        DE_isStore;
   wire        DE_isCSRRS;
   wire        DE_isEBREAK;
   wire        DE_wbEnable;
   wire        DE_isJALorJALRorLUIorAUIPC;
   wire [31:0] DE_PCplus4orUimm;
`ifdef CONFIG_PC_PREDICT
   wire [31:0] DE_PCplus4orBimm;
   wire        DE_predictBranch;
 `ifdef CONFIG_RAS
   wire [31:0] DE_predictRA;
 `endif
`else
   wire [31:0] DE_PCplusBorJimm;
`endif

   // E -> F / D / hazard detection / M
   wire        E_correctPC;
   wire        E_takeBranch;
   wire [31:0] E_addr;

   // E -> M (and F for the PC correction)
   wire        EM_nop;
   wire [4:0]  EM_rdId;
   wire [4:0]  EM_rs2Id;
   wire [3:0]  EM_csrId_is;
   wire [2:0]  EM_funct3;
   wire [31:0] EM_rs2;
   wire [31:0] EM_Eresult;
   wire [31:0] EM_addr;
   wire        EM_isStore;
   wire        EM_isLoad;
   wire        EM_isCSRRS;
   wire        EM_wbEnable;
   wire        EM_correctPC;
   wire [31:0] EM_PCcorrection;

   // M -> W (and E for forwarding)
   wire        MW_nop;
   wire [4:0]  MW_rdId;
   wire [31:0] MW_wbData;
   wire        MW_wbEnable;

   // W -> E
   wire        wbEnable;
   wire [31:0] wbData;
   wire [4:0]  wbRdId;
   wire [31:0] RF_rs1;
   wire [31:0] RF_rs2;

/******************************************************************************/

   riscv_fetch fetch (
      .clk(clk),
      .resetn(resetn),
      .F_stall(F_stall),
      .D_flush(D_flush),
      .D_predictPC(D_predictPC),
      .D_PCprediction(D_PCprediction),
      .EM_correctPC(EM_correctPC),
      .EM_PCcorrection(EM_PCcorrection),
      .FD_PC(FD_PC),
      .FD_instr(FD_instr),
      .FD_nop(FD_nop)
   );

   riscv_decode decode (
      .clk(clk),
      .FD_PC(FD_PC),
      .FD_instr(FD_instr),
      .FD_nop(FD_nop),
      .D_stall(D_stall),
      .D_flush(D_flush),
      .E_flush(E_flush),
      .E_takeBranch(E_takeBranch),
      .D_rs1Id(D_rs1Id),
      .D_rs2Id(D_rs2Id),
      .D_readsRs1(D_readsRs1),
      .D_readsRs2(D_readsRs2),
      .D_isLoad(D_isLoad),
      .D_isStore(D_isStore),
      .D_predictPC(D_predictPC),
      .D_PCprediction(D_PCprediction),
      .DE_nop(DE_nop),
      .DE_rdId(DE_rdId),
      .DE_rs1Id(DE_rs1Id),
      .DE_rs2Id(DE_rs2Id),
      .DE_csrId(DE_csrId),
      .DE_funct3(DE_funct3),
      .DE_funct3_is(DE_funct3_is),
      .DE_funct7(DE_funct7),
      .DE_IorSimm(DE_IorSimm),
      .DE_isALUreg(DE_isALUreg),
      .DE_isBranch(DE_isBranch),
      .DE_isJALR(DE_isJALR),
      .DE_isJAL(DE_isJAL),
      .DE_isLoad(DE_isLoad),
      .DE_isStore(DE_isStore),
      .DE_isCSRRS(DE_isCSRRS),
      .DE_isEBREAK(DE_isEBREAK),
      .DE_wbEnable(DE_wbEnable),
      .DE_isJALorJALRorLUIorAUIPC(DE_isJALorJALRorLUIorAUIPC),
      .DE_PCplus4orUimm(DE_PCplus4orUimm)
`ifdef CONFIG_PC_PREDICT
     ,.DE_PCplus4orBimm(DE_PCplus4orBimm),
      .DE_predictBranch(DE_predictBranch)
 `ifdef CONFIG_RAS
     ,.DE_predictRA(DE_predictRA)
 `endif
`else
     ,.DE_PCplusBorJimm(DE_PCplusBorJimm)
`endif
   );

   riscv_execute execute (
      .clk(clk),
      .DE_nop(DE_nop),
      .DE_rdId(DE_rdId),
      .DE_rs1Id(DE_rs1Id),
      .DE_rs2Id(DE_rs2Id),
      .DE_csrId(DE_csrId),
      .DE_funct3(DE_funct3),
      .DE_funct3_is(DE_funct3_is),
      .DE_funct7(DE_funct7),
      .DE_IorSimm(DE_IorSimm),
      .DE_isALUreg(DE_isALUreg),
      .DE_isBranch(DE_isBranch),
      .DE_isJALR(DE_isJALR),
      .DE_isJAL(DE_isJAL),
      .DE_isLoad(DE_isLoad),
      .DE_isStore(DE_isStore),
      .DE_isCSRRS(DE_isCSRRS),
      .DE_wbEnable(DE_wbEnable),
      .DE_isJALorJALRorLUIorAUIPC(DE_isJALorJALRorLUIorAUIPC),
      .DE_PCplus4orUimm(DE_PCplus4orUimm),
`ifdef CONFIG_PC_PREDICT
      .DE_PCplus4orBimm(DE_PCplus4orBimm),
      .DE_predictBranch(DE_predictBranch),
 `ifdef CONFIG_RAS
      .DE_predictRA(DE_predictRA),
 `endif
`else
      .DE_PCplusBorJimm(DE_PCplusBorJimm),
`endif
      .RF_rs1(RF_rs1),
      .RF_rs2(RF_rs2),
      .MW_wbEnable(MW_wbEnable),
      .MW_rdId(MW_rdId),
      .wbData(wbData),
      .E_correctPC(E_correctPC),
      .E_takeBranch(E_takeBranch),
      .E_addr(E_addr),
      .EM_nop(EM_nop),
      .EM_rdId(EM_rdId),
      .EM_rs2Id(EM_rs2Id),
      .EM_csrId_is(EM_csrId_is),
      .EM_funct3(EM_funct3),
      .EM_rs2(EM_rs2),
      .EM_Eresult(EM_Eresult),
      .EM_addr(EM_addr),
      .EM_isStore(EM_isStore),
      .EM_isLoad(EM_isLoad),
      .EM_isCSRRS(EM_isCSRRS),
      .EM_wbEnable(EM_wbEnable),
      .EM_correctPC(EM_correctPC),
      .EM_PCcorrection(EM_PCcorrection)
   );

   riscv_memory memory (
      .clk(clk),
      .resetn(resetn),
      .E_addr(E_addr),
      .EM_nop(EM_nop),
      .EM_rdId(EM_rdId),
      .EM_rs2Id(EM_rs2Id),
      .EM_csrId_is(EM_csrId_is),
      .EM_funct3(EM_funct3),
      .EM_rs2(EM_rs2),
      .EM_Eresult(EM_Eresult),
      .EM_addr(EM_addr),
      .EM_isStore(EM_isStore),
      .EM_isLoad(EM_isLoad),
      .EM_isCSRRS(EM_isCSRRS),
      .EM_wbEnable(EM_wbEnable),
      .IO_mem_addr(IO_mem_addr),
      .IO_mem_rdata(IO_mem_rdata),
      .IO_mem_wdata(IO_mem_wdata),
      .IO_mem_wr(IO_mem_wr),
      .MW_nop(MW_nop),
      .MW_rdId(MW_rdId),
      .MW_wbData(MW_wbData),
      .MW_wbEnable(MW_wbEnable)
   );

   riscv_writeback writeback (
      .clk(clk),
      .MW_wbEnable(MW_wbEnable),
      .MW_rdId(MW_rdId),
      .MW_wbData(MW_wbData),
      .rs1Id(DE_rs1Id),
      .rs2Id(DE_rs2Id),
      .rs1Data(RF_rs1),
      .rs2Data(RF_rs2),
      .wbEnable(wbEnable),
      .wbData(wbData),
      .wbRdId(wbRdId)
   );

/******************************************************************************/

                     /*** Hazard detection ***/

   assign halt = resetn & DE_isEBREAK;

   // we do not test rdId == 0 because in general, one loads data to
   // a register, not to zero !
   wire rs1Hazard = D_readsRs1 && (D_rs1Id == DE_rdId);
   wire rs2Hazard = D_readsRs2 && (D_rs2Id == DE_rdId);

   // we could generate slightly more bubble with
   // simpler test (to be used if critical path is here)
   // -> keeping this one (seems it has no influence on CPI,
   //   and results in slightly better timings)
   // wire  rs1Hazard = (D_rs1Id == DE_rdId);
   // wire  rs2Hazard = (D_rs2Id == DE_rdId);

   // we are not obliged to compare all bits !
   // wire rs1Hazard = (D_rs1Id[3:0] == DE_rdId[3:0]);
   // wire rs2Hazard = (D_rs2Id[3:0] == DE_rdId[3:0]);

   // Add bubble if next instr uses result of latency-2 instr
   // Or load right after store (problem only if same address,
   // we could also test but D does not know address yet)
   //  (we need here load after store test because mem read access is done
   //   in E. It was not the case in the non-optimized version)
   wire dataHazard = !FD_nop && (
        ((DE_isLoad || DE_isCSRRS) && (rs1Hazard || (rs2Hazard && !D_isStore))) ||
        ( D_isLoad && DE_isStore)
   );

   // (other option: always add bubble after latency-2 instr
   // like Samsoniuk's DarkRiscV). Increases CPI and may reduce critical path.
   // wire dataHazard = !FD_nop &&  (
   //   (DE_isLoad || DE_isCSRRS) || (D_isLoad && DE_isStore)
   // );

   assign F_stall = dataHazard | halt;
   assign D_stall = dataHazard | halt;

   // Here we need to use E_correctPC (the registered version
   // DE_correctPC is not ready on time).
   assign D_flush = E_correctPC;
   assign E_flush = E_correctPC | dataHazard;

/******************************************************************************/

`ifdef BENCH
   always @(posedge clk) begin
      if(halt) $finish();
   end

   reg [31:0] DE_instr; reg [31:0] DE_PC;
   reg [31:0] EM_instr; reg [31:0] EM_PC;
   reg [31:0] MW_instr; reg [31:0] MW_PC;

   localparam NOP = 32'b0000000_00000_00000_000_00000_0110011;

   always @(posedge clk) begin
      if(!D_stall) begin
	 DE_instr <= FD_nop ? NOP : FD_instr;
	 DE_PC    <= FD_PC;
      end
      if(E_flush) begin
	 DE_instr <= NOP;
      end
      EM_instr <= DE_instr;
      EM_PC    <= DE_PC;
      MW_instr <= EM_instr;
      MW_PC    <= EM_PC;
   end

`ifdef CONFIG_DEBUG

   always @(posedge clk) begin
      if(resetn & !halt) begin

         $write("     ");
	 $write("[W] PC=%h ", MW_PC);
	 $write("     ");
	 riscv_disasm(MW_instr,MW_PC);
	 if(wbEnable) $write(
            "    x%0d <- 0x%0h (%0d)",
	    riscv_disasm_rdId(MW_instr),wbData,wbData
         );
	 $write("\n");

         $write("(  ) ");
	 $write("[M] PC=%h ", EM_PC);
	 $write("     ");
	 riscv_disasm(EM_instr,EM_PC);
	 $write("\n");

         $write("( %c) ", E_flush ? "f":" ");
	 $write("[E] PC=%h ", DE_PC);

	 // Register forwarding
	 if(DE_nop) $write("[  ] ");
	 else $write("[%s%s] ",
	         riscv_disasm_readsRs1(DE_instr) ?
		     (execute.E_M_fwd_rs1 ? "M" : execute.E_W_fwd_rs1 ? "W" : " ") : " ",
		 riscv_disasm_readsRs2(DE_instr) ?
		     (execute.E_M_fwd_rs2 ? "M" : execute.E_W_fwd_rs2 ? "W" : " ") : " "
	 );
	 riscv_disasm(DE_instr,DE_PC);
	 if(DE_instr != NOP) begin
	    $write("  rs1=0x%h (%0d) rs2=0x%h (%0d) ",
		   execute.E_rs1,execute.E_rs1,execute.E_rs2,execute.E_rs2);
`ifdef CONFIG_PC_PREDICT
	    if(riscv_disasm_isBranch(DE_instr)) begin
	       $write(" taken:%0d  %s",
		       E_takeBranch,
		      (E_takeBranch == DE_predictBranch) ?
		             "predict hit" : "predict miss"
               );
	    end
`endif
	 end
	 $write("\n");

         $write("(%c%c) ",D_stall ? "s":" ",D_flush ? "f":" ");
	 $write("[D] PC=%h ", FD_PC);
	 $write("[%s%s] ",
		dataHazard && rs1Hazard?"*":" ",
		dataHazard && rs2Hazard?"*":" ");
	 riscv_disasm(FD_nop ? NOP : FD_instr,FD_PC);
`ifdef CONFIG_PC_PREDICT
	 if(riscv_disasm_isBranch(FD_instr)) begin
	    $write(" predict taken:%0d",decode.D_predictBranch);
	 end
`endif
	 $write("\n");

         $write("(%c ) ",F_stall ? "s":" ");
	 $write("[F] PC=%h ", fetch.F_PC);
`ifdef CONFIG_PC_PREDICT
	 if(D_predictPC) begin
	    $write(" PC <- [D] 0x%0h (prediction)",D_PCprediction);
	 end
`endif
	 if(EM_correctPC) begin
	    $write(" PC <- [E] 0x%0h (correction)",EM_PCcorrection);
	 end
	 $write("\n");

	 $display("");
      end
   end

/* "debugger" */

`ifdef verilator

   // wire breakpoint = 1'b0; // no breakpoint
   // wire breakpoint = (EM_addr == 32'h400004); // break on LEDs output
   wire breakpoint = (EM_addr == 32'h400008); // break on character output
   // wire breakpoint = (DE_PC   == 32'h000000); // break on address reached

   reg step = 1'b1;
   reg [31:0] dbg_cmd = 0;

   initial begin
      $display("");
      $display("\"Debugger\" commands:");
      $display("--------------------");
      $display("g       : go");
      $display("<return>: step");
      $display("see \"debugger\" section in source for breakpoints");
      $display("");
   end

   always @(posedge clk) begin
      if(resetn & !halt) begin
	 if(step) begin
	    $write("DBG>");
	    dbg_cmd <= $c32("getchar()");
	    $write("\n");
	 end
	 if(dbg_cmd == "g") begin
	    step <= 1'b0;
	 end
	 if(breakpoint) begin
	    step <= 1'b1;
	 end
      end
   end
`endif

`endif // `CONFIG_DEBUG

   /*************** statistics *************/

   integer nbBranch = 0;
   integer nbBranchHit = 0;
   integer nbJAL  = 0;
   integer nbJALR = 0;
   integer nbJALRhit = 0;
   integer nbLoad = 0;
   integer nbStore = 0;
   integer nbLoadHazard = 0;

   always @(posedge clk) begin
      if(resetn & !D_stall) begin
	 if(riscv_disasm_isBranch(DE_instr)) begin
	    nbBranch <= nbBranch + 1;
`ifdef CONFIG_PC_PREDICT
	    if(E_takeBranch == DE_predictBranch) begin
	       nbBranchHit <= nbBranchHit + 1;
	    end
`endif
	 end
	 if(riscv_disasm_isJAL(DE_instr)) begin
	    nbJAL <= nbJAL + 1;
	 end
	 if(riscv_disasm_isJALR(DE_instr)) begin
	    nbJALR <= nbJALR + 1;
`ifdef CONFIG_RAS
	    if(DE_predictRA == execute.E_JALRaddr) begin
	       nbJALRhit <= nbJALRhit + 1;
	    end
`endif
	 end
      end

      if(riscv_disasm_isLoad(MW_instr)) begin
	 nbLoad <= nbLoad + 1;
      end
      if(riscv_disasm_isStore(MW_instr)) begin
	 nbStore <= nbStore + 1;
      end
      if(dataHazard) begin
	 nbLoadHazard <= nbLoadHazard + 1;
      end
   end

   /* verilator lint_off WIDTH */
   always @(posedge clk) begin
      if(halt) begin
	 $display("Simulated processor's report");
	 $display("----------------------------");
	 $display("Branch hit = %3.3f\%%",
		   nbBranchHit*100.0/nbBranch	 );
	 $display("JALR   hit = %3.3f\%%",
		   nbJALRhit*100.0/nbJALR	 );
	 $display("Load hzrds = %3.3f\%%", nbLoadHazard*100.0/nbLoad);
	 $display("CPI        = %3.3f",(memory.cycle*1.0)/(memory.instret*1.0));
	 $write("Instr. mix = (");
	 $write("Branch:%3.3f\%%",    nbBranch*100.0/memory.instret);
	 $write(" JAL:%3.3f\%%",       nbJAL*100.0/memory.instret);
	 $write(" JALR:%3.3f\%%",      nbJALR*100.0/memory.instret);
	 $write(" Load:%3.3f\%%",      nbLoad*100.0/memory.instret);
	 $write(" Store:%3.3f\%%",     nbStore*100.0/memory.instret);
	 $write(")\n");
	 $finish();
      end
   end
   /* verilator lint_on WIDTH */

`endif // `BENCH

/******************************************************************************/

endmodule

//module SOC (
//    input 	     CLK, // system clock
//    input 	     RESET,// reset button
//    output reg [4:0] LEDS, // system LEDs
//    input 	     RXD, // UART receive
//    output 	     TXD  // UART transmit
//);
//
//   wire clk;
//   wire resetn;
//
//   wire [31:0] IO_mem_addr;
//   wire [31:0] IO_mem_rdata;
//   wire [31:0] IO_mem_wdata;
//   wire        IO_mem_wr;
//
//   Processor CPU(
//      .clk(clk),
//      .resetn(resetn),
//      .IO_mem_addr(IO_mem_addr),
//      .IO_mem_rdata(IO_mem_rdata),
//      .IO_mem_wdata(IO_mem_wdata),
//      .IO_mem_wr(IO_mem_wr)
//   );
//
//   wire [13:0] IO_wordaddr = IO_mem_addr[15:2];
//
//   // Memory-mapped IO in IO page, 1-hot addressing in word address.
//   localparam IO_LEDS_bit      = 0;  // W five leds
//   localparam IO_UART_DAT_bit  = 1;  // W data to send (8 bits)
//   localparam IO_UART_CNTL_bit = 2;  // R status. bit 9: busy sending
//
//   always @(posedge clk) begin
//      if(IO_mem_wr & IO_wordaddr[IO_LEDS_bit]) begin
//	 LEDS <= IO_mem_wdata[4:0];
//      end
//   end
//
//   wire uart_valid = IO_mem_wr & IO_wordaddr[IO_UART_DAT_bit];
//   wire uart_ready;
//
//
////   corescore_emitter_uart #(
////      .clk_freq_hz(`CPU_FREQ*1000000)
////   ) UART(
////      .i_clk(clk),
////      .i_rst(!resetn),
////      .i_data(IO_mem_wdata[7:0]),
////      .i_valid(uart_valid),
////      .o_ready(uart_ready),
////      .o_uart_tx(TXD)
////   );
////
////   assign IO_mem_rdata =
////		    IO_wordaddr[IO_UART_CNTL_bit] ? { 22'b0, !uart_ready, 9'b0}
////	                                          : 32'b0;
////
////`ifdef BENCH
////   always @(posedge clk) begin
////      if(uart_valid) begin
////`ifdef CONFIG_DEBUG
////	 $display("UART: %c", IO_mem_wdata[7:0]);
////`else
////	 $write("%c", IO_mem_wdata[7:0] );
////	 $fflush(32'h8000_0001);
////`endif
////      end
////   end
////`endif
////
////   // Gearbox and reset circuitry.
////   Clockworks CW(
////     .CLK(CLK),
////     .RESET(RESET),
////     .clk(clk),
////     .resetn(resetn)
////   );
//
//endmodule

`default_nettype wire
