// Behavioural stand-ins for the course SRAM macros (1 write port + 1 read port,
// active-low chip selects, synchronous read: data valid the cycle after the
// address is sampled).  Replace with the provided macro models for sign-off.
module sram_32x32_1r1w (
  input  wire        clk0, input wire csb0, input wire [4:0] addr0, input wire [31:0] din0,
  input  wire        clk1, input wire csb1, input wire [4:0] addr1, output logic [31:0] dout1
);
  logic [31:0] mem [0:31];
  always @(posedge clk0) if (!csb0) mem[addr0] <= din0;
  always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
endmodule

module sram_128x32_1r1w (
  input  wire        clk0, input wire csb0, input wire [6:0] addr0, input wire [31:0] din0,
  input  wire        clk1, input wire csb1, input wire [6:0] addr1, output logic [31:0] dout1
);
  logic [31:0] mem [0:127];
  always @(posedge clk0) if (!csb0) mem[addr0] <= din0;
  always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
endmodule
