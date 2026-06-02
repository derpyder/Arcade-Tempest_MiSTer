#!/usr/bin/env python3
# Quantitative framebuffer SOLIDITY metric (judge lines by numbers, not by eye).
#
# Builds a GOLDEN lit-pixel set from the real display list using the SAME coord-map
# as tb_fb_replay (draws az>0 light up; moves az==0 stay dark; NO erase, NO
# contention), then compares the sim's fb_out.txt against it.
#
#   retention = |sim ∩ golden| / |golden|   (1.00 = lines exactly as solid as the AVG drew)
#   missing   = golden pixels absent in sim  (these ARE the dots/gaps)
#   spurious  = sim pixels not in golden     (e.g. moves drawn, stray writes)
#   erase-risk= golden ∩ move-pixels         (upper bound on move-erase damage in overwrite mode)
import sys

FRAME = "../../../Arcade-Tempest/sim/tempest_frame.txt"
OUT   = sys.argv[1] if len(sys.argv) > 1 else "fb_out.txt"

def mapx(ax):  # matches tempest_sw.sv orient C: fxs = 490 + rx (X not flipped)
    cx = ax ^ 512; sx = (cx * 11) >> 4; return 490 + (sx - 352)   # FILL scale 11/16, centre 352
def mapy(ay):  # matches tempest_sw.sv orient C: fys = 360 - ry (flip Y, right-side-up; FB 720)
    cy = ay ^ 512; sy = (cy * 11) >> 4; return 360 - (sy - 352)   # FILL scale 11/16, centre 352
def inb(x, y):
    return 0 <= x < 980 and 0 <= y < 720

# A pixel is VISIBLY lit only when Z = az[7:3] > 0  (chan = {Z,Z[4:2]} == 0 when Z==0).
# So az 1..7 also render black AND erase in overwrite mode -> they are "movers", not golden.
golden = set()   # intended VISIBLE pixels (Z = az>>3 > 0)
movepx = set()   # invisible pixels (Z==0): true moves az==0 AND dim az 1..7 -> erase in overwrite
order_first = {} # (x,y) -> first display-list index that LIGHTS it (a real draw)
order_lastmove = {}  # (x,y) -> last display-list index an invisible point touches it
for i, l in enumerate(open(FRAME)):
    f = l.split()
    if len(f) < 4: continue
    ax, ay, rgb, az = map(int, f[:4])
    x, y = mapx(ax), mapy(ay)
    if not inb(x, y): continue
    if (az >> 3) > 0 and rgb != 0:
        golden.add((x, y))
        if (x, y) not in order_first: order_first[(x, y)] = i
    else:
        movepx.add((x, y))
        order_lastmove[(x, y)] = i

sim = set()
for l in open(OUT):
    p = l.split()
    if len(p) == 5:
        sim.add((int(p[0]), int(p[1])))

inter    = sim & golden
missing  = golden - sim
spurious = sim - golden
erase_risk = golden & movepx
# of the erase-risk pixels, how many have a move AFTER the last... (approx: any move touches)
# erase that actually fires in overwrite = a move at index > the draw that lit it
erased_by_late_move = {p for p in erase_risk
                       if order_lastmove.get(p, -1) > order_first.get(p, 1 << 30)}

# characterize the MISSING pixels by their first-draw position in the display list:
# clustering near the end => EOF-clear pipeline flush dropping the frame tail.
total_lit_events = max(order_first.values()) + 1 if order_first else 1
miss_orders = sorted(order_first[p] for p in missing if p in order_first)
if miss_orders:
    tail_window = total_lit_events - 1000   # last ~1000 display-list indices
    in_tail = sum(1 for o in miss_orders if o >= tail_window)
    print(f"[missing-order] first-draw index range {miss_orders[0]}..{miss_orders[-1]} of 0..{total_lit_events-1}"
          f"  |  {in_tail}/{len(miss_orders)} are in the last 1000 list entries (EOF-flush tail?)")

g = len(golden) or 1
print(f"golden draw-pixels (intended): {len(golden)}")
print(f"move-only pixels:              {len(movepx)}")
print(f"sim lit pixels:                {len(sim)}")
print(f"retention |sim&golden|/golden: {len(inter)}/{len(golden)} = {100*len(inter)/g:.1f}%")
print(f"missing   (DOTS/gaps):         {len(missing)}")
print(f"spurious  (sim not in golden): {len(spurious)}")
# row-range-clear boundary check (SIM_ROWCLEAR): marker pre-fill survives only OUTSIDE rows 88..613.
spur_inside  = [p for p in spurious if 88 <= p[1] <= 613]
spur_outside = len(spurious) - len(spur_inside)
print(f"  spurious INSIDE rows[88,613]:  {len(spur_inside)}  <- MUST be 0 (row-range clear has no gaps)")
print(f"  spurious OUTSIDE rows[88,613]: {spur_outside}  <- marker survivors (HW boot-full-clear handles these)")
print(f"erase-risk(golden&move):       {len(erase_risk)}")
print(f"  of which a LATE move erases: {len(erased_by_late_move)}  <- overwrite-mode erase damage (BUSY-independent)")
