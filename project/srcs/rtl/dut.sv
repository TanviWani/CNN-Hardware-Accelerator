// =============================================================================
// Top-level wrapper (the module the testbench and Design Compiler instantiate).
//   default       : dut_feature  - verified feature-extraction design (course deliverable,
//                   writes the 8 pooled maps to DRAM @0x600).
//   +define FULL_CNN : dut_cnn   - full CNN accelerator (feature extraction + flatten +
//                   weight memory + bias + MAC/accumulation tree + argmax). Weights/bias are read
//                   from DRAM and the class + logits are written back (see cnn_ext/README_CNN.md).
// Both cores have identical ports; only one is elaborated.
// Select with:  cmake .. --preset cnn   (or -DFULL_CNN=ON)
// =============================================================================
module dut #(
  parameter int DRAM_ADDRESS_WIDTH = 32,
  parameter int DRAM_DQ_WIDTH = 8
)(
  // Clock and reset
  input  wire clk,
  input  wire reset_n,
  // Handshake
  input  wire start,
  output logic ready,
  // Unified DRAM
  output logic [1:0] CMD,
  output logic [DRAM_ADDRESS_WIDTH-1:0] addr,
  input  wire [DRAM_DQ_WIDTH-1:0] dout,
  output logic [DRAM_DQ_WIDTH-1:0] din,
  output logic oe
);
`ifdef FULL_CNN
  dut_cnn #(.DRAM_ADDRESS_WIDTH(DRAM_ADDRESS_WIDTH), .DRAM_DQ_WIDTH(DRAM_DQ_WIDTH)) u_core (
`else
  dut_feature #(.DRAM_ADDRESS_WIDTH(DRAM_ADDRESS_WIDTH), .DRAM_DQ_WIDTH(DRAM_DQ_WIDTH)) u_core (
`endif
    .clk(clk), .reset_n(reset_n), .start(start), .ready(ready),
    .CMD(CMD), .addr(addr), .dout(dout), .din(din), .oe(oe)
  );

  // simulation-only banner: shows in the vsim log which core was compiled
  // synopsys translate_off
`ifdef FULL_CNN
  initial $display("[DUT] core elaborated: dut_cnn   (FULL CNN accelerator, FULL_CNN defined)");
`else
  initial $display("[DUT] core elaborated: dut_feature (feature extraction only)");
`endif
  // synopsys translate_on
endmodule
