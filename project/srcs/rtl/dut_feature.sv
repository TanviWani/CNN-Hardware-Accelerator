// ===== AI-GENERATED CODE START (Claude, Anthropic) - prompts documented in report appendix =====
// =============================================================================
// ECE 564 Fall 2026 - CNN feature extraction (564 variant), spec v4
// Pipelined design: 4 dot-product units (64 multipliers), 1 pooled pixel / cycle.
//
//   IMPORTANT: keep the port NAMES/WIDTHS of the provided dut.sv stub.  If they
//   differ from the header below, change ONLY the header and the 5 output
//   `assign` lines at the "Output ports" section.
//
//   Parameters (calibrate against the HW5 DRAM timing, see README notes):
//     RD_LAT  : clock edges between the edge that samples a READ command and the
//               edge at which the DUT samples the first read beat
//     WR_LAT  : same for WRITE (edge sampling the command -> edge that samples
//               the first write beat)
//     COMMIT  : extra idle cycles after the last write beat before ready rises
//     ROUND_V4: 1 = spec v4 (round toward zero, ASR2(x+3)), 0 = spec v3
// =============================================================================
module dut_feature #(
  // Parameters overridden by tb.sv - names/widths must match the stub exactly
  parameter int DRAM_ADDRESS_WIDTH = 32,
  parameter int DRAM_DQ_WIDTH      = 8,
  // Internal timing knobs (tb does not override these)
  // Calibrated to the 564 DRAM timing of the working dut.sv:
  //   READ : cmd visible cycle 1 -> first beat sampled at the edge ending cycle 7  => RD_LAT = 6
  //   WRITE: cmd visible cycle 1 -> first din beat sampled at edge ending cycle 6  => WR_LAT = 5
  //   ready rises right after the last write beat (as in dut.sv)                   => COMMIT = 0
  parameter int RD_LAT   = 6,
  parameter int WR_LAT   = 5,
  parameter int COMMIT   = 0,
  parameter bit ROUND_V4 = 1'b1
)(
  input  wire                           clk,
  input  wire                           reset_n,
  input  wire                           start,
  output logic                          ready,
  output logic [1:0]                    CMD,
  output logic [DRAM_ADDRESS_WIDTH-1:0] addr,
  input  wire  [DRAM_DQ_WIDTH-1:0]      dout,
  output logic [DRAM_DQ_WIDTH-1:0]      din,
  output logic                          oe
);

  // ---------------------------------------------------------------------------
  // Derived constants
  // ---------------------------------------------------------------------------
  localparam int TD  = (WR_LAT + 1 > 4) ? (WR_LAT + 1) : 4;  // decision -> first din beat
  localparam int TC  = TD - WR_LAT;                          // decision -> CMD visible (>=1)
  localparam int NWL = TD + 3;

  // control-token field positions
  localparam int T_V    = 0;
  localparam int T_Q15  = 1;
  localparam int T_MROW = 2;
  localparam int T_MCOL = 3;
  localparam int T_ODD  = 4;
  localparam int T_SH   = 5;
  localparam int T_CAPH = 6;
  localparam int T_HEAD = 7;
  localparam int T_KSW  = 8;
  localparam int T_BSEL = 9;    // [10:9]
  localparam int T_KN   = 11;   // [14:11]
  localparam int TW     = 15;

  // ---------------------------------------------------------------------------
  // Global handshake / init
  // ---------------------------------------------------------------------------
  typedef enum logic [4:0] {
    D_IDLE = 5'b00001,
    D_RD   = 5'b00010,
    D_RDW  = 5'b00100,
    D_WR   = 5'b01000,
    D_WRD  = 5'b10000
  } dstate_t;
  dstate_t dst;

  logic start_d;
  logic ready_r;
  logic init;                         // 1-cycle pulse that clears all control state
  logic clr;
  logic [2:0] bph;                    // DRAM command cadence phase

  always_ff @(posedge clk) begin
    if (!reset_n) start_d <= 1'b0;
    else          start_d <= start;
  end
  assign init = (dst == D_IDLE) & start & ~start_d;
  assign clr  = ~reset_n | init;

  // ---------------------------------------------------------------------------
  // DRAM interface registers
  // ---------------------------------------------------------------------------
  logic [1:0]  cmd_r;
  logic [31:0] addr_r;
  logic [7:0]  din_r;
  logic        oe_r;

  // ---- read issue ----
  logic [7:0]  rd_cnt;
  logic [31:0] rd_addr;
  logic        rd_cmd_v;
  wire         rd_issue = (dst == D_RD) & (bph == 3'd0);

  // ---- write decision / pipeline ----
  logic [2:0]  wmap;
  logic [4:0]  wwd;
  logic [1:0]  full;
  wire         wgo = (dst == D_WR) & (bph == 3'd0) & ((wwd != 5'd0) | full[wmap[0]]);
  wire         wlast = (wmap == 3'd7) & (wwd == 5'd29);
  logic [NWL-1:1] wl_q;               // wgo delayed by 1..NWL-1 cycles
  wire  [NWL-1:0] wl = {wl_q, wgo};   // wl[k] = wgo delayed by k cycles
  logic [31:0] waddr;
  logic [6:0]  drain;
  logic        stored_f;

  // ---------------------------------------------------------------------------
  // dram_fsm  (Moore, one-hot)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset_n) begin
      dst     <= D_IDLE;
      bph     <= 3'd0;
      ready_r <= 1'b1;
      drain   <= 7'd0;
    end else begin
      case (dst)
        D_IDLE: begin
          if (init) begin dst <= D_RD; bph <= 3'd0; ready_r <= 1'b0; end
        end
        D_RD: begin
          bph <= bph + 3'd1;
          if (rd_issue && rd_cnt == 8'd143) dst <= D_RDW;
        end
        D_RDW: begin
          if (stored_f) begin dst <= D_WR; bph <= 3'd0; end
        end
        D_WR: begin
          if (bph == 3'd0) begin
            if (wgo) begin
              bph <= 3'd1;
              if (wlast) begin
                dst   <= D_WRD;
                drain <= 7'(TD + 6 + COMMIT);
              end
            end
          end else begin
            bph <= bph + 3'd1;
          end
        end
        D_WRD: begin
          if (drain == 7'd0) begin dst <= D_IDLE; ready_r <= 1'b1; end
          else               drain <= drain - 7'd1;
        end
        default: begin dst <= D_IDLE; ready_r <= 1'b1; end
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // READ PATH: issue, capture window, byte lanes, SRAM write staging
  // ---------------------------------------------------------------------------
  logic [RD_LAT:1] rdd_q;             // delayed copies of rd_cmd_v
  wire  [RD_LAT:0] rdd = {rdd_q, rd_cmd_v};
  always_ff @(posedge clk) begin
    if (clr) rdd_q <= '0;
    else     rdd_q <= rdd[RD_LAT-1:0];
  end
  wire cap_start = rdd[RD_LAT];

  logic       cap_run;
  logic [2:0] cap_ctr;
  logic [7:0] cap_u;                  // DRAM word index being captured (0..143)
  wire        cap_v    = cap_start | cap_run;
  wire  [2:0] cbeat    = cap_start ? 3'd0 : cap_ctr;
  always_ff @(posedge clk) begin
    if (clr) begin
      cap_run <= 1'b0; cap_ctr <= 3'd0;
    end else begin
      if (cap_start) begin cap_run <= 1'b1; cap_ctr <= 3'd1; end
      else if (cap_run) begin
        cap_ctr <= cap_ctr + 3'd1;
        if (cap_ctr == 3'd7) cap_run <= 1'b0;
      end
    end
  end

  // byte-lane capture registers.  DRAM data is already signed two's complement
  // (same as dut.sv: `$signed(dout)`), so it is stored unchanged - no -128 bias here.
  logic [7:0] cl [0:3];
  wire  [7:0] dbyte = dout;
  always_ff @(posedge clk) begin
    if (cap_v) cl[2'd3 - cbeat[1:0]] <= dbyte;
  end

  // half-word complete (visible the cycle after beat 3 / beat 7 was sampled)
  logic half_ev, half_sel;
  always_ff @(posedge clk) begin
    if (clr) half_ev <= 1'b0;
    else     half_ev <= cap_v & (cbeat[1:0] == 2'd3);
    half_sel <= cbeat[2];
  end

  always_ff @(posedge clk) begin
    if (clr)                       cap_u <= 8'd0;
    else if (half_ev & half_sel)   cap_u <= cap_u + 8'd1;
  end

  // SRAM write staging
  logic [31:0] wr_d;
  logic        ks_csb0;
  logic [4:0]  ks_a0;
  logic [7:0]  is_csb0;
  logic [4:0]  is_a0;

  wire        is_k   = (cap_u < 8'd16);
  wire [6:0]  vimg   = cap_u[6:0] - 7'd16;
  wire [4:0]  v_row  = vimg[6:2];
  wire [1:0]  v_g    = vimg[1:0];

  always_ff @(posedge clk) begin
    if (clr) begin
      ks_csb0 <= 1'b1;
      is_csb0 <= 8'hFF;
    end else begin
      ks_csb0 <= 1'b1;
      is_csb0 <= 8'hFF;
      if (half_ev) begin
        if (is_k) ks_csb0 <= 1'b0;
        else      is_csb0[v_row[2:0]] <= 1'b0;
      end
    end
    if (half_ev) begin
      wr_d  <= {cl[3], cl[2], cl[1], cl[0]};
      ks_a0 <= {cap_u[3:0], ~half_sel};
      is_a0 <= {v_row[4:3], v_g, ~half_sel};
    end
  end

  // load-progress flags (visible 2 cycles after the SRAM write staging cycle)
  logic kok_p, row_p, stored_p;
  logic kern_ok;
  logic [5:0] rows_loaded;
  always_ff @(posedge clk) begin
    if (clr) begin
      kok_p <= 1'b0; row_p <= 1'b0; stored_p <= 1'b0;
      kern_ok <= 1'b0; rows_loaded <= 6'd0; stored_f <= 1'b0;
    end else begin
      kok_p    <= half_ev & half_sel & (cap_u == 8'd15);
      row_p    <= half_ev & half_sel & ~is_k & (v_g == 2'd3);
      stored_p <= half_ev & half_sel & (cap_u == 8'd143);
      if (kok_p)    kern_ok     <= 1'b1;
      if (row_p)    rows_loaded <= rows_loaded + 6'd1;
      if (stored_p) stored_f    <= 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Read-address generation
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (clr) begin
      rd_cnt   <= 8'd0;
      rd_addr  <= 32'd0;
    end else if (rd_issue) begin
      rd_cnt  <= rd_cnt + 8'd1;
      rd_addr <= (rd_cnt == 8'd15) ? 32'h0000_0100 : (rd_addr + 32'd8);
    end
  end

  // ---------------------------------------------------------------------------
  // WRITE PATH: decision counters, pipeline events, OSRAM reads, serializer
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (clr) wl_q <= '0;
    else     wl_q <= wl[NWL-2:0];
  end

  always_ff @(posedge clk) begin
    if (clr) begin
      wmap <= 3'd0; wwd <= 5'd0;
    end else if (wgo) begin
      if (wwd == 5'd29) begin wwd <= 5'd0; wmap <= wmap + 3'd1; end
      else              wwd <= wwd + 5'd1;
    end
  end

  // DRAM command / address registers
  always_ff @(posedge clk) begin
    if (clr) begin
      cmd_r <= 2'd0; addr_r <= 32'd0; rd_cmd_v <= 1'b0; waddr <= 32'h0000_0600;
    end else begin
      cmd_r    <= 2'd0;
      rd_cmd_v <= 1'b0;
      if (rd_issue) begin
        cmd_r <= 2'd1; addr_r <= rd_addr; rd_cmd_v <= 1'b1;
      end else if (wl[TC-1]) begin
        cmd_r <= 2'd2; addr_r <= waddr; waddr <= waddr + 32'd8;
      end
    end
  end

  // OSRAM read side (port 1) and serializer
  logic        os_csb1;
  logic [6:0]  os_a1;
  logic [31:0] os_dout;
  logic [31:0] W;
  logic        orp_buf;
  logic [4:0]  orp_wd;
  logic        hbuf;
  logic [4:0]  hwd;
  logic        fclr_pend, fclr_buf;
  logic        bt_act;
  logic [2:0]  bt_ctr;
  wire         bt_start = wl[TD-1];
  wire  [2:0]  jj       = bt_start ? 3'd0 : bt_ctr;
  wire         bt_v     = bt_start | bt_act;
  logic [1:0]  full_clr;              // pulse + buffer for clearing

  always_ff @(posedge clk) begin
    if (clr) begin
      os_csb1 <= 1'b1; orp_buf <= 1'b0; orp_wd <= 5'd0;
      fclr_pend <= 1'b0; bt_act <= 1'b0; bt_ctr <= 3'd0;
      oe_r <= 1'b0;
    end else begin
      os_csb1 <= 1'b1;
      oe_r    <= 1'b0;
      // read word 2*wd+1 (beats 0..3)
      if (wl[TD-4]) begin
        os_csb1 <= 1'b0;
        os_a1   <= {orp_buf, orp_wd, 1'b1};
        hbuf    <= orp_buf;
        hwd     <= orp_wd;
        if (orp_wd == 5'd29) begin orp_wd <= 5'd0; orp_buf <= ~orp_buf; end
        else                 orp_wd <= orp_wd + 5'd1;
      end
      // read word 2*wd (beats 4..7)
      if (wl[TD]) begin
        os_csb1   <= 1'b0;
        os_a1     <= {hbuf, hwd, 1'b0};
        fclr_pend <= (hwd == 5'd29);
        fclr_buf  <= hbuf;
      end
      // beat counter
      if (bt_start) begin bt_act <= 1'b1; bt_ctr <= 3'd1; end
      else if (bt_act) begin
        bt_ctr <= bt_ctr + 3'd1;
        if (bt_ctr == 3'd7) bt_act <= 1'b0;
      end
      if (bt_v) oe_r <= 1'b1;
    end
    // serializer register W and data register din_r (no reset needed)
    if (wl[TD-2] | wl[TD+2]) W <= os_dout;
    if (bt_v) din_r <= W[8*(3 - jj[1:0]) +: 8];
  end

  // ---------------------------------------------------------------------------
  // COMPUTE CONTROL (cmp_fsm, Moore one-hot) + counters + token generation
  // ---------------------------------------------------------------------------
  typedef enum logic [6:0] {
    C_IDL   = 7'b0000001,
    C_PREK  = 7'b0000010,
    C_PREH  = 7'b0000100,
    C_RUN   = 7'b0001000,
    C_STR   = 7'b0010000,
    C_STB   = 7'b0100000,
    C_FLUSH = 7'b1000000
  } cstate_t;
  cstate_t cst;

  logic [2:0] k;
  logic [3:0] p, q;
  logic [3:0] pc;
  logic       cdone;

  wire run   = (cst == C_RUN);
  wire pre_k = (cst == C_PREK);
  wire pre_h = (cst == C_PREH);
  wire iss_ev = run | pre_h;

  wire [3:0] pnext = (p == 4'd14) ? 4'd0 : (p + 4'd1);
  // rows needed in ISRAM before the prefetch of band p+1 (pass 0 only)
  wire [5:0] need  = (p >= 4'd13) ? 6'd32 : ({1'b0, p, 1'b0} + 6'd7);
  wire rows_ok     = (rows_loaded >= need);
  wire stall_pre   = (k == 3'd0) & (p <= 4'd13) & (q == 4'd13) & ~rows_ok;
  wire last_slot   = (p == 4'd14) & (q == 4'd15);

  always_ff @(posedge clk) begin
    if (clr) begin
      cst <= C_IDL; k <= 3'd0; p <= 4'd0; q <= 4'd0; pc <= 4'd0; cdone <= 1'b0;
    end else begin
      case (cst)
        C_IDL: begin
          pc <= 4'd0;
          if (kern_ok && (rows_loaded >= 6'd5) && !cdone) cst <= C_PREK;
        end
        C_PREK: begin
          pc <= pc + 4'd1;
          if (pc == 4'd3) begin cst <= C_PREH; p <= 4'd14; q <= 4'd14; k <= 3'd0; end
        end
        C_PREH: begin
          q <= q + 4'd1;
          if (q == 4'd15) begin cst <= C_RUN; p <= 4'd0; q <= 4'd0; end
        end
        C_RUN: begin
          if (q != 4'd15) begin
            q <= q + 4'd1;
            if (stall_pre) cst <= C_STR;
          end else begin
            q <= 4'd0;
            if (p != 4'd14) p <= p + 4'd1;
            else begin
              p <= 4'd0;
              k <= k + 3'd1;
              if (k == 3'd7) begin cst <= C_FLUSH; pc <= 4'd0; end
              else if (full[(k + 3'd1) & 3'd1]) cst <= C_STB;
            end
          end
        end
        C_STR: if (rows_ok) cst <= C_RUN;
        C_STB: if (!full[k[0]]) cst <= C_RUN;
        C_FLUSH: begin
          pc <= pc + 4'd1;
          if (pc == 4'd12) begin cst <= C_IDL; cdone <= 1'b1; end
        end
        default: cst <= C_IDL;
      endcase
    end
  end

  // ---- stage-A token (combinational) ----
  logic [TW-1:0] tok_a;
  logic [3:0]    kn_oh;
  always_comb begin
    kn_oh = 4'd0;
    if (pre_k) kn_oh[pc[1:0]] = 1'b1;
    else if (run && p == 4'd0 && q >= 4'd4 && q <= 4'd7 && k != 3'd7)
      kn_oh[q[1:0]] = 1'b1;
  end
  always_comb begin
    tok_a = '0;
    tok_a[T_V]    = run;
    tok_a[T_Q15]  = (q == 4'd15);
    tok_a[T_MROW] = (p == 4'd14);
    tok_a[T_MCOL] = (q == 4'd14);
    tok_a[T_ODD]  = q[0];
    tok_a[T_SH]   = iss_ev & q[0] & (q <= 4'd13);
    tok_a[T_CAPH] = iss_ev & (q == 4'd14);
    tok_a[T_HEAD] = iss_ev & (q == 4'd15);
    tok_a[T_KSW]  = run & (p == 4'd0) & (q == 4'd0);
    tok_a[T_BSEL +: 2] = (q >= 4'd14) ? pnext[1:0] : p[1:0];
    tok_a[T_KN +: 4]   = kn_oh;
  end

  // ---- ISRAM / KSRAM read-address registers (stage A -> visible next cycle) ----
  wire        isr_rd = iss_ev & (q[0] | (q >= 4'd14));
  wire  [2:0] wsel   = (q == 4'd14) ? 3'd0 : (q == 4'd15) ? 3'd1 : (q[3:1] + 3'd2);
  wire  [4:0] base   = (q >= 4'd14) ? {pnext, 1'b0} : {p, 1'b0};
  logic [7:0] is_csb1;
  logic [4:0] is_a1 [0:7];
  logic       ks_csb1;
  logic [4:0] ks_a1;

  genvar gb;
  generate
    for (gb = 0; gb < 8; gb++) begin : g_bank_rd
      wire [2:0] dd     = 3'(gb) - base[2:0];            // (b - base) mod 8
      wire       act    = (dd < 3'd5);
      wire [1:0] rowhi  = base[4:3] + {1'b0, (3'(gb) < base[2:0])};
      always_ff @(posedge clk) begin
        if (clr) is_csb1[gb] <= 1'b1;
        else     is_csb1[gb] <= ~(isr_rd & act);
        is_a1[gb] <= {rowhi, wsel};
      end
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (clr) ks_csb1 <= 1'b1;
    else     ks_csb1 <= ~(|kn_oh);
    ks_a1 <= pre_k ? {3'd0, pc[1:0]} : {(k + 3'd1), q[1:0]};
  end

  // ---- token pipeline: T1 (A+1), T2 (S0), ... T7 (W) ----
  logic [TW-1:0] t1, t2, t3, t4, t5, t6, t7;
  always_ff @(posedge clk) begin
    if (clr) begin
      t1 <= '0; t2 <= '0; t3 <= '0; t4 <= '0; t5 <= '0; t6 <= '0; t7 <= '0;
    end else begin
      t1 <= tok_a; t2 <= t1; t3 <= t2; t4 <= t3; t5 <= t4; t6 <= t5; t7 <= t6;
    end
  end

  // ---------------------------------------------------------------------------
  // SRAM instances
  // ---------------------------------------------------------------------------
  logic [31:0] ks_dout;
  logic [31:0] is_dout [0:7];
  logic        os_csb0;
  logic [6:0]  os_a0;
  logic [31:0] os_d0;

  sram_32x32_1r1w u_ksram (
    .clk0(clk), .csb0(ks_csb0), .addr0(ks_a0), .din0(wr_d),
    .clk1(clk), .csb1(ks_csb1), .addr1(ks_a1), .dout1(ks_dout)
  );

  generate
    for (gb = 0; gb < 8; gb++) begin : g_isram
      sram_32x32_1r1w u_isram (
        .clk0(clk), .csb0(is_csb0[gb]), .addr0(is_a0), .din0(wr_d),
        .clk1(clk), .csb1(is_csb1[gb]), .addr1(is_a1[gb]), .dout1(is_dout[gb])
      );
    end
  endgenerate

  sram_128x32_1r1w u_osram (
    .clk0(clk), .csb0(os_csb0), .addr0(os_a0), .din0(os_d0),
    .clk1(clk), .csb1(os_csb1), .addr1(os_a1), .dout1(os_dout)
  );

  // ---------------------------------------------------------------------------
  // S0: lane buffers, window register P5, kernel registers
  // ---------------------------------------------------------------------------
  logic [31:0] W0 [0:4];
  logic [31:0] W1 [0:4];
  logic [31:0] H  [0:4];
  logic [31:0] nw [0:4];

  wire [1:0] bsel2 = t2[T_BSEL +: 2];
  genvar gr;
  generate
    for (gr = 0; gr < 5; gr++) begin : g_lane
      wire [1:0] sel_r = bsel2 + 2'(gr / 2);
      always_comb begin
        case (sel_r)
          2'd0: nw[gr] = is_dout[0 + (gr % 2)];
          2'd1: nw[gr] = is_dout[2 + (gr % 2)];
          2'd2: nw[gr] = is_dout[4 + (gr % 2)];
          default: nw[gr] = is_dout[6 + (gr % 2)];
        endcase
      end
      always_ff @(posedge clk) begin
        if (t2[T_SH])   begin W0[gr] <= W1[gr]; W1[gr] <= nw[gr]; end
        if (t2[T_CAPH]) begin H[gr]  <= nw[gr]; end
        if (t2[T_HEAD]) begin W0[gr] <= H[gr];  W1[gr] <= nw[gr]; end
      end
    end
  endgenerate

  // window register P5 (5x5 signed bytes)
  logic signed [7:0] P5 [0:24];
  genvar gc;
  generate
    for (gr = 0; gr < 5; gr++) begin : g_win_r
      for (gc = 0; gc < 5; gc++) begin : g_win_c
        wire [63:0] lw = {W1[gr], W0[gr]};
        wire [7:0]  bb = t2[T_ODD] ? lw[8*(gc+2) +: 8] : lw[8*gc +: 8];
        always_ff @(posedge clk) begin
          if (t2[T_V]) P5[gr*5+gc] <= bb;
        end
      end
    end
  endgenerate

  // kernel registers: KN (shadow) and K
  logic [31:0] KN [0:3];
  logic signed [7:0] K [0:15];
  genvar gm;
  // KN: each word has its own constant-index driver
  generate
    for (gm = 0; gm < 4; gm++) begin : g_kn
      always_ff @(posedge clk) begin
        if (t2[T_KN + gm]) KN[gm] <= ks_dout;
      end
    end
  endgenerate

  // K: driven from ONE always_ff (a loop-indexed write from several blocks
  // makes vopt treat the whole array as multiply driven, vopt-7061)
  always_ff @(posedge clk) begin
    if (t2[T_KSW]) begin
      for (int m = 0; m < 4; m++)
        for (int n = 0; n < 4; n++)
          K[m*4+n] <= KN[m][8*n +: 8];
    end
  end

  // ---------------------------------------------------------------------------
  // S1: 64 multipliers + level 1-2 adders (per kernel row)  -> R1
  // ---------------------------------------------------------------------------
  logic signed [17:0] R1 [0:15];
  genvar ga, gbb;
  generate
    for (ga = 0; ga < 2; ga++) begin : g_s1a
      for (gbb = 0; gbb < 2; gbb++) begin : g_s1b
        for (gm = 0; gm < 4; gm++) begin : g_s1m
          always_ff @(posedge clk) begin
            if (t3[T_V])
              R1[(ga*2+gbb)*4+gm] <=
                  P5[(ga+gm)*5+gbb+0] * K[gm*4+0]
                + P5[(ga+gm)*5+gbb+1] * K[gm*4+1]
                + P5[(ga+gm)*5+gbb+2] * K[gm*4+2]
                + P5[(ga+gm)*5+gbb+3] * K[gm*4+3];
          end
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // S2: level 3-4 adders -> C
  // ---------------------------------------------------------------------------
  logic signed [19:0] Cc [0:3];
  genvar gu;
  generate
    for (gu = 0; gu < 4; gu++) begin : g_s2
      always_ff @(posedge clk) begin
        if (t4[T_V])
          Cc[gu] <= R1[gu*4+0] + R1[gu*4+1] + R1[gu*4+2] + R1[gu*4+3];
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // S3: Leaky ReLU (+ edge mask) and 4-input window sum -> S_reg
  // ---------------------------------------------------------------------------
  wire signed [21:0] am  [0:3];
  wire signed [21:0] iv  [0:3];
  generate
    for (gu = 0; gu < 4; gu++) begin : g_s3
      wire signed [19:0] cu  = Cc[gu];
      wire               neg = cu[19];
      wire signed [19:0] fa  = cu >>> 2;
      wire               inc = neg & (cu[1] | cu[0]) & (ROUND_V4 | (&cu[19:2]));
      wire               msk = (t5[T_MROW] & (gu / 2 == 1)) | (t5[T_MCOL] & (gu % 2 == 1));
      wire signed [21:0] sx_f = {{2{fa[19]}}, fa};
      wire signed [21:0] sx_c = {{2{cu[19]}}, cu};
      assign am[gu] = msk ? 22'sd0 : (neg ? sx_f : sx_c);
      assign iv[gu] = (msk | ~inc) ? 22'sd0 : 22'sd1;
    end
  endgenerate

  logic signed [21:0] S_reg;
  always_ff @(posedge clk) begin
    if (t5[T_V]) S_reg <= am[0] + am[1] + am[2] + am[3] + iv[0] + iv[1] + iv[2] + iv[3];
  end

  // ---------------------------------------------------------------------------
  // S4: pool rule, clip, bias, pad -> Y_reg
  // ---------------------------------------------------------------------------
  wire        sat_hi = ~S_reg[21] & (|S_reg[20:9]);
  wire        sat_lo =  S_reg[21] & ~(&S_reg[20:9]);
  wire        incS   =  S_reg[21] & (S_reg[1] | S_reg[0]) & (ROUND_V4 | (&S_reg[21:2]));
  wire [7:0]  low8   = S_reg[9:2] + {7'd0, incS};
  logic [7:0] y_reg;
  always_ff @(posedge clk) begin
    if (t6[T_V])
      y_reg <= t6[T_Q15] ? 8'h00 :
               sat_hi    ? 8'hFF :
               sat_lo    ? 8'h00 : {~low8[7], low8[6:0]};
  end

  // ---------------------------------------------------------------------------
  // W: packer, OSRAM write port, buffer flags
  // ---------------------------------------------------------------------------
  logic [7:0] pl0, pl1, pl2;
  logic [7:0] pk_cnt;
  logic       obuf_w;
  logic       fs0, fs1, fs_buf0, fs_buf1;

  always_ff @(posedge clk) begin
    if (clr) begin
      pk_cnt <= 8'd0; obuf_w <= 1'b0; os_csb0 <= 1'b1;
      fs0 <= 1'b0; fs1 <= 1'b0;
    end else begin
      os_csb0 <= 1'b1;
      fs0     <= 1'b0;
      fs1     <= fs0;
      fs_buf1 <= fs_buf0;
      if (t7[T_V]) begin
        case (pk_cnt[1:0])
          2'd0: pl0 <= y_reg;
          2'd1: pl1 <= y_reg;
          2'd2: pl2 <= y_reg;
          default: begin
            os_d0   <= {y_reg, pl2, pl1, pl0};
            os_csb0 <= 1'b0;
            os_a0   <= {obuf_w, pk_cnt[7:2]};
          end
        endcase
        if (pk_cnt == 8'd239) begin
          pk_cnt  <= 8'd0;
          obuf_w  <= ~obuf_w;
          fs0     <= 1'b1;
          fs_buf0 <= obuf_w;
        end else begin
          pk_cnt <= pk_cnt + 8'd1;
        end
      end
    end
  end

  // full flags: set by the packer pipeline, cleared when the last word of a
  // map has been fetched by the serializer
  wire fclr_now = wl[TD+2] & fclr_pend;
  always_ff @(posedge clk) begin
    if (clr) full <= 2'b00;
    else begin
      if (fs1)       full[fs_buf1]  <= 1'b1;
      if (fclr_now)  full[fclr_buf] <= 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // Output ports  (adapt to the stub's names/widths here if they differ)
  // ---------------------------------------------------------------------------
  assign ready = ready_r;
  assign CMD   = cmd_r;
  assign addr  = addr_r;
  assign din   = din_r;
  assign oe    = oe_r;

endmodule
// ===== AI-GENERATED CODE END =====
