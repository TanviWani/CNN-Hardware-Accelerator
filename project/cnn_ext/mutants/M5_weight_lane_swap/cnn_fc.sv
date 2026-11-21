// ===== AI-GENERATED CODE START (Claude, Anthropic) - prompts documented in report appendix =====
// =============================================================================
// Fully-connected stage of the CNN accelerator
//   cnn_flatten : (map, class, word) loop sequencer = the flattening unit
//   cnn_mac4    : 4 unsigned x signed multipliers + 2-level adder tree (pipelined)
//   cnn_argmax  : running first-maximum comparator
//   cnn_fc      : control FSM, tile accumulator, per-class accumulators, bias, argmax
//   cnn_wload   : weight/bias stream assembler + weight-tile SRAM write side
//
// Data organisation (see README):
//   feature map m   : 60 x 32-bit words in OSRAM buffer m[0]; word w = row*4 + col/4,
//                     byte lane = col%4, col 15 is a zero pad column.
//   weight tile t   : 60 x 32-bit words in WSRAM buffer t[0], same word/lane layout
//                     (pad bytes are zero, so the pad lane never contributes).
//   tile (m,c)      : dot product of map m with the class-c weights of that map.
//   logit[c]        = bias[c] + sum over the 8 tiles (m,c).
// =============================================================================

// -----------------------------------------------------------------------------
// Flattening unit.  Walks the 3-D feature volume in the same order the weights
// are stored (map-major, then class, then row-major words) WITHOUT copying the
// data: it only generates OSRAM / WSRAM read addresses.
//   flat feature index f = m*225 + row*15 + col   <->  (m, w=row*4+col/4, lane=col%4)
// -----------------------------------------------------------------------------
module cnn_flatten #(
  parameter int NC = 10
)(
  input  wire       clk,
  input  wire       clr,
  input  wire       step_w,       // advance to next word inside the tile
  input  wire       step_tile,    // advance to next (m,c) tile
  output logic [2:0] m,           // feature map
  output logic [3:0] c,           // class
  output logic [5:0] w,           // word inside the tile (0..59)
  output logic       tbuf,        // weight-tile ping-pong buffer
  output wire  [6:0] o_addr,      // OSRAM read address
  output wire  [6:0] w_addr,      // WSRAM read address
  output wire        w_first, w_last, c_last, m_last
);
  assign o_addr  = {m[0], w};
  assign w_addr  = {tbuf, w};
  assign w_first = (w == 6'd0);
  assign w_last  = (w == 6'd59);
  assign c_last  = (c == 4'(NC - 1));
  assign m_last  = (m == 3'd7);

  always_ff @(posedge clk) begin
    if (clr) begin
      m <= 3'd0; c <= 4'd0; w <= 6'd0; tbuf <= 1'b0;
    end else begin
      if (step_w) w <= w_last ? 6'd0 : (w + 6'd1);
      if (step_tile) begin
        tbuf <= ~tbuf;
        if (c_last) begin c <= 4'd0; m <= m + 3'd1; end
        else        c <= c + 4'd1;
      end
    end
  end
endmodule

// -----------------------------------------------------------------------------
// 4-lane MAC front end.  Operands are captured only when valid (operand
// isolation: idle multipliers see constant inputs and do not toggle).
//   v_in -> [operand regs] -> [products] -> [pair sums] -> [quad sum] -> v_out
// -----------------------------------------------------------------------------
module cnn_mac4 (
  input  wire        clk,
  input  wire        clr,
  input  wire        v_in,
  input  wire [1:0]  t_in,          // {last, first} tags travel with the data
  input  wire [31:0] f_in,          // 4 x unsigned 8-bit features
  input  wire [31:0] w_in,          // 4 x signed   8-bit weights
  output logic       v_out,
  output logic [1:0] t_out,
  output logic signed [17:0] s_out
);
  logic [31:0] fd, wd;
  logic        v1, v2, v3;
  logic [1:0]  t1, t2, t3;
  logic signed [15:0] pr [0:3];       // |product| <= 255*128 -> fits 16 bit signed
  logic signed [16:0] s01, s23;

  wire signed [16:0] p17 [0:3];
  genvar j;
  generate
    for (j = 0; j < 4; j++) begin : g_mul
      wire signed [8:0] fx = $signed({1'b0, fd[8*j +: 8]});
      wire signed [7:0] wx = $signed(wd[8*j +: 8]);
      assign p17[j] = fx * wx;
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (clr) begin v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v_out <= 1'b0; end
    else     begin v1 <= v_in; v2 <= v1; v3 <= v2; v_out <= v3; end
    t1 <= t_in; t2 <= t1; t3 <= t2; t_out <= t3;
    if (v_in) begin fd <= f_in; wd <= w_in; end
    for (int k = 0; k < 4; k++) pr[k] <= p17[k][15:0];
    s01   <= pr[0] + pr[1];
    s23   <= pr[2] + pr[3];
    s_out <= s01 + s23;
  end
endmodule

// -----------------------------------------------------------------------------
// Running argmax: strict '>' so ties keep the lowest class index (numpy argmax).
// -----------------------------------------------------------------------------
module cnn_argmax #(
  parameter int W  = 27,
  parameter int IW = 4
)(
  input  wire                 clk,
  input  wire                 v,
  input  wire                 first,
  input  wire [IW-1:0]        idx,
  input  wire signed [W-1:0]  val,
  output logic [IW-1:0]       best_idx,
  output logic signed [W-1:0] best_val
);
  always_ff @(posedge clk) begin
    if (v && (first || (val > best_val))) begin
      best_val <= val;
      best_idx <= idx;
    end
  end
endmodule

// -----------------------------------------------------------------------------
// FC engine
// -----------------------------------------------------------------------------
module cnn_fc #(
  parameter int NC    = 10,
  parameter int ACC_W = 27
)(
  input  wire        clk,
  input  wire        clr,
  // feature (OSRAM) and weight-tile (WSRAM) buffers
  input  wire [1:0]  ofull,
  input  wire [1:0]  wfull,
  output logic       os_csb1,
  output logic [6:0] os_a1,
  input  wire [31:0] os_dout,
  output logic       ws_csb1,
  output logic [6:0] ws_a1,
  input  wire [31:0] ws_dout,
  output wire        wrel_v,        // weight tile fully read -> buffer free
  output wire        wrel_b,
  output wire        ofree_v,       // feature map fully consumed -> buffer free
  output wire        ofree_b,
  output logic [7:0] tcons,         // number of weight tiles consumed so far
  input  wire [NC*16-1:0] bias_vec, // signed 16-bit per class
  output logic       done,
  output wire  [3:0] pred,
  output wire  [NC*ACC_W-1:0] logits
);
  typedef enum logic [3:0] { F_IDLE = 4'b0001, F_RUN = 4'b0010, F_WAIT = 4'b0100, F_CMP = 4'b1000 } fstate_t;
  fstate_t st;

  logic [2:0] m; logic [3:0] c; logic [5:0] w; logic tbuf;
  wire  [6:0] o_addr, w_addr;
  wire        w_first, w_last, c_last, m_last;
  wire        run = (st == F_RUN);

  cnn_flatten #(.NC(NC)) u_flat (
    .clk(clk), .clr(clr), .step_w(run), .step_tile(st == F_CMP),
    .m(m), .c(c), .w(w), .tbuf(tbuf), .o_addr(o_addr), .w_addr(w_addr),
    .w_first(w_first), .w_last(w_last), .c_last(c_last), .m_last(m_last)
  );

  assign wrel_v  = run & w_last;
  assign wrel_b  = tbuf;
  assign ofree_v = run & w_last & c_last;
  assign ofree_b = m[0];

  // ---- control FSM (Moore, one-hot) ----
  logic td;                           // tile sum complete (tacc stable)
  always_ff @(posedge clk) begin
    if (clr) begin
      st <= F_IDLE; done <= 1'b0; tcons <= 8'd0;
    end else begin
      if (wrel_v) tcons <= tcons + 8'd1;
      case (st)
        F_IDLE: if (!done && ofull[m[0]] && wfull[tbuf]) st <= F_RUN;
        F_RUN : if (w_last) st <= F_WAIT;
        F_WAIT: if (td) st <= F_CMP;
        F_CMP : begin
          st <= F_IDLE;
          if (m_last && c_last) done <= 1'b1;
        end
        default: st <= F_IDLE;
      endcase
    end
  end

  // ---- SRAM read issue (registered: address/csb visible next cycle) ----
  logic va, vb; logic [1:0] ta, tb_;
  always_ff @(posedge clk) begin
    if (clr) begin os_csb1 <= 1'b1; ws_csb1 <= 1'b1; va <= 1'b0; vb <= 1'b0; end
    else begin
      os_csb1 <= ~run; ws_csb1 <= ~run;
      va <= run; vb <= va;
    end
    if (run) begin os_a1 <= o_addr; ws_a1 <= w_addr; end
    ta <= {w_last, w_first}; tb_ <= ta;
  end

  // ---- MAC pipeline ----
  wire        mv; wire [1:0] mt; wire signed [17:0] ms;
  cnn_mac4 u_mac (
    .clk(clk), .clr(clr), .v_in(vb), .t_in(tb_), .f_in(os_dout), .w_in(ws_dout),
    .v_out(mv), .t_out(mt), .s_out(ms)
  );

  // ---- per-tile accumulator (24-bit: 225*255*128 < 2^23) ----
  logic signed [23:0] tacc;
  always_ff @(posedge clk) begin
    if (clr) td <= 1'b0;
    else begin
      td <= 1'b0;
      if (mv) begin
        tacc <= (mt[0] ? 24'sd0 : tacc) + {{6{ms[17]}}, ms};
        td   <= mt[1];
      end
    end
  end

  // ---- per-class accumulators (bias added on the first map) ----
  logic signed [ACC_W-1:0] acc [0:NC-1];
  wire  signed [15:0]      bias_c = $signed(bias_vec[16*c +: 16]);
  wire  signed [ACC_W-1:0] base_nx = (m == 3'd0) ? {{(ACC_W-16){bias_c[15]}}, bias_c} : acc[c];
  // Timing: (m,c) are static for >= 60 cycles before the tile sum completes, so the
  // class mux + bias select is registered here and the 27-bit adder starts at a flop
  // (removes the c -> 10:1 mux -> adder path, the longest path of the FC stage).
  logic signed [ACC_W-1:0] base;
  always_ff @(posedge clk) base <= base_nx;
  wire  signed [ACC_W-1:0] logit_nx = base + {{(ACC_W-24){tacc[23]}}, tacc};
  logic signed [ACC_W-1:0] logit_r;
  logic cmp_v;
  always_ff @(posedge clk) begin
    if (clr) cmp_v <= 1'b0;
    else     cmp_v <= td & m_last;
    if (td) begin
      acc[c]  <= logit_nx;
      logit_r <= logit_nx;
`ifdef CNN_DEBUG
      $display("[FC ] t=%0t tile(m=%0d,c=%0d) sum=%0d  running logit=%0d", $time, m, c, tacc, logit_nx);
`endif
    end
  end

  // ---- argmax over the final logits (compared as they are produced) ----
  logic signed [ACC_W-1:0] best_val;
  logic [3:0] best_idx;
  cnn_argmax #(.W(ACC_W), .IW(4)) u_argmax (
    .clk(clk), .v(cmp_v), .first(c == 4'd0), .idx(c), .val(logit_r),
    .best_idx(best_idx), .best_val(best_val)
  );
  assign pred = best_idx;

  genvar gi;
  generate
    for (gi = 0; gi < NC; gi++) begin : g_lg
      assign logits[gi*ACC_W +: ACC_W] = acc[gi];
    end
  endgenerate
endmodule

// -----------------------------------------------------------------------------
// Weight / bias stream loader.
//   The DRAM weight stream (map-major, class, 225 bytes per tile in row-major
//   15x15 order) arrives 1 byte per cycle.  Every 15 bytes (end of a row) a zero
//   pad byte is inserted so that weight words line up with the 16-wide OSRAM
//   feature words.  The pad byte is always lane 3 of a word, so no extra cycle
//   is needed: words complete at col = 3, 7, 11 (lane 3) and col = 14 (lane 2 +
//   zero pad).  Words go to the weight-tile SRAM (ping-pong, 60 words per tile).
// -----------------------------------------------------------------------------
module cnn_wload (
  input  wire        clk,
  input  wire        clr,
  input  wire        bv,           // byte valid (weight stream)
  input  wire [7:0]  bd,           // byte (stream order)
  input  wire        rel_v,        // FC finished reading tile in buffer rel_b
  input  wire        rel_b,
  output logic       ws_csb0,
  output logic [6:0] ws_a0,
  output logic [31:0] ws_d0,
  output logic [1:0] wfull
);
  logic [3:0]  col, row;
  logic [5:0]  wwa;
  logic        wbuf;
  logic [23:0] wacc;
  logic        wset, wset_b;

  wire last_col  = (col == 4'd14);
  wire word_done = (col[1:0] == 2'd3) | last_col;
  wire [31:0] word_nx = last_col ? {8'h00, wacc[7:0], bd, wacc[15:8]} : {bd, wacc[23:0]};

  always_ff @(posedge clk) begin
    if (clr) begin
      col <= 4'd0; row <= 4'd0; wwa <= 6'd0; wbuf <= 1'b0;
      ws_csb0 <= 1'b1; wset <= 1'b0; wfull <= 2'b00;
    end else begin
      ws_csb0 <= 1'b1;
      wset    <= 1'b0;
      if (bv) begin
        if (!word_done) wacc[8*col[1:0] +: 8] <= bd;
        if (word_done) begin
          ws_csb0 <= 1'b0;
          ws_a0   <= {wbuf, wwa};
          ws_d0   <= word_nx;
          wwa     <= wwa + 6'd1;
        end
        if (last_col) begin
          col <= 4'd0;
          if (row == 4'd14) begin
            row <= 4'd0; wwa <= 6'd0; wbuf <= ~wbuf;
            wset <= 1'b1; wset_b <= wbuf;
          end else row <= row + 4'd1;
        end else col <= col + 4'd1;
      end
      // flag update one cycle after the last write was staged (write is in the SRAM by then)
      if (wset)  wfull[wset_b] <= 1'b1;
      if (rel_v) wfull[rel_b]  <= 1'b0;
    end
  end
endmodule
// ===== AI-GENERATED CODE END =====
