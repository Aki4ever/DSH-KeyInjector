#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KeyInjector (Key注入器) — native-style macOS app icon generator.

Pure Python 3 standard library ONLY (zlib / struct / math). No Pillow, no numpy,
no third-party image library. A minimal RGBA8 PNG encoder is implemented here.

Rendering pipeline
------------------
1. Everything is rasterised at SS x SS supersampling (default 4x4 = 4096x4096)
   using signed-distance-field (SDF) coverage so both the rounded-square plate
   and the glyph edges get smooth, analytically-graded antialiasing.
2. Supersamples are box-filtered down to 1024x1024 in *premultiplied* alpha
   space, then un-premultiplied, which prevents dark/coloured fringe pixels.
3. The result is written as a 1024x1024 RGBA (8 bit/channel) PNG with an
   "Up" row filter for good compression.

Usage:
    python3 scripts/gen_icon.py [--out-dir DIR] [--ss 4]

Then (see build_iconset() below / the shell steps in the task):
    sips -z ... ; iconutil -c icns assets/icon.iconset -o assets/AppIcon.icns
"""

import argparse
import math
import os
import struct
import sys
import time
import zlib

# --------------------------------------------------------------------------
# Canvas / design constants (all in 1024-point design space)
# --------------------------------------------------------------------------
W = 1024                      # final output size (pixels)
SS = 4                        # supersampling factor per axis

INSET = 0.08 * W              # 8% transparent margin around the plate  -> 81.92
PLATE = W - 2.0 * INSET      # plate edge length                        -> 860.16
PLATE_R = 0.22 * PLATE        # rounded-square corner radius             -> 189.24

PLATE_X0 = INSET
PLATE_Y0 = INSET
PLATE_X1 = W - INSET
PLATE_Y1 = W - INSET
PLATE_CX = 0.5 * (PLATE_X0 + PLATE_X1)
PLATE_CY = 0.5 * (PLATE_Y0 + PLATE_Y1)
PLATE_HX = 0.5 * (PLATE_X1 - PLATE_X0) - PLATE_R   # half-extent minus radius
PLATE_HY = 0.5 * (PLATE_Y1 - PLATE_Y0) - PLATE_R

# Palette -------------------------------------------------------------------
BG_FROM = (0x2B, 0x2D, 0x6E)      # deep indigo   (top-left)
BG_TO = (0x6C, 0x4C, 0xE0)        # violet        (bottom-right)
KEY_WHITE = (0xF5, 0xF6, 0xFF)    # key glyph
ARROW_CYAN = (0x38, 0xE1, 0xC8)   # injection arrow badge

HILIGHT_STRENGTH = 0.16           # subtle top highlight
HILIGHT_DEPTH = 0.50              # fraction of plate height it fades over
VIGNETTE_STRENGTH = 0.10          # subtle bottom shading for depth

# --- Key glyph geometry ----------------------------------------------------
BOW_CX, BOW_CY = 340.0, 498.0     # ring (key bow) centre
BOW_RO, BOW_RI = 154.0, 72.0      # outer / inner radius (hole stays open)
BOW_RMID = 0.5 * (BOW_RO + BOW_RI)
BOW_HALF = 0.5 * (BOW_RO - BOW_RI)

SHAFT_X0, SHAFT_X1 = 414.0, 840.0  # starts on the hole rim, right of the ring
SHAFT_Y0, SHAFT_Y1 = 440.0, 556.0  # 116 pt thick, rounded capsule ends

# Two teeth hanging below the shaft near the tip. They start inside the shaft
# (y=500) so their rounded top corners are hidden by the union with the shaft.
# Each entry is (x0, y0, x1, y1) in design units.
TEETH = (
    (506.0, 500.0, 562.0, 682.0),
    (614.0, 500.0, 670.0, 682.0),
)
TOOTH_R = 18.0

# Cyan injection arrow, overlaid on the shaft right of the teeth.
ARROW_TAIL = (676.0, 482.0, 748.0, 514.0)   # x0, y0, x1, y1 (arrow shaft)
ARROW_TAIL_R = 8.0
ARROW_HEAD = ((748.0, 456.0), (748.0, 540.0), (824.0, 498.0))  # triangle, apex right


# --------------------------------------------------------------------------
# Minimal PNG writer (RGBA8, no interlace)
# --------------------------------------------------------------------------
def png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, width, height, rows):
    """rows: list of bytearray/bytes, each 4*width bytes, RGBA8 straight alpha."""
    raw = bytearray()
    prev = bytes(4 * width)
    for y, row in enumerate(rows):
        row = bytes(row)
        if y == 0:
            raw.append(0)                      # filter: None
            raw += row
        else:
            raw.append(2)                      # filter: Up
            raw += bytes(((row[i] - prev[i]) & 0xFF) for i in range(len(row)))
        prev = row
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + png_chunk(b"IHDR", ihdr)
           + png_chunk(b"sRGB", b"\x00")       # rendering intent: perceptual
           + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + png_chunk(b"IEND", b""))
    with open(path, "wb") as fh:
        fh.write(png)
    return len(png)


# --------------------------------------------------------------------------
# Signed distance helpers (operate in *supersampled pixel* units)
# --------------------------------------------------------------------------
def sd_round_rect(px, py, x0, y0, x1, y1, r):
    """Negative inside. Exact rounded-rectangle SDF."""
    hx = 0.5 * (x1 - x0) - r
    hy = 0.5 * (y1 - y0) - r
    dx = abs(px - 0.5 * (x0 + x1)) - hx
    dy = abs(py - 0.5 * (y0 + y1)) - hy
    ax = dx if dx > 0.0 else 0.0
    ay = dy if dy > 0.0 else 0.0
    outside = math.sqrt(ax * ax + ay * ay)
    inside = dx if dx > dy else dy
    if inside > 0.0:
        inside = 0.0
    return outside + inside - r


def sd_ring(px, py, cx, cy, rmid, half):
    """Annulus SDF: abs(dist_to_centre - rmid) - half."""
    dx = px - cx
    dy = py - cy
    return abs(math.sqrt(dx * dx + dy * dy) - rmid) - half


def _seg_dist(px, py, ax, ay, bx, by):
    vx = bx - ax
    vy = by - ay
    wx = px - ax
    wy = py - ay
    denom = vx * vx + vy * vy
    t = 0.0 if denom <= 0.0 else (wx * vx + wy * vy) / denom
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    dx = wx - t * vx
    dy = wy - t * vy
    return math.sqrt(dx * dx + dy * dy)


def sd_triangle(px, py, a, b, c):
    """Exact triangle SDF (negative inside), convex triangle."""
    d = _seg_dist(px, py, a[0], a[1], b[0], b[1])
    d2 = _seg_dist(px, py, b[0], b[1], c[0], c[1])
    if d2 < d:
        d = d2
    d3 = _seg_dist(px, py, c[0], c[1], a[0], a[1])
    if d3 < d:
        d = d3
    c1 = (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0])
    c2 = (c[0] - b[0]) * (py - b[1]) - (c[1] - b[1]) * (px - b[0])
    c3 = (a[0] - c[0]) * (py - c[1]) - (a[1] - c[1]) * (px - c[0])
    if (c1 >= 0.0 and c2 >= 0.0 and c3 >= 0.0) or (c1 <= 0.0 and c2 <= 0.0 and c3 <= 0.0):
        return -d
    return d


def cov(d):
    """SDF -> coverage byte. Pixel size is 1.0 in supersampled units."""
    v = 0.5 - d
    if v <= 0.0:
        return 0
    if v >= 1.0:
        return 255
    return int(v * 255.0 + 0.5)


def _sx_range(x0, x1):
    lo = int(math.floor(x0)) - 1
    hi = int(math.ceil(x1)) + 1
    if lo < 0:
        lo = 0
    if hi > W * SS - 1:
        hi = W * SS - 1
    return lo, hi


# --------------------------------------------------------------------------
# Glyph shape table: (bbox in design units, sdf(px,py)->distance in SS units)
# --------------------------------------------------------------------------
def build_shapes():
    """Returns (white_shapes, cyan_shapes).

    Each shape is (x0, y0, x1, y1, sdf) with the SDF expressed in supersampled
    pixel coordinates (i.e. already multiplied by SS).
    """
    s = float(SS)

    def ring_sdf(px, py):
        return sd_ring(px, py, BOW_CX * s, BOW_CY * s, BOW_RMID * s, BOW_HALF * s)

    def shaft_sdf(px, py):
        return sd_round_rect(px, py, SHAFT_X0 * s, SHAFT_Y0 * s, SHAFT_X1 * s,
                             SHAFT_Y1 * s, 0.5 * (SHAFT_Y1 - SHAFT_Y0) * s)

    white = [
        (BOW_CX - BOW_RO, BOW_CY - BOW_RO, BOW_CX + BOW_RO, BOW_CY + BOW_RO, ring_sdf),
        (SHAFT_X0, SHAFT_Y0, SHAFT_X1, SHAFT_Y1, shaft_sdf),
    ]
    for (x0, y0, x1, y1) in TEETH:
        def tooth_sdf(px, py, x0=x0, y0=y0, x1=x1, y1=y1):
            return sd_round_rect(px, py, x0 * s, y0 * s, x1 * s, y1 * s, TOOTH_R * s)
        white.append((x0, y0, x1, y1, tooth_sdf))

    def tail_sdf(px, py):
        x0, y0, x1, y1 = ARROW_TAIL
        return sd_round_rect(px, py, x0 * s, y0 * s, x1 * s, y1 * s, ARROW_TAIL_R * s)

    (ha, hb, hc) = ARROW_HEAD
    hx0 = min(ha[0], hb[0], hc[0])
    hx1 = max(ha[0], hb[0], hc[0])
    hy0 = min(ha[1], hb[1], hc[1])
    hy1 = max(ha[1], hb[1], hc[1])

    def head_sdf(px, py):
        return sd_triangle(px, py, (ha[0] * s, ha[1] * s), (hb[0] * s, hb[1] * s),
                           (hc[0] * s, hc[1] * s))

    cyan = [
        (ARROW_TAIL[0], ARROW_TAIL[1], ARROW_TAIL[2], ARROW_TAIL[3], tail_sdf),
        (hx0, hy0, hx1, hy1, head_sdf),
    ]
    return white, cyan


# --------------------------------------------------------------------------
# Renderer
# --------------------------------------------------------------------------
def render(ss=SS, progress=True):
    global SS
    SS = ss
    N = W * SS
    t_start = time.time()

    white_shapes, cyan_shapes = build_shapes()

    # Pre-scaled plate geometry (in supersampled units)
    s = float(SS)
    pcx, pcy = PLATE_CX * s, PLATE_CY * s
    phx, phy = PLATE_HX * s, PLATE_HY * s
    pr = PLATE_R * s
    px0, px1 = PLATE_X0 * s, PLATE_X1 * s
    py0 = PLATE_Y0 * s

    # Gradient: t = (x + y - 2*INSET) / (2*PLATE) in design space.
    D = 2.0 * PLATE
    t_step = (1.0 / s) / D                    # per supersample pixel step
    dr = (BG_TO[0] - BG_FROM[0]) / 255.0
    dg = (BG_TO[1] - BG_FROM[1]) / 255.0
    db = (BG_TO[2] - BG_FROM[2]) / 255.0
    r0 = BG_FROM[0] / 255.0
    g0 = BG_FROM[1] / 255.0
    b0 = BG_FROM[2] / 255.0

    # Highlight horizontal falloff
    hw = 0.5 * PLATE * s
    fx_step = (1.0 / s) / hw

    out_rows = []
    accR = [0.0] * W
    accG = [0.0] * W
    accB = [0.0] * W
    accA = [0.0] * W

    inv_ss2 = 1.0 / (SS * SS)

    for sy in range(N):
        # ---- 1. glyph coverage for this supersample row -------------------
        wrow = bytearray(N)
        crow = bytearray(N)
        for (x0, y0, x1, y1, fn) in white_shapes:
            if sy + 0.5 < y0 * s - 1.0 or sy + 0.5 > y1 * s + 1.0:
                continue
            lo, hi = _sx_range(x0 * s, x1 * s)
            py = sy + 0.5
            for sx in range(lo, hi + 1):
                c = cov(fn(sx + 0.5, py))
                if c > wrow[sx]:
                    wrow[sx] = c
        for (x0, y0, x1, y1, fn) in cyan_shapes:
            if sy + 0.5 < y0 * s - 1.0 or sy + 0.5 > y1 * s + 1.0:
                continue
            lo, hi = _sx_range(x0 * s, x1 * s)
            py = sy + 0.5
            for sx in range(lo, hi + 1):
                c = cov(fn(sx + 0.5, py))
                if c > crow[sx]:
                    crow[sx] = c

        # ---- 2. plate coverage + shading + compositing --------------------
        yk = (sy + 0.5) / s                                   # design space
        dy = abs(yk - PLATE_CY) - PLATE_HY
        if dy >= PLATE_R:
            xlo_d = xhi_d = None
        elif dy <= 0.0:
            xlo_d, xhi_d = PLATE_X0, PLATE_X1
        else:
            d = PLATE_R - math.sqrt(PLATE_R * PLATE_R - dy * dy)
            xlo_d, xhi_d = PLATE_X0 + d, PLATE_X1 - d

        if xlo_d is not None:
            slo = int(math.floor(xlo_d * s)) - 1
            shi = int(math.ceil(xhi_d * s)) + 1
            if slo < 0:
                slo = 0
            if shi > N - 1:
                shi = N - 1

            # per-row shading constants
            if yk <= py0 / s:
                hl_y = 0.0
            else:
                hsf = (yk - PLATE_Y0) / (HILIGHT_DEPTH * PLATE)
                if hsf > 1.0:
                    hsf = 1.0
                hl_y = HILIGHT_STRENGTH * (1.0 - hsf) * (1.0 - hsf)
            vsf = (yk - (PLATE_Y0 + 0.55 * PLATE)) / (0.45 * PLATE)
            if vsf <= 0.0:
                vmul = 1.0
            else:
                if vsf > 1.0:
                    vsf = 1.0
                vmul = 1.0 - VIGNETTE_STRENGTH * (vsf * math.sqrt(vsf))

            ay = dy if dy > 0.0 else 0.0
            ay2 = ay * ay
            corner_rows = ay > 0.0

            t = ((slo + 0.5) / s + yk - 2.0 * INSET) / D
            fx = abs((slo + 0.5) / s - PLATE_CX) / (0.5 * PLATE)
            if fx > 1.0:
                fx = 1.0
            fx = 1.0 - 0.35 * fx

            for sx in range(slo, shi + 1):
                x = sx + 0.5
                dx = abs(x - pcx) - phx
                if corner_rows:
                    ax = dx if dx > 0.0 else 0.0
                    dist = math.sqrt(ax * ax + ay2)
                    ins = dx if dx > dy else dy
                    if ins > 0.0:
                        ins = 0.0
                    dist += ins - pr
                else:
                    dist = (dx if dx > dy else dy) - pr
                ca = 0.5 - dist
                if ca <= 0.0:
                    t += t_step
                    fx -= fx_step
                    continue
                if ca > 1.0:
                    ca = 1.0

                tt = t
                if tt < 0.0:
                    tt = 0.0
                elif tt > 1.0:
                    tt = 1.0
                cr = r0 + dr * tt
                cg = g0 + dg * tt
                cb = b0 + db * tt

                if hl_y > 0.0:
                    h = hl_y * (fx if fx > 0.0 else 0.0)
                    if h > 0.0:
                        cr += (1.0 - cr) * h
                        cg += (1.0 - cg) * h
                        cb += (1.0 - cb) * h
                if vmul != 1.0:
                    cr *= vmul
                    cg *= vmul
                    cb *= vmul

                wc = wrow[sx]
                if wc:
                    a = wc / 255.0
                    cr += (0.96078 - cr) * a
                    cg += (0.96471 - cg) * a
                    cb += (1.0 - cb) * a
                cc = crow[sx]
                if cc:
                    a = cc / 255.0
                    cr += (0.21961 - cr) * a
                    cg += (0.88235 - cg) * a
                    cb += (0.78431 - cb) * a

                ar = cr * ca
                ag = cg * ca
                ab = cb * ca
                ox = sx >> 2 if SS == 4 else sx // SS
                accR[ox] += ar
                accG[ox] += ag
                accB[ox] += ab
                accA[ox] += ca

                t += t_step
                fx -= fx_step

        # ---- 3. flush a finished output row ------------------------------
        if (sy % SS) == SS - 1:
            row = bytearray(4 * W)
            for ox in range(W):
                a = accA[ox]
                if a > 0.0:
                    inv = 1.0 / a
                    row[4 * ox] = int(cr_clamp(accR[ox] * inv))
                    row[4 * ox + 1] = int(cr_clamp(accG[ox] * inv))
                    row[4 * ox + 2] = int(cr_clamp(accB[ox] * inv))
                    row[4 * ox + 3] = int(cr_clamp(a * inv_ss2))
                accR[ox] = 0.0
                accG[ox] = 0.0
                accB[ox] = 0.0
                accA[ox] = 0.0
            out_rows.append(row)
            if progress and (len(out_rows) % 128 == 0):
                sys.stderr.write("\r  rendering %4d/%d rows  (%.1fs)"
                                 % (len(out_rows), W, time.time() - t_start))
                sys.stderr.flush()

    if progress:
        sys.stderr.write("\r  rendered %d rows in %.1fs%s\n"
                         % (len(out_rows), time.time() - t_start, " " * 12))
    return out_rows


def cr_clamp(v):
    """Clamp a normalised 0..1 channel value and scale it to a 0..255 byte value."""
    if v <= 0.0:
        return 0.0
    if v >= 1.0:
        return 255.0
    return v * 255.0 + 0.5


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Generate the KeyInjector app icon.")
    ap.add_argument("--out", default=os.path.join("assets", "icon.png"))
    ap.add_argument("--ss", type=int, default=SS, help="supersampling factor (>=1)")
    ap.add_argument("--no-progress", action="store_true")
    args = ap.parse_args()

    ss = max(1, args.ss)
    out = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    t0 = time.time()
    rows = render(ss=ss, progress=not args.no_progress)
    size = write_png(out, W, W, rows)
    sys.stderr.write("wrote %s  %dx%d  ss=%d  %d bytes  (%.1fs total)\n"
                     % (out, W, W, ss, size, time.time() - t0))


if __name__ == "__main__":
    main()
