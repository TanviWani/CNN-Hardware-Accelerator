# Open-source synthesis estimate (NOT Design Compiler) - `dut_cnn`, NC=10
Yosys 0.33 + ABC -> Nangate45 **typical** corner -> OpenSTA 3.2.0. Reproduce: `cd cnn_ext && bash synth_open/run_synth.sh 1.85`.
Raw reports: `synth_open/out_1.85/sta_report.txt`, `yosys_stat.txt`. For Design Compiler results run `make synth` (see README_CNN.md).

| Item | Value |
|---|---|
| Clock period met | 1.85 ns; STA minimum period 1.81 ns (552 MHz) |
| Setup slack @1.85 ns | +0.040 ns (arrival 1.669, library setup 0.041, uncertainty 0.10) |
| Hold slack @1.85 ns | +0.026 ns (ideal clock; arrival 0.078 vs required 0.052) |
| Standard cells / flops | 45,877 / 2,864 (+ 11 SRAM macro instances: 9 x 32x32, 2 x 128x32) |
| Area | 86,424 um2 total = ~62,900 logic + 23,500 SRAM (ASSUMED macro areas) |
| Cycles per image (NC=10) | 19,338 (NC=1: 3,066, NC=3: 6,680, NC=7: 13,916, NC=16: 30,188) |
| Time per image | 19,338 x 1.85 ns = 35.8 us |

Caveats: typical corner, ideal clock, no wire load; SRAM timing/area from `sram_macros_assumed.lib` (clk->dout 1.0 ns, setup 0.15 ns);
Design Compiler in this course uses the **slow** corner (DFF clk->Q 0.638 ns, setup 0.546 ns in `Constraints.tcl`) and the OpenRAM macro libraries,
so its achievable period will be several times larger. Use these numbers to compare design variants, not as predictions of the DC report.
Longest path ~1.7 ns is in the unchanged feature stage (multiply + add); the classifier is shorter (51 vs 60 gate levels).
