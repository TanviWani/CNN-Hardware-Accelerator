`timescale 1ns/1ps
module tb_feature;
  logic clk=0, reset_n=0, start=0; wire ready; wire [1:0] CMD; wire [31:0] addr; wire [7:0] dout, din; wire oe;
  always #5 clk = ~clk;
  dut dut(.clk(clk),.reset_n(reset_n),.start(start),.ready(ready),.CMD(CMD),.addr(addr),.dout(dout),.din(din),.oe(oe));
  dram_model dram(.clk(clk),.CMD(CMD),.addr(addr),.din(din),.oe(oe),.dout(dout));
  string vec_dir;
  int bad = 0, cycles = 0;
  initial begin
    if (!$value$plusargs("VEC=%s", vec_dir)) vec_dir = "vec";
    $readmemh({vec_dir, "/dram_init.hex"}, dram.mem);
    repeat (5) @(posedge clk); reset_n = 1; repeat (3) @(posedge clk);
    start = 1; wait (ready == 0); @(posedge clk); start = 0;
    wait (ready == 1);
    // original writes 8 maps x 30 words at 0x600
    for (int m = 0; m < 8; m++) for (int w = 0; w < 30; w++) begin
      logic [63:0] got; got = dram.mem[(32'h600 >> 3) + m*30 + w];
      // expected: bytes of the padded 15x16 map, address order little endian
      begin
        logic [63:0] e; e = 0;
        for (int i = 0; i < 8; i++) e |= 64'(exp_b(m, w*8+i)) << (8*i);
        if (got !== e) begin bad++; if (bad < 6) $display("MISMATCH map %0d word %0d got %016h exp %016h", m, w, got, e); end
      end
    end
    $display("FEATURE-ONLY MODE (wrapper -> dut_feature) @0x600: %0d mismatching words", bad);
    $finish;
  end
  initial begin #(10*60000); $display("TIMEOUT"); $finish; end
  logic [7:0] expb [0:1919];
  initial begin #1; $readmemh({vec_dir, "/exp_featbytes.hex"}, expb); end
  function automatic logic [7:0] exp_b(int m, int idx); return expb[m*240 + idx]; endfunction
endmodule
