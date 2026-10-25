`include "riscv_config.vh"
`default_nettype none

/******************************************************************************/

                     /*** W: WriteBack ***/

// Owns the register file: written here, read asynchronously by E
// (so a value written by W is visible to E on the next cycle, and the
// same-cycle case is covered by the W->E forwarding path).

module riscv_writeback (
   input  wire        clk,

   // M/W pipeline register
   input  wire        MW_wbEnable,
   input  wire [4:0]  MW_rdId,
   input  wire [31:0] MW_wbData,

   // register file read ports (used by E)
   input  wire [4:0]  rs1Id,
   input  wire [4:0]  rs2Id,
   output wire [31:0] rs1Data,
   output wire [31:0] rs2Data,

   output wire        wbEnable,
   output wire [31:0] wbData,
   output wire [4:0]  wbRdId
);

   assign wbData   = MW_wbData;
   assign wbEnable = MW_wbEnable;
   assign wbRdId   = MW_rdId;

   reg [31:0] RegisterBank [0:31];

`ifdef CONFIG_INITIALIZE
   integer i;
   initial begin
      for(i=0; i<32; i=i+1) begin
	 RegisterBank[i] = 0;
      end
   end
`endif

   always @(posedge clk) begin
      if(wbEnable) begin
	 RegisterBank[wbRdId] <= wbData;
      end
   end

   assign rs1Data = RegisterBank[rs1Id];
   assign rs2Data = RegisterBank[rs2Id];

endmodule

`default_nettype wire
