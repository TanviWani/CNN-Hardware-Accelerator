`timescale 1ns/1ps
// =============================================================================
// Self-checking testbench for the full CNN accelerator (dut.sv)
//   * loads vec/dram_init.hex into the DRAM model
//   * runs the DUT twice back-to-back (second run proves restart/clear is clean)
//   * CHECK 1  feature maps : every OSRAM write (480 words) vs golden pooled maps
//   * CHECK 2  result       : class + NC int32 logits read back from DRAM vs golden
//   * CHECK 3  protocol     : DRAM model command spacing / bus-turnaround errors
//   * CHECK 4  liveness     : watchdog timeout
//   plusargs: +VEC=<dir> (default vec)   +VERBOSE   (per-tile trace needs -DCNN_DEBUG)
// Run-time log lines are prefixed [TB ]; the last line is "RESULT: PASS|FAIL".
// =============================================================================
module tb_cnn;
  parameter int NC = 10;
  parameter int RD_LAT = 6, WR_LAT = 5, COMMIT = 0;      // DRAM/DUT timing knobs (must match)
  localparam int NRB = 1 + (NC + 1) / 2;
  localparam logic [31:0] RES_BASE = 32'h1100;
  localparam int WATCHDOG = 200000;      // slow-FC mutants legitimately need ~110k cycles for two runs

  logic clk = 0, reset_n = 0, start = 0;
  wire        ready;
  wire [1:0]  CMD;
  wire [31:0] addr;
  wire [7:0]  dout, din;
  wire        oe;

  always #5 clk = ~clk;                                   // 100 MHz

  dut_cnn #(.NUM_CLASSES(NC), .RD_LAT(RD_LAT), .WR_LAT(WR_LAT), .COMMIT(COMMIT)) dut (
    .clk(clk), .reset_n(reset_n), .start(start), .ready(ready),
    .CMD(CMD), .addr(addr), .dout(dout), .din(din), .oe(oe)
  );
  dram_model #(.RD_LAT(RD_LAT), .WR_LAT(WR_LAT)) dram (.clk(clk), .CMD(CMD), .addr(addr), .din(din), .oe(oe), .dout(dout));

  string vec_dir;
  logic [31:0] exp_feat [0:479];
  logic [63:0] exp_res  [0:NRB-1];
  int errors = 0;
  int run_cycles [1:2];
  int cycle  = 0;
  always @(posedge clk) cycle <= cycle + 1;

  // ---------------- CHECK 1: feature-map monitor (taps the OSRAM write port) -------------
  int feat_n = 0, feat_bad = 0;
  always @(posedge clk) begin
    if (reset_n && !dut.os_csb0) begin
      if (feat_n < 480) begin
        if (dut.os_d0 !== exp_feat[feat_n] || dut.os_a0 !== 7'(((feat_n / 60) % 2) * 64 + (feat_n % 60))) begin
          feat_bad++;
          if (feat_bad <= 5)
            $display("[TB ] FEATURE MISMATCH #%0d: map %0d word %0d  addr=%0d got %08h exp %08h",
                     feat_bad, feat_n/60, feat_n%60, dut.os_a0, dut.os_d0, exp_feat[feat_n]);
        end
      end
      feat_n++;
    end
  end

  // ---------------- milestone tracking ------------------------------------------------------
  int t_start, t_rd_done, t_fc_done, t_ready;
  logic fc_seen, rd_seen;
  always @(posedge clk) begin
    if (dut.dst == 4'b0100 && !rd_seen) begin rd_seen = 1; t_rd_done = cycle; end
    if (dut.fc_done && !fc_seen)        begin fc_seen = 1; t_fc_done = cycle; end
  end

  function automatic logic [7:0] sbyte(input logic [63:0] w, input int s);
    return w[56 - 8*s +: 8];                                // stream byte s of a burst word
  endfunction

  task automatic run_once(input int idx);
    int cls_got, cls_exp, nc_got, bad, rd0, wr0;
    logic signed [31:0] lg_got, lg_exp;
    logic [63:0] gw, ew;
    bit pass;
    $display("");
    $display("[TB ] ===== RUN %0d : start @cycle %0d =====", idx, cycle);
    feat_n = 0; feat_bad = 0; fc_seen = 1; rd_seen = 1;     // masked until the new run has started
    rd0 = dram.n_rd; wr0 = dram.n_wr;
    for (int j = 0; j < NRB; j++) dram.mem[(RES_BASE >> 3) + j] = 64'hDEAD_BEEF_DEAD_BEEF;   // poison result area
    @(posedge clk); start <= 1;
    wait (ready == 0); t_start = cycle; @(posedge clk); start <= 0;
    fc_seen = 0; rd_seen = 0;
    wait (ready == 1); t_ready = cycle;
    run_cycles[idx] = t_ready - t_start;
    repeat (4) @(posedge clk);

    $display("[TB ] timeline (cycles from start): reads+weight-stream issued %0d | classifier done %0d | ready %0d",
             t_rd_done - t_start, t_fc_done - t_start, t_ready - t_start);
    $display("[TB ] DRAM bursts: %0d reads, %0d writes (expected reads %0d, writes %0d)",
             dram.n_rd - rd0, dram.n_wr - wr0, 144 + (2*NC+7)/8 + NC*225, NRB);
    if (dram.n_rd - rd0 != 144 + (2*NC+7)/8 + NC*225 || dram.n_wr - wr0 != NRB) begin errors++; $display("[TB ] FAIL: unexpected DRAM burst count"); end

    // CHECK 1 report
    if (feat_n !== 480) begin errors++; $display("[TB ] FAIL: expected 480 OSRAM writes, saw %0d", feat_n); end
    if (feat_bad != 0)  begin errors++; $display("[TB ] FAIL: %0d feature words differ", feat_bad); end
    else if (feat_n == 480) $display("[TB ] CHECK 1 feature maps : PASS (480/480 words, 8 maps x 15x16 incl. zero pad column)");

    // CHECK 2: result
    bad = 0;
    gw = dram.mem[(RES_BASE >> 3)]; ew = exp_res[0];
    cls_got = sbyte(gw, 0); cls_exp = sbyte(ew, 0); nc_got = sbyte(gw, 1);
    $display("[TB ] ---- result read back from DRAM @0x%0h ----", RES_BASE);
    $display("[TB ]  class   | got %0d | expected %0d | NC field %0d  -> %s", cls_got, cls_exp, nc_got,
             (cls_got == cls_exp && nc_got == NC) ? "ok" : "MISMATCH");
    if (cls_got != cls_exp || nc_got != NC) bad++;
    for (int i = 0; i < NC; i++) begin
      gw = dram.mem[(RES_BASE >> 3) + 1 + i/2]; ew = exp_res[1 + i/2];
      for (int b = 0; b < 4; b++) begin
        lg_got[8*b +: 8] = sbyte(gw, 4*(i%2) + b);
        lg_exp[8*b +: 8] = sbyte(ew, 4*(i%2) + b);
      end
      $display("[TB ]  logit[%0d]%s | got %11d | expected %11d  %s%s", i, (i < 10) ? " " : "", lg_got, lg_exp,
               (lg_got == lg_exp) ? "ok" : "<-- MISMATCH", (i == cls_got) ? "   (argmax)" : "");
      if (lg_got !== lg_exp) bad++;
    end
    if (bad == 0) $display("[TB ] CHECK 2 classifier result : PASS");
    else begin errors++; $display("[TB ] CHECK 2 classifier result : FAIL (%0d fields)", bad); end
    // the hierarchical class register must agree with what was written to DRAM
    if (dut.fc_pred !== cls_exp[3:0]) begin errors++; $display("[TB ] FAIL: dut.fc_pred=%0d", dut.fc_pred); end
  endtask

  initial begin
    if (!$value$plusargs("VEC=%s", vec_dir)) vec_dir = "vec";
    $readmemh({vec_dir, "/dram_init.hex"}, dram.mem);
    $readmemh({vec_dir, "/exp_feat.hex"},  exp_feat);
    $readmemh({vec_dir, "/exp_res.hex"},   exp_res);
    $display("[TB ] ECE 564 full CNN accelerator testbench  (NC=%0d classes, vectors from '%0s')", NC, vec_dir);
    repeat (5) @(posedge clk); reset_n <= 1; repeat (3) @(posedge clk);
    run_once(1);
    run_once(2);                                           // back-to-back restart, same inputs

    // CHECK 3: protocol
    if (dram.errors != 0) begin errors += dram.errors; $display("[TB ] CHECK 3 DRAM protocol : FAIL (%0d violations)", dram.errors); end
    else $display("[TB ] CHECK 3 DRAM protocol : PASS (no spacing / bus-contention violations)");

    $display("");
    if (errors == 0) $display("[TB ] RESULT: PASS");
    else             $display("[TB ] RESULT: FAIL (%0d error groups)", errors);
    begin   // machine-readable result for make cnn-report
      int fd; string rp;
      if (!$value$plusargs("RESULT=%s", rp)) rp = "cnn_result.txt";
      fd = $fopen(rp, "w");
      if (fd != 0) begin
        $fdisplay(fd, "result=%s", (errors == 0) ? "PASS" : "FAIL");
        $fdisplay(fd, "nc=%0d", NC);
        $fdisplay(fd, "cycles_run1=%0d", run_cycles[1]);
        $fdisplay(fd, "cycles_run2=%0d", run_cycles[2]);
        $fclose(fd);
      end
    end
    $finish;
  end

  // CHECK 4: watchdog
  initial begin
    #(10 * WATCHDOG);
    $display("[TB ] watchdog state: dst=%b fc_st=%b rd_cnt=%0d tcons=%0d full=%b wfull=%b fc_done=%b",
             dut.dst, dut.u_fc.st, dut.rd_cnt, dut.tcons, dut.full, dut.wfull, dut.fc_done);
    $display("[TB ] RESULT: FAIL (watchdog: no ready after %0d cycles, dst=%b)", WATCHDOG, dut.dst);
    $finish;
  end
endmodule
