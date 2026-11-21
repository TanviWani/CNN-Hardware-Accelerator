#!/usr/bin/env python3
"""Summarise a full-CNN run: simulation cycles (tb_cnn) + Design Compiler cells/area/timing.
Usage: cnn_report.py --build <build_dir> --clock <ns> --nc <classes> [--out file]
Reads  <build>/cnn/cnn_result.txt  (written by tb_cnn.sv)
       <build>/synth/reports/cell_report_final.rpt, timing_max_slow*.rpt, timing_min_fast_holdcheck*.rpt
Exit code 1 if the simulation failed, SRAM macros are unlinked, or timing is violated (report is still written)."""
import argparse, glob, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--build", required=True); ap.add_argument("--clock", type=float, required=True)
ap.add_argument("--nc", type=int, default=10); ap.add_argument("--out")
a = ap.parse_args()
R = os.path.join(a.build, "synth", "reports")
problems, lines = [], []

# ---- simulation ----
sim = {}
try:
    for l in open(os.path.join(a.build, "cnn", "cnn_result.txt")):
        k, _, v = l.strip().partition("="); sim[k] = v
except OSError:
    problems.append("no simulation result (build/cnn/cnn_result.txt) - run: make vsim-cnn-c")
cycles = int(sim["cycles_run1"]) if "cycles_run1" in sim else None
if sim.get("result") != "PASS": problems.append(f"simulation result: {sim.get('result', 'missing')}")

# ---- cell / area ----
cell_rpt = os.path.join(R, "cell_report_final.rpt")
n_comb = n_seq = n_mac = 0; a_comb = a_seq = a_mac = 0.0; total_cells = total_area = None; unresolved = False; macros = {}
try:
    txt = open(cell_rpt).read().splitlines()
    unresolved = any("unresolved reference" in l for l in txt)
    start = next((k for k, l in enumerate(txt) if l.startswith("-----")), 0) + 1
    cur = None                                   # (name, ref) of the entry whose area line is still to come
    hier_n = 0; hier_a = 0.0
    def add(ref, area, attrs):
        global n_comb, n_seq, n_mac, a_comb, a_seq, a_mac
        if ref.startswith("sram_"):               n_mac += 1; a_mac += area; macros[ref] = macros.get(ref, 0) + 1
        elif re.match(r"(S?DFF|DLH|DLL)", ref):    n_seq += 1; a_seq += area
        else:                                      n_comb += 1; a_comb += area
    for l in txt[start:]:
        if not l.strip() or l.startswith("-----"): continue
        t = re.match(r"^Total\s+(\d+)\s+cells\s+([0-9.]+)", l)
        if t: total_cells, total_area = int(t.group(1)), float(t.group(2)); continue
        toks = l.split()
        if not l[0].isspace():                    # new entry:  name [reference [library | area attrs]]
            k = next((x for x, tk in enumerate(toks) if x >= 1 and re.fullmatch(r"[0-9]+\.[0-9]+", tk)), None)
            if k is not None and k >= 2:          # whole entry on one line: name reference area [attrs]
                add(toks[k - 1], float(toks[k]), toks[k + 1:]); cur = None
            else:
                cur = [toks[0], toks[1] if len(toks) > 1 else None]
        elif cur is not None:                     # area line:  [reference] area [attributes]
            k = next((x for x, tk in enumerate(toks) if re.fullmatch(r"[0-9]+\.[0-9]+", tk)), None)
            if k is None: continue
            ref = toks[k - 1] if k > 0 else cur[1]
            add(ref or "?", float(toks[k]), toks[k + 1:]); cur = None
except OSError:
    problems.append("no cell report - run: make synth")
if total_cells is not None and (n_comb + n_seq + n_mac != total_cells or abs(a_comb + a_seq + a_mac - total_area) > 0.01 * total_area):
    problems.append(f"report parser did not reconcile with the DC total ({n_comb+n_seq+n_mac} cells / {a_comb+a_seq+a_mac:,.1f} um^2 parsed vs {total_cells} / {total_area:,.1f}) - tell the author")
if unresolved or (n_mac and a_mac == 0.0):
    problems.append("SRAM macros NOT linked in Design Compiler (unresolved references / zero macro area): area and SRAM timing are incomplete")

# ---- timing ----
def first_slack(pattern):
    for f in sorted(glob.glob(os.path.join(R, pattern))):
        for l in open(f):
            m = re.search(r"slack \((MET|VIOLATED)\)\s+(-?[0-9.]+)", l)
            if m: return float(m.group(2)), m.group(1), os.path.basename(f)
    return None, None, None
ss, sst, sf = first_slack("timing_max_slow.rpt")
hs, hst, hf = first_slack("timing_min_fast_holdcheck*.rpt")
if sst == "VIOLATED": problems.append("setup timing VIOLATED")
if hst == "VIOLATED": problems.append("hold timing VIOLATED")
min_period = a.clock - ss if ss is not None and ss >= 0 else None

def fmt(x, f="{:,.4f}"): return "n/a" if x is None else f.format(x)
L = lines.append
L("=" * 74); L(f" FULL CNN ACCELERATOR - SUMMARY   (NC = {a.nc} classes, Design Compiler slow corner)"); L("=" * 74)
L(f" Simulation (Questa, tb_cnn):  {sim.get('result', 'n/a')}")
L(f" Clock cycle count / image  :  {cycles:,}" if cycles else " Clock cycle count / image  :  n/a")
L(f" Clock period (constraint)  :  {a.clock:.3f} ns   ({1000/a.clock:.1f} MHz)")
L(f" Min period estimate        :  {fmt(min_period, '{:.3f} ns')}   (= period - setup slack {fmt(ss)}; DC stops once timing is met)")
if cycles:
    L(f" Total execution time       :  {cycles*a.clock/1000:,.2f} us per image at the constraint period")
    if min_period: L(f"                               {cycles*min_period/1000:,.2f} us at the min-period estimate")
L("-" * 74)
L(f" Cells (total)              :  {total_cells if total_cells is not None else 'n/a'}   "
  f"[combinational {n_comb}, sequential {n_seq}, SRAM macros {n_mac}]")
L(f" Cell area (std cells)      :  {fmt(a_comb + a_seq, '{:,.1f}')} um^2   [combinational {a_comb:,.1f}, sequential {a_seq:,.1f}]")
L(f" SRAM macro area            :  {fmt(a_mac, '{:,.1f}')} um^2   {macros if macros else ''}")
L(f" Total area (DC report)     :  {fmt(total_area, '{:,.1f}')} um^2")
L("-" * 74)
L(f" Setup slack (slow corner)  :  {fmt(ss)} ns  {sst or ''}   [{sf or 'n/a'}]")
L(f" Hold slack  (fast corner)  :  {fmt(hs)} ns  {hst or ''}   [{hf or 'n/a'}]")
L("=" * 74)
if problems:
    L(" PROBLEMS:"); [L(f"  - {p}") for p in problems]
else: L(" All checks OK (simulation PASS, SRAM macros linked, timing met).")
L("=" * 74)
out = "\n".join(lines); print(out)
if a.out: open(a.out, "w").write(out + "\n")
sys.exit(1 if problems else 0)
