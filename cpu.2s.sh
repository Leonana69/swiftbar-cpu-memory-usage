#!/bin/bash

# CPU + memory history monitor — draws a Task-Manager-style filled CPU history
# graph (colored by load) with memory usage overlaid as a blue line behind it.
# Each run samples both, appends to a rolling history file, and renders the
# history as a small PNG (pure-stdlib, no third-party deps).

HIST="$HOME/Library/Caches/swiftbar_cpu_history.txt"

# --- Sample CPU usage (100 - idle). top -l 2 gives an accurate delta sample. ---
idle=$(top -l 2 -n 0 2>/dev/null | awk '/CPU usage/{i=$0} END{print i}' \
        | sed -E 's/.* ([0-9.]+)%[[:space:]]+idle.*/\1/')
[ -z "$idle" ] && idle=100
cpu=$(echo "100 - $idle" | bc 2>/dev/null)
[ -z "$cpu" ] && cpu=0

# --- Sample memory usage (used = active + wired + compressed, à la Activity Monitor) ---
total_bytes=$(sysctl -n hw.memsize 2>/dev/null)
pagesize=$(sysctl -n hw.pagesize 2>/dev/null)
[ -z "$pagesize" ] && pagesize=16384
used_bytes=$(vm_stat 2>/dev/null | awk -v ps="$pagesize" '
  /Pages active/           {gsub(/\./,"",$3); a=$3}
  /Pages wired down/       {gsub(/\./,"",$4); w=$4}
  /occupied by compressor/ {gsub(/\./,"",$5); c=$5}
  END { print (a + w + c) * ps }')
mem=$(awk -v u="$used_bytes" -v t="$total_bytes" 'BEGIN{ printf "%.1f", (t>0 ? u/t*100 : 0) }')
mem_used_gb=$(awk -v u="$used_bytes" 'BEGIN{ printf "%.1f", u/1073741824 }')
mem_total_gb=$(awk -v t="$total_bytes" 'BEGIN{ printf "%.1f", t/1073741824 }')

# --- Update history + render PNG to base64 (system python3, always present) ---
img=$(/usr/bin/python3 - "$HIST" "$cpu" "$mem" <<'PY'
import sys, os, zlib, struct, base64

hist_path = sys.argv[1]
cpu, mem = float(sys.argv[2]), float(sys.argv[3])
N = 60  # number of samples kept in the rolling window

vals = []  # list of (cpu, mem) pairs
if os.path.exists(hist_path):
    try:
        with open(hist_path) as f:
            for tok in f.read().split():
                if "," in tok:
                    c, m = tok.split(",")
                    vals.append((float(c), float(m)))
                else:                       # legacy CPU-only entry
                    vals.append((float(tok), mem))
    except Exception:
        vals = []
vals.append((cpu, mem))
vals = vals[-N:]
try:
    with open(hist_path, "w") as f:
        f.write(" ".join("%.1f,%.1f" % (c, m) for c, m in vals))
except Exception:
    pass

# Output is @2x (SwiftBar treats the PNG as retina), so the on-screen size is
# OUT * (28 x 14) points. We render SS times larger and box-downscale, which
# anti-aliases the rounded corners without changing the displayed size.
OUT, SS = 2, 3                  # final @2x; 3x supersample for smooth edges
S = OUT * SS
W, H = 28 * S, 14 * S           # hi-res render buffer (width cut ~30%)
R = 4 * S                       # rounded-corner radius
bg   = (30, 30, 34, 205)        # dark translucent panel
grid = (70, 70, 78, 150)        # faint gridlines at 25/50/75%
none = (0, 0, 0, 0)             # transparent (rounded corners)

def band(v):                    # usage -> (fill, bright top edge)
    if   v < 30: return (48, 200, 90, 220),  (130, 255, 160, 255)
    elif v < 60: return (230, 205, 40, 220), (255, 240, 130, 255)
    elif v < 90: return (240, 150, 30, 220), (255, 200, 110, 255)
    else:        return (235, 60, 50, 225),  (255, 150, 140, 255)

img = [[bg for _ in range(W)] for _ in range(H)]
for q in (0.25, 0.5, 0.75):     # gridlines, SS thick so they survive downscale
    y = int((1 - q) * (H - 1))
    for t in range(SS):
        for x in range(W):
            img[min(H - 1, y + t)][x] = grid

mem_col = (70, 150, 255, 255)   # memory usage line (blue)
n = len(vals)

# Memory usage as a blue line — drawn first so the CPU area sits in front of it.
prev = None
for x in range(W):
    m = max(0.0, min(100.0, vals[min(int(x / W * n), n - 1)][1]))
    y = H - 1 - int(m / 100.0 * (H - 1))
    lo, hi = (y, y) if prev is None else (min(prev, y), max(prev, y))
    for yy in range(lo, hi + 1):    # connect to previous point
        img[yy][x] = mem_col
    for t in range(SS):             # ~SS thickness around the point
        yy = y + t - SS // 2
        if 0 <= yy < H:
            img[yy][x] = mem_col
    prev = y

# CPU usage as a filled area, colored by load band (covers the memory line).
for x in range(W):
    v = max(0.0, min(100.0, vals[min(int(x / W * n), n - 1)][0]))
    fill, line = band(v)
    top = H - 1 - int(v / 100.0 * (H - 1))
    for y in range(top, H):
        img[y][x] = fill
    for t in range(SS):         # top edge, SS thick
        if 0 <= top + t < H:
            img[top + t][x] = line

# Hard-cut rounded corners at hi-res; the downscale below turns the stair-step
# into a smooth anti-aliased edge.
for y in range(H):
    py = y + 0.5
    for x in range(W):
        px = x + 0.5
        if not ((px < R or px > W - R) and (py < R or py > H - R)):
            continue
        cxc = R if px < R else W - R
        cyc = R if py < R else H - R
        if (px - cxc) ** 2 + (py - cyc) ** 2 > R * R:
            img[y][x] = none

# Box-downscale by SS with premultiplied alpha (avoids dark fringes).
OW, OH = W // SS, H // SS
out = [[none] * OW for _ in range(OH)]
area = SS * SS
for oy in range(OH):
    for ox in range(OW):
        ra = ga = ba = aa = 0
        for j in range(SS):
            row = img[oy * SS + j]
            for i in range(SS):
                r, g, b, a = row[ox * SS + i]
                ra += r * a; ga += g * a; ba += b * a; aa += a
        out[oy][ox] = (ra // aa, ga // aa, ba // aa, aa // area) if aa else none

def png(img, W, H):
    raw = bytearray()
    for y in range(H):
        raw.append(0)                       # filter type 0 (none) per scanline
        for x in range(W):
            raw += bytes(img[y][x])
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))

sys.stdout.write(base64.b64encode(png(out, OW, OH)).decode())
PY
)

# --- Menu bar: graph image only (usage indicated by color) ---
printf " | image=%s\n" "$img"

# --- Dropdown: current readouts + top CPU-consuming processes ---
echo "---"
printf "CPU: %.0f%% | color=#2ec85a font='Menlo'\n" "$cpu"
printf "Memory: %s%% (%s / %s GB) | color=#4696ff font='Menlo'\n" "$mem" "$mem_used_gb" "$mem_total_gb"
echo "---"
echo "Top processes | font='Menlo'"
ps -Ao %cpu=,comm= -r 2>/dev/null | head -5 | while read -r pct comm; do
  printf -- "%5s%%  %s | font='Menlo'\n" "$pct" "$(basename "$comm")"
done
echo "---"
echo "Refresh | refresh=true"
