#!/usr/bin/env python3
"""Creates mutants/<id>/ : the faulty RTL file, a unified diff, and DESCRIPTION.txt.
Each mutant replaces ONE file of rtl/ (the rest of the design is the golden RTL)."""
import os, difflib, shutil
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # cnn_ext/
RTL = os.path.join(os.path.dirname(ROOT), "srcs", "rtl")
rd = lambda f: open(f"{RTL}/{f}").read()

SLOW_DECL = ("  logic td;                           // tile sum complete (tacc stable)\n",
             "  logic td;                           // tile sum complete (tacc stable)\n"
             "  logic [9:0] idle_cnt;               // MUTANT: artificial 600-cycle FC start delay\n"
             "  always_ff @(posedge clk) idle_cnt <= (clr || st != F_IDLE) ? 10'd0 : idle_cnt + 10'd1;   // reset by clr: 4-state safe\n")
SLOW_COND = ("F_IDLE: if (!done && ofull[m[0]] && wfull[tbuf]) st <= F_RUN;",
             "F_IDLE: if (!done && ofull[m[0]] && wfull[tbuf] && idle_cnt >= 10'd600) st <= F_RUN;")
CREDIT = ("cdiff[7:0] <= 8'd1", "cdiff[7:0] <= 8'd2")

# id, file, [(old,new),...], test(mode seed nc), expected, description
M = [
 ("M1_argmax_tiebreak", "cnn_fc.sv", [("(val > best_val)", "(val >= best_val)")], ("ties",1,10), "DETECT",
  "Argmax uses >= instead of >: on equal logits the LAST class wins instead of the first."),
 ("M2_acc_width_24", "dut_cnn.sv", [("localparam int ACC_W  = 27;", "localparam int ACC_W  = 24;")], ("accmax",1,10), "DETECT",
  "Class accumulator narrowed from 27 to 24 bits: overflows for large logits (+-58M)."),
 ("M3_fc_ignores_weight_ready", "cnn_fc.sv", [("ofull[m[0]] && wfull[tbuf]", "ofull[m[0]]")], ("mixed",1,10), "DETECT",
  "FC starts a tile before the weight tile is completely loaded."),
 ("M4_bias_not_added", "cnn_fc.sv", [("(m == 3'd0) ? {{(ACC_W-16){bias_c[15]}}, bias_c}", "(m == 3'd0) ? {ACC_W{1'b0}}")], ("mixed",1,10), "DETECT",
  "Bias is replaced by 0 on the first map."),
 ("M5_weight_lane_swap", "cnn_fc.sv", [("{8'h00, bd, wacc[15:0]}", "{8'h00, wacc[7:0], bd, wacc[15:8]}")], ("mixed",1,10), "DETECT",
  "Weight bytes of the last word of every row are put in the wrong lanes."),
 ("M6_tile_drops_last_word", "cnn_fc.sv", [("F_RUN : if (w_last) st <= F_WAIT;", "F_RUN : if (w == 6'd58) st <= F_WAIT;")], ("mixed",1,10), "DETECT",
  "Tile read sequence stops one word early (59 of 60 words)."),
 ("M7_tile_acc_not_cleared", "cnn_fc.sv", [("tacc <= (mt[0] ? 24'sd0 : tacc)", "tacc <= (1'b0 ? 24'sd0 : tacc)")], ("mixed",1,10), "DETECT",
  "Tile accumulator is not cleared at the first word of a tile (sums leak across tiles)."),
 ("M8_credit_relaxed_normal_fc", "dut_cnn.sv", [CREDIT], ("mixed",1,10), "SURVIVES",
  "Weight credit allows 3 tiles in flight. EXPECTED TO SURVIVE: the real FC is ~3x faster than the DRAM weight stream so the interlock never binds (equivalent behaviour)."),
 ("M9_slow_fc_real_credit", "cnn_fc.sv", [SLOW_DECL, SLOW_COND], ("mixed",1,10), "CONTROL_PASS",
  "CONTROL: FC artificially slowed (600 idle cycles per tile) with the REAL credit logic. Must still PASS (interlock throttles DRAM correctly)."),
 ("M10_slow_fc_relaxed_credit", "MULTI", [], ("mixed",1,10), "DETECT",
  "Slow FC (as M9) AND relaxed credit: the DRAM overwrites unconsumed weight tiles. Proves the interlock is necessary."),
]

os.makedirs(f"{ROOT}/mutants", exist_ok=True)
for d in os.listdir(f"{ROOT}/mutants"):
    if d.startswith("M") and os.path.isdir(f"{ROOT}/mutants/{d}"): shutil.rmtree(f"{ROOT}/mutants/{d}")
rows = []
for mid, f, edits, test, exp, desc in M:
    d = f"{ROOT}/mutants/{mid}"; os.makedirs(d)
    if f == "MULTI":                       # M10 = slow-FC edit on cnn_fc.sv + relaxed credit on dut.sv
        files = {"cnn_fc.sv": [SLOW_DECL, SLOW_COND], "dut_cnn.sv": [CREDIT]}
    else:
        files = {f: edits}
    for fn, eds in files.items():
        src = rd(fn); new = src
        for o, n in eds:
            assert o in new, f"{mid}: pattern not found: {o[:50]}"
            new = new.replace(o, n, 1)
        open(f"{d}/{fn}", "w").write(new)
        diff = "".join(difflib.unified_diff(src.splitlines(1), new.splitlines(1), f"srcs/rtl/{fn}", f"mutants/{mid}/{fn}", n=1))
        open(f"{d}/{fn}.diff", "w").write(diff)
    open(f"{d}/DESCRIPTION.txt", "w").write(
        f"{mid}\nfiles replaced: {', '.join(files)}\ntest: mode={test[0]} seed={test[1]} NC={test[2]}\n"
        f"expected: {exp}\n\n{desc}\n")
    rows.append(f"{mid} {test[0]} {test[1]} {test[2]} {exp}")
open(f"{ROOT}/mutants/manifest.txt", "w").write("\n".join(rows) + "\n")
print(f"{len(M)} mutants written to mutants/")
