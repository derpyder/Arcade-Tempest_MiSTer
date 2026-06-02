# 700 -> 720 framebuffer geometry (Tempest v1.1) — the authoritative constant set

**Why:** 700 doesn't integer-scale to 4K (700*3=2100 != 2160). **720 does: 720*3 = 2160 (exact 4K).**
Also 720*1.5=1080, 720*2=1440 — every step lands on a real panel height. FB stays 980 wide.

**Stride unchanged** = 4096 bytes/row = 512 64-bit words/row (980*4=3920 padded to 2^12 for Y<<12).

## Per-buffer sizes
| quantity            | 700 (old)      | 720 (new)      |
|---------------------|----------------|----------------|
| buffer bytes        | 0x2BC000       | **0x2D0000**   |
| buffer words        | 358400=0x57800 | **368640=0x5A000** |
| words % 16 (burst)  | 0 (exact)      | **0 (exact)**  |

## DDR FB_BASE (scan-out, BYTE addr, base 0x30000000)
| buf | 700        | 720          |
|-----|------------|--------------|
| 0   | 0x30000000 | 0x30000000   |
| 1   | 0x302BC000 | **0x302D0000** |
| 2   | 0x30578000 | **0x305A0000** |

## DDR draw/clear (WORD addr, base 0x06000000)
| buf | 700        | 720          |
|-----|------------|--------------|
| 0   | 0x06000000 | 0x06000000   |
| 1   | 0x06057800 | **0x0605A000** |
| 2   | 0x060AF000 | **0x060B4000** |
| safety clamp hi | 0x0610FFFF (loose) | **0x0610DFFF** (= base+3*buf_words-1; loose 0x0610FFFF still ok) |

## Clear ranges (clear_addr is reg[18:0]; 368639 needs 19 bits -> FITS, no width change)
| const                | 700     | 720      |
|----------------------|---------|----------|
| full buffer words    | 358400  | **368640** |
| CLR_BURST_END_FULL   | 358384  | **368624** (=words-16) |
| CLR_SINGLE_END_FULL  | 358399  | **368639** (=words-1) |

### Row-range clear (content occupies ~512 rows centred). centre 350->**360**.
Old window rows 88..613 (around c=350). New around c=360, rows **96..623** (lo on a clean 16-boundary):
| const               | 700    | 720     |
|---------------------|--------|---------|
| CLR_ROW_LO          | 45056  | **49152** (row 96 * 512) |
| CLR_BURST_END_ROW   | 314352 | **319472** ((row 624)*512 - 16) |
| CLR_SINGLE_END_ROW  | 314367 | **319487** ((row 624)*512 - 1) |
(lo%16=0, (burst_end-lo)%16=0 -> clean burst walk.)

## Bounds check (vector_fb_ddram stage-2)
`pixel_y < 10'd700` -> **`pixel_y < 10'd720`**

## Coord map (tempest_sw.sv)
- centre: `fys = 14'sd350 - ry` -> **`fys = 14'sd360 - ry`** (720/2). fxs (X centre 490) unchanged.
- in_bounds: `fys < 14'sd700` -> **`fys < 14'sd720`**.

## Core raster timing (tempest_sw.sv) — MUST track height or vsync lands in active video
| signal     | 700                | 720                 |
|------------|--------------------|---------------------|
| vblank     | v_cnt >= 700       | **v_cnt >= 720**    |
| vs_start   | 703                | **723** (active+3)  |
| vs_end     | 709                | **729** (active+9)  |
| v_total    | 860                | 860 (unchanged; 860-720=140 lines blank, ample) |
(FB_HEIGHT is what ascal scans; core h/v timing only needs to CONTAIN the FB + emit sync.)

## Auto-scale table (Arcade-StarWars.sv) — FB now 980x720
| step | size       | ARX     | ARY (NEW)  |
|------|------------|---------|------------|
| x1   | 980x720    | 0x13D4  | **0x12D0** |
| x1.5 | 1470x1080  | 0x15BE  | **0x1438** |
| x2   | 1960x1440  | 0x17A8  | **0x15A0** |
| x3   | 2940x2160  | 0x1B7C  | **0x1870** (exact 4K height!) |
Pixel-Perfect (ar==1): ARX 0x13D4 / ARY **0x12D0**.
HDMI_HEIGHT thresholds (>=2100 etc.) unchanged — they gate on OUTPUT height, not FB.

## For Major Havoc
Bake 720 from the start (don't inherit Tempest's 700). Same stride/width assumptions;
MH's content centring differs, but the buffer-size / DDR-offset / clear-range / burst-fit
math above is identical for any 980x720 FB on this chassis.
