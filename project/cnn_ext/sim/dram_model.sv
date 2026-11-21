// Cycle-accurate DRAM stand-in.  Timing (matches the calibration comments in dut.sv):
//   READ : command sampled at edge E  -> DUT samples beat 0 at edge E+RD_LAT
//   WRITE: command sampled at edge E  -> model samples beat 0 at edge E+WR_LAT
// 64-bit words, little-endian byte addresses, beats are sent MSB byte first
// (beat k <-> bits [63-8k -: 8]).  This is the convention the feature-extraction
// RTL already relies on (deduced from its byte-lane wiring).
module dram_model #(
  parameter int RD_LAT = 6, parameter int WR_LAT = 5, parameter int WORDS = 16384,
  parameter int MIN_GAP = 8
)(
  input  wire        clk,
  input  wire [1:0]  CMD,
  input  wire [31:0] addr,
  input  wire [7:0]  din,
  input  wire        oe,
  output logic [7:0] dout
);
  logic [63:0] mem [0:WORDS-1];
  int cyc = 0;
  int rd_start [0:7]; logic [31:0] rd_a [0:7]; int rd_n = 0;
  int wr_start [0:7]; logic [31:0] wr_a [0:7]; int wr_n = 0;
  int last_cmd_cyc = -1000;
  int n_rd = 0, n_wr = 0, errors = 0;

  always @(posedge clk) begin
    bit rd_act, wr_act;
    rd_act = 0; wr_act = 0;
    cyc = cyc + 1;
    if (CMD != 2'd0) begin
      if (cyc - last_cmd_cyc < MIN_GAP) begin
        errors++; $display("[DRAM] ERROR t=%0t: command spacing %0d < %0d cycles", $time, cyc-last_cmd_cyc, MIN_GAP);
      end
      last_cmd_cyc = cyc;
      if (CMD == 2'd1) begin rd_start[rd_n] = cyc + RD_LAT - 1; rd_a[rd_n] = addr; rd_n++; n_rd++; end
      if (CMD == 2'd2) begin wr_start[wr_n] = cyc + WR_LAT;     wr_a[wr_n] = addr; wr_n++; n_wr++; end
    end
    dout <= 8'hEE;                                   // junk outside the valid window
    for (int i = 0; i < rd_n; i++) begin
      int k; k = cyc - rd_start[i];
      if (k >= 0 && k < 8) begin
        rd_act = 1;
        dout <= mem[rd_a[i][31:3]][63-8*k -: 8];
      end
    end
    for (int i = 0; i < wr_n; i++) begin
      int k; k = cyc - wr_start[i];
      if (k >= 0 && k < 8) begin
        wr_act = 1;
        if (!oe) begin errors++; $display("[DRAM] ERROR t=%0t: oe low during write beat %0d", $time, k); end
        mem[wr_a[i][31:3]][63-8*k -: 8] = din;
      end
    end
    if (rd_act && oe) begin errors++; $display("[DRAM] ERROR t=%0t: DUT drives bus during read window", $time); end
    if (rd_n > 0 && cyc - rd_start[0] >= 8) begin for (int i=1;i<8;i++) begin rd_start[i-1]=rd_start[i]; rd_a[i-1]=rd_a[i]; end rd_n--; end
    if (wr_n > 0 && cyc - wr_start[0] >= 8) begin for (int i=1;i<8;i++) begin wr_start[i-1]=wr_start[i]; wr_a[i-1]=wr_a[i]; end wr_n--; end
  end
endmodule
