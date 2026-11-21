#!/usr/bin/env python3
"""Golden model + DRAM image generator for the full CNN accelerator.

Network (all integer arithmetic, bit-exact with the RTL):
  image 32x32 int8  --conv 4x4 x8 kernels (valid, correlation)--> 8 x 29x29
  --leaky ReLU (x>=0 ? x : trunc(x/4))--> --2x2 avg-pool/4, trunc-to-zero, clip[-128,127], +128-->
  8 x 15x15 uint8 (edge windows are partial: out-of-range conv taps count as 0)
  --flatten (map, row, col)--> 1800 --FC (int8 weights, int16 bias)--> NC int logits --argmax-->

DRAM image (64-bit words, byte address a lives in bits [8*(a%8)+:8], beats go MSB first):
  0x0000  kernels  8 x 16 B (row-major)                      [feature stage, unchanged]
  0x0100  image    32 x 32 B (row-major)                     [feature stage, unchanged]
  0x1000  bias[c]  int16 little-endian, NC*2 B               [STREAM order, see below]
  0x2000  weights  tiles (m, c): 225 B each, order m-major,  [STREAM order]
                   tile byte i = w[c][m*225 + i], i = row*15+col
  0x1100  result   written by the DUT                         [STREAM order]
"STREAM order" = bytes in the order they appear on the 8-bit bus (beat 0 first).
Stream byte s of a burst lives in word bits [63-8*(s%8) -: 8].
"""
import argparse, os
import numpy as np

NF_MAPS, IMG, KSZ, CONV, POOL = 8, 32, 4, 29, 15
FEAT_PER_MAP = 225
N_FLAT = NF_MAPS * FEAT_PER_MAP
BIAS_BASE, RES_BASE, WGT_BASE = 0x1000, 0x1100, 0x2000
DRAM_WORDS = 16384


def trunc_div(x, d):
    """integer division rounding toward zero"""
    x = np.asarray(x, dtype=np.int64)
    return np.where(x >= 0, x // d, -((-x) // d))


def features(img, K):
    """-> uint8 array [8][15][15]"""
    out = np.zeros((NF_MAPS, POOL, POOL), dtype=np.int64)
    for k in range(NF_MAPS):
        C = np.zeros((CONV, CONV), dtype=np.int64)
        for y in range(CONV):
            for x in range(CONV):
                C[y, x] = int(np.sum(img[y:y + 4, x:x + 4].astype(np.int64) * K[k].astype(np.int64)))
        L = np.where(C >= 0, C, trunc_div(C, 4))                  # leaky ReLU, slope 1/4, trunc-to-zero
        Lp = np.zeros((2 * POOL, 2 * POOL), dtype=np.int64)       # out-of-range taps contribute 0
        Lp[:CONV, :CONV] = L
        S = Lp.reshape(POOL, 2, POOL, 2).sum(axis=(1, 3))
        v = np.clip(trunc_div(S, 4), -128, 127) + 128
        out[k] = v
    return out.astype(np.uint8)


def pack_words(mem, base, stream):
    """stream bytes (beat order) -> 64-bit words, beat 0 in the MSB"""
    stream = list(stream) + [0] * ((-len(stream)) % 8)
    for j in range(0, len(stream), 8):
        w = 0
        for s in range(8):
            w |= (int(stream[j + s]) & 0xFF) << (56 - 8 * s)
        mem[(base >> 3) + j // 8] = w


def pack_le(mem, base, data):
    """bytes in address order -> little-endian 64-bit words"""
    data = list(data) + [0] * ((-len(data)) % 8)
    for j in range(0, len(data), 8):
        w = 0
        for i in range(8):
            w |= (int(data[j + i]) & 0xFF) << (8 * i)
        mem[(base >> 3) + j // 8] = w


def make_case(mode, seed, nc):
    rng = np.random.default_rng(seed)
    if mode == "rand":            # full-range random: most features saturate
        img = rng.integers(-128, 128, (IMG, IMG)); K = rng.integers(-128, 128, (NF_MAPS, 4, 4))
    elif mode == "mixed":         # small ranges: rich, non-saturated feature maps
        img = rng.integers(-20, 21, (IMG, IMG));  K = rng.integers(-5, 6, (NF_MAPS, 4, 4))
    elif mode in ("accmax", "accmin", "ties", "zeros"):
        img = np.full((IMG, IMG), 127 if mode != "zeros" else 0); K = np.full((NF_MAPS, 4, 4), 127 if mode != "zeros" else 0)
    else:
        raise SystemExit("unknown mode")
    W = rng.integers(-128, 128, (nc, N_FLAT))
    B = rng.integers(-32768, 32768, nc)
    if mode == "accmax":          # every feature = 255; class0 all +127 (max), class1 all -128 (min)
        W[:] = 0; W[0, :] = 127
        if nc > 1: W[1, :] = -128
        B[:] = 0; B[0] = 32767
        if nc > 1: B[1] = -32768
    if mode == "ties":            # all logits equal except a two-way tie for the max
        W[:] = 0; B[:] = 100; B[min(3, nc - 1)] = 5000; B[nc - 1] = 5000
    if mode == "zeros":           # features all 128 (relu(0)); weights random
        pass
    return img, K, W, B


def build(mode, seed, nc, outdir):
    img, K, W, B = make_case(mode, seed, nc)
    F = features(img, K)                                         # [8][15][15] uint8
    flat = F.reshape(-1).astype(np.int64)                        # (m, row, col) channel-major
    logits = W.astype(np.int64) @ flat + B.astype(np.int64)
    cls = int(np.argmax(logits))                                 # first maximum on ties
    assert np.abs(logits).max() < (1 << 26), "27-bit accumulator would overflow"

    mem = [0] * DRAM_WORDS
    kb = []
    for k in range(NF_MAPS):
        kb += [int(v) & 0xFF for v in K[k].reshape(-1)]
    pack_le(mem, 0x0000, kb)
    pack_le(mem, 0x0100, [int(v) & 0xFF for v in img.reshape(-1)])
    bb = []
    for c in range(nc):
        v = int(B[c]) & 0xFFFF; bb += [v & 0xFF, v >> 8]
    pack_words(mem, BIAS_BASE, bb)
    ws = []
    for m in range(NF_MAPS):
        for c in range(nc):
            ws += [int(v) & 0xFF for v in W[c, m * FEAT_PER_MAP:(m + 1) * FEAT_PER_MAP]]
    pack_words(mem, WGT_BASE, ws)
    assert WGT_BASE > RES_BASE + 8 * 16 and WGT_BASE + len(ws) < 8 * DRAM_WORDS, "memory map overlap"

    # expected result stream: [class, NC, 0*6] then 32-bit LE logits, 2 per burst
    rs = [cls, nc, 0, 0, 0, 0, 0, 0]
    for c in range(nc):
        rs += [(int(logits[c]) >> (8 * i)) & 0xFF for i in range(4)]
    nrb = 1 + (nc + 1) // 2
    rs += [0] * (8 * nrb - len(rs))
    exp_res = [0] * nrb
    for j in range(nrb):
        w = 0
        for s in range(8):
            w |= rs[8 * j + s] << (56 - 8 * s)
        exp_res[j] = w

    # expected OSRAM write stream: per map 60 words of {col3,col2,col1,col0}(row-major, 16-wide, col15 = 0)
    ef = []
    for m in range(NF_MAPS):
        pad = np.zeros((POOL, 16), dtype=np.uint8); pad[:, :15] = F[m]
        b = pad.reshape(-1)
        for w in range(60):
            ef.append(int(b[4 * w]) | int(b[4 * w + 1]) << 8 | int(b[4 * w + 2]) << 16 | int(b[4 * w + 3]) << 24)

    os.makedirs(outdir, exist_ok=True)
    with open(f"{outdir}/dram_init.hex", "w") as f:
        f.write("\n".join(f"{w:016x}" for w in mem) + "\n")
    with open(f"{outdir}/exp_feat.hex", "w") as f:
        f.write("\n".join(f"{w:08x}" for w in ef) + "\n")
    with open(f"{outdir}/exp_featbytes.hex", "w") as f:      # padded 15x16 maps, address order (feature-only mode check)
        for m in range(NF_MAPS):
            pad = np.zeros((POOL, 16), dtype=np.uint8); pad[:, :15] = F[m]
            f.write("\n".join(f"{int(b):02x}" for b in pad.reshape(-1)) + "\n")
    with open(f"{outdir}/exp_res.hex", "w") as f:
        f.write("\n".join(f"{w:016x}" for w in exp_res) + "\n")
    with open(f"{outdir}/summary.txt", "w") as f:
        f.write(f"mode={mode} seed={seed} nc={nc}\nclass={cls}\n")
        for c in range(nc):
            f.write(f"logit[{c}]={int(logits[c])}\n")
        f.write(f"feat_min={int(F.min())} feat_max={int(F.max())} feat_mean={F.mean():.1f}\n")
    print(f"[gen] mode={mode} seed={seed} NC={nc}: class={cls} logits={[int(x) for x in logits]}"
          f"  feature range {int(F.min())}..{int(F.max())}")
    return F, logits, cls


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="mixed")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--nc", type=int, default=10)
    ap.add_argument("--out", default="vec")
    a = ap.parse_args()
    build(a.mode, a.seed, a.nc, a.out)
