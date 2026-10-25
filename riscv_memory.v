`include "riscv_config.vh"
`default_nettype none

/******************************************************************************/

                     /*** M: Memory ***/

// Owns the data RAM and the cycle/instret CSRs. The RAM read is started by
// E (E_addr) so that its registered output, EM_Mdata, is valid in M together
// with the other EM_ registers.

module riscv_memory (
   input  wire        clk,
   input  wire        resetn,

   input  wire [31:0] E_addr,        // data RAM read address, from E

   // E/M pipeline register
   input  wire        EM_nop,
   input  wire [4:0]  EM_rdId,
   input  wire [4:0]  EM_rs2Id,
   input  wire [3:0]  EM_csrId_is,
   input  wire [2:0]  EM_funct3,
   input  wire [31:0] EM_rs2,
   input  wire [31:0] EM_Eresult,
   input  wire [31:0] EM_addr,
   input  wire        EM_isStore,
   input  wire        EM_isLoad,
   input  wire        EM_isCSRRS,
   input  wire        EM_wbEnable,

   output wire [31:0] IO_mem_addr,   // IO memory address
   input  wire [31:0] IO_mem_rdata,  // data read from IO memory
   output wire [31:0] IO_mem_wdata,  // data written to IO memory
   output wire        IO_mem_wr,     // IO write flag

   // M/W pipeline register
   output reg         MW_nop,        // Needed by instret in W stage
   output reg  [4:0]  MW_rdId,
   output reg  [31:0] MW_wbData,
   output reg         MW_wbEnable
);

   // CSRs (cycle and retired instructions counters)
   reg [63:0] cycle;
   reg [63:0] instret;

   always @(posedge clk) begin
      cycle <= !resetn ? 0 : cycle + 1;
   end

   wire M_isB = (EM_funct3[1:0] == 2'b00);
   wire M_isH = (EM_funct3[1:0] == 2'b01);

   /*********** Registrer forwarding ************************************/

   // store's rs2 register id, only when data is forwarded, not address
   // (used when sw instruction dependent on lw)
   wire M_W_fwd_rs2 = MW_wbEnable && (MW_rdId != 0) && (MW_rdId == EM_rs2Id) && EM_isStore;

   wire [31:0] M_rs2 = M_W_fwd_rs2 ? MW_wbData : EM_rs2 ;

   /*************** STORE **************************/

   wire [31:0] M_STORE_data;
   assign M_STORE_data[ 7: 0] = M_rs2[7:0];
   assign M_STORE_data[15: 8] = EM_addr[0] ? M_rs2[7:0]  : M_rs2[15: 8] ;
   assign M_STORE_data[23:16] = EM_addr[1] ? M_rs2[7:0]  : M_rs2[23:16] ;
   assign M_STORE_data[31:24] = EM_addr[0] ? M_rs2[7:0]  :
			        EM_addr[1] ? M_rs2[15:8] : M_rs2[31:24] ;

   // The memory write mask:
   //    1111                     if writing a word
   //    0011 or 1100             if writing a halfword
   //                                (depending on EM_addr[1])
   //    0001, 0010, 0100 or 1000 if writing a byte
   //                                (depending on EM_addr[1:0])

   wire [3:0] M_STORE_wmask = M_isB ?
	                     (EM_addr[1] ?
		                (EM_addr[0] ? 4'b1000 : 4'b0100) :
		                (EM_addr[0] ? 4'b0010 : 4'b0001)
                             ) :
	                     M_isH ? (EM_addr[1] ? 4'b1100 : 4'b0011) :
                                     4'b1111 ;


   wire  M_isIO         = EM_addr[22];
   wire  M_isRAM        = !M_isIO;

   assign IO_mem_addr  = EM_addr;
   assign IO_mem_wr    = EM_isStore && M_isIO; // && M_STORE_wmask[0];
   assign IO_mem_wdata = M_rs2;

   wire [3:0] M_wmask = {4{EM_isStore & M_isRAM}} & M_STORE_wmask;

   reg [31:0] DATARAM [0:31]; // 32 4-bytes words
                                 // 16 Kb of data RAM in total

//   initial begin
//      $readmemh("DATARAM.hex",DATARAM);
//   end

   integer j;
   initial begin
      for (j = 0; j < 32; j = j + 1) DATARAM[j] = 32'h00000000;
      // DATARAM[0] = 32'hDEADBEEF; // example
   end

   wire [13:0] M_word_addr = EM_addr[15:2];

   always @(posedge clk) begin
      if(M_wmask[0]) DATARAM[M_word_addr][ 7:0 ] <= M_STORE_data[ 7:0 ];
      if(M_wmask[1]) DATARAM[M_word_addr][15:8 ] <= M_STORE_data[15:8 ];
      if(M_wmask[2]) DATARAM[M_word_addr][23:16] <= M_STORE_data[23:16];
      if(M_wmask[3]) DATARAM[M_word_addr][31:24] <= M_STORE_data[31:24];
   end

   // RAM read port: address comes from E, data is used in M.
   reg [31:0] EM_Mdata;

   always @(posedge clk) begin
      EM_Mdata <= DATARAM[E_addr[15:2]];
   end

   wire M_sext = !EM_funct3[2];

   /*************** LOAD ****************************/

   wire [15:0] M_LOAD_H=EM_addr[1] ? EM_Mdata[31:16]: EM_Mdata[15:0];
   wire  [7:0] M_LOAD_B=EM_addr[0] ? M_LOAD_H[15:8] : M_LOAD_H[7:0];
   wire        M_LOAD_sign=M_sext & (M_isB ? M_LOAD_B[7] : M_LOAD_H[15]);

   wire [31:0] M_Mdata = M_isB ? {{24{M_LOAD_sign}},M_LOAD_B} :
	                 M_isH ? {{16{M_LOAD_sign}},M_LOAD_H} :
                                                    EM_Mdata ;

   wire [31:0] M_CSR_data =
	(EM_csrId_is[0] ? cycle[31:0]    : 32'b0) |
	(EM_csrId_is[2] ? cycle[63:32]   : 32'b0) |
	(EM_csrId_is[1] ? instret[31:0]  : 32'b0) |
        (EM_csrId_is[3] ? instret[63:32] : 32'b0) ;

   always @(posedge clk) begin
      MW_nop       <= EM_nop;
      MW_rdId      <= EM_rdId;

      MW_wbData <=
	  EM_isLoad  ? (M_isIO ? IO_mem_rdata : M_Mdata) :
          EM_isCSRRS ? M_CSR_data   :
          EM_Eresult;

      MW_wbEnable  <= EM_wbEnable;

      if(!resetn) begin
	 instret <= 0;
      end else if(!MW_nop) begin
	 // It's easier to count the retired instructions when
	 // they *exit* the pipeline (but it requires to pass
	 // a _nop flag through the pipeline).
	 instret <= instret + 1;
      end
   end

endmodule

`default_nettype wire
