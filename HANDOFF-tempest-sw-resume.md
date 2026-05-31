# Tempest 1.1 (Star Wars chassis) — RESUME HANDOFF (2026-05-30)

**Single authoritative resume doc** (supersedes the layered notes in HANDOFF-SW-CHASSIS.md
and RESEARCH-vector-fb-contract.md, which remain as detail/evidence).

## LATEST (2026-05-31 PM) — PHOSPHOR-PERSISTENCE present-gate (HW feedback in hand)

### HW result on the list-aligned (one-list) build
User flashed the one-list gate: **attract + in-game flash when firing; when NOT firing,
intermittent dropped beams across the screen.** They asked the key question: does real
Tempest rely on decay/ghosting/lingering frames, and can we use that to fight flicker?

### Diagnosis (this is the correct model now)
**YES — persistence is the whole mechanism.** A real Tempest redraws its WHOLE list
~200-250x/sec (GHDL: 9 redraws/45 ms) and the CRT PHOSPHOR INTEGRATES them: any single
redraw missing a beam is refilled by the next, and motion gets a soft trail. That is why a
real tube never flickers. A DDR framebuffer has NO phosphor. The one-list gate presented
exactly ONE redraw/frame -> every DDR-contention dropped beam shows for a whole frame with
nothing to refill it (= the "intermittent dropped beams"), and a list cut mid-draw drops its
tail (= firing flash). **The good "_n" build wasn't good because it was clean — it was good
because its ~12 ms window happened to OVERDRAW ~3 redraws (accidental phosphor), which hid
drops. It only flashed when firing because its fixed timer sliced the longer list mid-draw.**

### Fix: accumulate N COMPLETE lists per displayed buffer (emulate the phosphor)
The framebuffer only CLEARS on EOF. So `rtl/present_gate.sv` now holds the beam ON across
**N complete lists (each bounded vggo->vggo) and emits EOF only after the Nth** -> N redraws
pile into one buffer with no clear between = a union = crude phosphor. Dropped beams get
refilled across redraws (no idle flicker); the Nth list is COMPLETE (no tail cut = no firing
flash). Display is decoupled (FB swaps ready->display on its own scan-out vblank, shows the
last completed union steadily), so the per-EOF beam-off clear window is invisible and
free-running needs no vblank lock (each union is identical frame-to-frame = no beat).
Degrades to a time-window accumulator if vggo dies (never black, never worse than _n).

### NEW: live OSD "Persistence" knob (tune ghosting on the cab, no rebuild)
CONF_STR `"OST,Persistence,3 (default),4,6,2;"` -> status[29:28] -> tempest_sw.osd_persist
-> present_gate.persist. N = 3(default,≈_n) / 4 / 6 / 2. **This is the dial to find the
flicker/smear sweet spot on HW.** (status[29:28] is free; the old SW m_dsw0/1 status bits are
DEAD CODE here — Tempest reads DIPs via the MRA sw[] path, so no collision.)

### Sim (ModelSim, `sim/fb/tb_gate2.sv`, all 6 PASS)
lists/eof = exactly N for persist 0/1/2/3 (3/4/6/2); **FIRING (grown list) still accumulates 3
COMPLETE lists, last list complete = no tail cut**; vggo-dead degrades (eof still pulses).
(First run flagged "last list incomplete" — that was a TB off-by-one: eof is registered, seen
1 clk after its trigger vggo; corrected by checking vggo_rise delayed 1. List-count metric was
right throughout, independently proving the gate closes on a list boundary.)

### Build / next
`build_persist.log` compiling -> stage `releases/Arcade-Tempest_20260531b.rbf`. **HW test:
sweep the Persistence knob (3->4->6) while firing; pick the lowest N with no flicker (higher N
= more ghost/trail + more DDR clear pressure).** If even N=6 still drops beams when NOT firing,
the residual is DDR-contention pixel loss in vector_fb_ddram (separate; persistence masks it).

---

## EARLIER 2026-05-31 — LIST-ALIGNED present-gate (one list/frame) [SUPERSEDED — removed phosphor]

### What was wrong (the regression `_n` -> `_s`/vbllock)
The flicker is NOT a fundamental limit. `_n` (Arcade-Tempest_20260530n.rbf) was the best build
(user: "almost flicker free, flickered ONLY when projectiles were fired"). It was a 30 Hz
TIME-WINDOW gate: ~21 ms beam-off (clear) + ~12 ms beam-on. Every build after it switched to a
**vblank-locked 60 Hz time-window gate** (the code that was on disk: `BLANK_CYC=119999` ~10 ms
clear + ~6.6 ms beam, `gated_done=vbl_pulse`). That regressed to ALWAYS-flicker for two reasons:
1. **Clear starved.** 60 Hz gives the DDR clear only ~10 ms; under shared-bus contention the
   row/full clear runs 10-16 ms and OVERRUNS into the beam window -> incomplete buffer.
2. **List cut at a drifting phase.** A fixed beam-on TIME window is not list-aligned; the HDMI
   vblank (window start) and the AVG vggo (list start, game clock) drift, so each present
   captures a different fragment -> incomplete/varying buffer -> flicker. `_n`'s 12 ms window +
   21 ms clear were big enough to hide both effects EXCEPT when firing grew the list/DDR load.

### The fix — capture exactly ONE complete list, list-aligned (not a time window)
New module **`rtl/present_gate.sv`** (instantiated in `tempest_sw.sv`, replacing the vbllock
block). Per 30 Hz present (FB_VBL/2, locked to HDMI = no beat): wait for the next **vggo**
(avg_go/$4800, the CPU's once-per-list kick) to OPEN the beam, then close + EOF on the **next
vggo** -> the buffer holds exactly one complete list (vggo[n]->vggo[n+1]). Result: no tail-drop
(firing-safe -> kills `_n`'s projectile flicker), no smear (one list, objects at one position),
and EOF lands ~8 ms into the 33 ms present -> the clear gets a ~25 ms window (> `_n`'s 21 ms).
Uses **vggo only**, never avg_halted (avg_halted's ~0.66 µs short idle broke prior edge gates;
bypass mode already proved vggo/halt propagate on HW). **HW-SAFE DEGRADE:** if vggo is ever dead
the ARMED/CAP timeouts (12 ms) fire and it becomes an `_n`-style time window -> never worse than
`_n`, never black. `MIN_CAP_GUARD` (0.5 ms) rejects a stray $48xx double-strobe.
`vector_fb_ddram.sv` is UNCHANGED (row-range clear, USE_RMW=0, burst clear all kept).

### Evidence (SIM FIRST — this is the discipline that was being skipped)
- **GHDL cadence probe** (`Arcade-Tempest/sim/tb_tempest.vhd` cadence proc, real ROMs, steady
  attract 700-745 ms): `9 vggo, 10 halt-rise in 45 ms`; vggo period **~4.0-4.13 ms (~245 Hz =
  the 250 Hz IRQ)**; **exactly one halt per vggo** (no sublists). => vggo->vggo = one full list,
  and at 30 Hz there are ~8 lists/present so the clear gap is huge. (output in
  `Arcade-Tempest/sim/zprobe.log`.)
- **Gate sim** (`sim/fb/tb_gate2.sv` drives the REAL present_gate, ModelSim ASE): ALL 4 PASS --
  NORMAL 360/360, **FIRING 780/780 (NO tail-drop)**, DEAD degrades (eof keeps firing, bounded,
  never black), GLITCH rejected by the guard. Run: `sim/fb/` then
  `vlib work_g2; vlog -sv -work work_g2 ../../rtl/present_gate.sv tb_gate2.sv; vsim -c -work
  work_g2 -do "run -all; quit -f" tb_gate2` (ModelSim ASE = C:/intelFPGA_lite/17.0/
  modelsim_ase/win32aloem; SV `string` is rejected there -> use int/reg in TBs).
- vlog syntax-check of present_gate + tempest_sw: 0 err / 0 warn.

### Build candidate
Quartus compile kicked (`build_listgate.log`); stage `output_files/Arcade-StarWars.rbf` ->
`releases/Arcade-Tempest_20260531.rbf` -> cab `_Arcade/cores/` (keep ONE Arcade-Tempest*.rbf).
**Expected on HW: stable static AND stable firing (no projectile flicker), no smear.** If it
flickers, the degrade path means it's at worst `_n`-quality, so compare against `_n`.

### Tunable: 30 Hz vs 60 Hz
`tempest_sw.sv` localparam `PRESENT_DIV` = 8'd2 (30 Hz, safe ~25 ms clear budget; matches `_n`'s
proven-acceptable smoothness). Set to 8'd1 for 60 Hz (smoother motion; one 4 ms list + ~7.5 ms
clear fits 16.6 ms but only ~1 ms margin -> may flicker under heavy DDR contention). Recommend
shipping 30 Hz; try 60 Hz only if 30 Hz feels choppy and HW contention proves low.

### Immediate fallback for the user
`releases/Arcade-Tempest_20260530n.rbf` is the known "almost flicker-free" build (flickers only
on fire) -- flash it to get back to good instantly if the new build needs iteration.

### New/changed files (2026-05-31)
- NEW `rtl/present_gate.sv` (the gate FSM), added to `files.qip`.
- CHANGED `rtl/tempest_sw.sv` (vbllock time-window block -> present_gate instance; vggo edge).
- NEW `sim/fb/tb_gate2.sv` (gate unit test, the quantitative judge for the gate).
- UNCHANGED `rtl/vector_fb_ddram.sv` (proven render path stays put).

---

## PRIOR (2026-05-30, end of session) — flicker framed as a time-window limit [SUPERSEDED above]

### Builds staged (releases/)
- `_r` Arcade-Tempest_20260530r.rbf = audio fix (AUDIO_S=0) + warp clip. (superseded)
- `_s` Arcade-Tempest_20260530s.rbf = `_r` + row-range clear (more paint, ~9.1ms). CURRENT.
  Clean compile, setup slack +0.239, hold +0.246.

### HW results so far
- **Warp: FIXED** (off_screen clip in vector_drawer.vhd / avg_tempest.vhd). User-confirmed.
- **Audio (AUDIO_S=0):** warp confirmed; audio "might be the same" — user DEPRIORITIZED
  ("don't worry more unless obvious"). Both POKEYs ARE summed + AUDIO_S now unsigned. Leave it.
- **Flicker (_s, row-range clear): "flickers LESS when STATIC, MORE when MOVING."**

### THE FLICKER DIAGNOSIS (fundamental — STOP tuning the time-window)
The present-gate captures a fixed TIME WINDOW (paint ms) of the continuously-redrawing AVG.
For MOVING content this is unwinnable:
- paint too SHORT (`_q` ~6.6ms): list tail (projectiles) dropped → projectile flicker.
- paint too LONG  (`_s` ~9.1ms): captures ~1.4 redraws → moving objects at 1.4 positions →
  motion SMEAR (reads as "flickers more when moving").
There is NO time-window that captures exactly one list for moving content, because the window
is not list-aligned. The fast projectiles need EXACTLY one AVG frame.

### THE CLEAN FIX (next session) — list-aligned capture, NOT a time window
Keep the row-range clear from `_s`: it frees the time BUDGET (clear ~7.5ms + one list ~8ms =
15.5ms < 16.6ms ⇒ one clean list fits a 60Hz frame). Replace the TIME-WINDOW beam-gate in
`tempest_sw.sv` with a LIST-ALIGNED one-frame capture:
- Capture beam from one frame-start to the next; EOF (swap) at the boundary ⇒ each displayed
  buffer = exactly ONE complete list ⇒ no drop, no smear.
- Boundary source: try **vggo (avg_go, the CPU's once-per-frame $1640 write)**, bounding
  vggo→vggo. avg_halted was tried (`_o`) → PARTIAL frames (short-idle quirk); prefer vggo, or
  debounce avg_halted hard.
- Throttle: capture 1 frame, clear over the next (row-range clear fits), repeat.
- **SIM FIRST:** extend `sim/fb/tb_gate.sv` with a realistic vggo+halt model (incl short idle)
  and prove one-full-list capture before building. (Do NOT blind-build — that burned ~6 builds.)
Alternative (more robust, bigger): **selective-erase** (erase prev frame's ~7k px instead of
clearing 358400 words) ⇒ present every AVG frame, no throttle, no smear, no drop.

### Known SEPARATE bug (not flicker)
OSD status-bit COLLISION in `Arcade-StarWars.sv`: osd_flip=status[7], osd_scale=status[9:8],
osd_gate_bypass=status[10] OVERLAP the game DIP decode → those OSD knobs unreliable. Reassign
CONF_STR bits.

### Key files (all in Arcade-Tempest-SW/)
- `rtl/tempest_sw.sv`: orient C (fxs=490+rx, fys=350-ry), vblank-locked gate, off_screen wired.
- `rtl/vector_fb_ddram.sv`: USE_RMW=0, USE_BURST_CLEAR=1, row-range clear (CLR_ROW_LO=45056…),
  s2_advance read gate, Z!=0 push, dedup-on-push. 100% retention in fb_metric.py.
- `rtl/avg/vector_drawer.vhd` + `avg_tempest.vhd` + `pkg_bwidow.vhd`: off_screen warp clip.
- `Arcade-StarWars.sv`: **AUDIO_S=0**.
- `sim/fb/fb_metric.py` (golden-compare judge), `tb_fb_trails.sv`, `tb_gate.sv`.
- Build: `quartus_sh --flow compile Arcade-StarWars` → `output_files/Arcade-StarWars.rbf` →
  `releases/Arcade-Tempest_<date>.rbf` → cab `_Arcade/cores/` (keep ONE Arcade-Tempest*.rbf).

## TL;DR
Tempest grafted onto the Star Wars DDR framebuffer chassis. **SOLID LINES NOW PROVEN IN SIM
(2026-05-30): 100.0% pixel retention vs golden, 0 dropped, 0 spurious, robust to 75% DDR
contention.** The dotted/broken lines are FIXED via three RTL changes in `rtl/vector_fb_ddram.sv`
(below). Judged QUANTITATIVELY by `sim/fb/fb_metric.py` (golden-compare), not by eye. The render
path is done; remaining gates are (a) multi-frame trails/clear-cadence sim, (b) HW flash + the
display-path/near-black + orientation, none of which this single-frame render sim covers.

### THE THREE FIXES (all in rtl/vector_fb_ddram.sv, baked in, no defines)
1. **s2_advance gate** (read-pipeline desync — the BIG one, contention drops). `stage2_data <=
   fifo_mem[rd_ptr]` ran EVERY cycle, so during a stall (DDRAM_BUSY or pending stage3 write)
   rd_ptr had already advanced and stage2_data decoupled from stage2_valid — the held pixel's
   data was clobbered (often with the empty-slot X), the decode bounds-check then dropped it.
   Gated the read with `s2_advance = !DDRAM_BUSY && !clearing && rmw_state==RMW_IDLE &&
   !stage3_valid` so data stays paired with valid. **74%→94% @ BUSY=8.** (Bug also exists in the
   shipping SW core; SW's sparser vectors + RMW mode masked it.)
2. **Z==0 BLANK** (`push_pix` gained `Z_VECTOR != 0`). bwidow_dw blanked Z==0; vector_fb_ddram
   lost that. In overwrite mode (USE_RMW=0) a Z==0 write deposits BLACK and ERASES crossed
   geometry. **94%→99%.**
3. **DEDUP_PUSHED** (dedup ref `last_x/y/beam_on` update only on push, not every fed point).
   A blanked move advanced the dedup ref and suppressed the draw starting on that spot = the
   first pixel of every line. **99%→100%.**

### How the root-cause was found (method, for next time)
Built `sim/fb/fb_metric.py`: replays the display list in Python with CORRECT semantics (draws
light, moves dark, no erase, no contention) → GOLDEN pixel set, compares the sim's fb_out.txt.
Added FIFO/write instrumentation to tb (pushed/popped/max_occ/overflow/accepted/issued). That
showed: NOT FIFO overflow (max_occ=3), NOT EOF flush, NOT write-clobber (issue_hot=0) — pixels
were popped but never ISSUED (issue_rise<pushed). A cycle-accurate `+define+TRACE` dump then
showed `s2v=1` while `s2d=X` → the desync. Sweep harness `sim/fb/runfb.sh <duty> [defines]`.
LESSON: the contention model (ddr_model BUSY_DUTY) was right; the prior "19% contention drop"
framing was a symptom — the real bug was a structural read-pipeline race, found only by
instrumenting push-vs-issue-vs-accept and tracing cycles, NOT by staring at the image.

## OLD TL;DR (pre-fix, kept for context)
The HW **near-black** bug is root-caused + sim-fixed. Current build `_20260530h` renders the
attract. **NOT YET HW-CONFIRMED.** The open item WAS dotted lines (~19% drop under contention).

## Build / files
- Core dir: `D:\deck\fpga\tempest\Arcade-Tempest-SW\` (Quartus project still named `Arcade-StarWars`).
- Latest staged: **`releases/Arcade-Tempest_20260530i.rbf`** + `releases/Tempest.mra` (**FLASH CANDIDATE —
  all fixes: 3 render fixes + orient C + trails-verified; Quartus clean 0 err, setup +0.652ns, hold
  +0.244ns; untested on HW**). `_20260530h` = prior (pre-fix). Cab `_Arcade/cores/` must hold ONE Arcade-Tempest*.rbf.
- Build: `"C:/intelFPGA_lite/17.0/quartus/bin64/quartus_sh.exe" --flow compile Arcade-StarWars` (~25 min);
  `quartus_map.exe Arcade-StarWars` for A&S only. Output `output_files/Arcade-StarWars.rbf` →
  copy to `releases/Arcade-Tempest_<date>.rbf`. Keep exactly ONE `Arcade-Tempest_*.rbf` in the cab's `_Arcade/cores/`.
- Current RTL fix state (2026-05-30, post solid-lines + orient + trails work):
  - `rtl/vector_fb_ddram.sv` (Tempest's own copy): `USE_RMW=1'b0` + `USE_BURST_CLEAR=1'b1`, PLUS the
    three baked-in render fixes — `s2_advance`-gated FIFO read (desync), Z==0 blank on push, dedup-on-push.
  - `rtl/tempest_sw.sv`: `rast_z=tmp_z[7:3]`, `rast_beam=|tmp_rgb`, **orient C = flip Y ONLY
    (`fxs=490+rx; fys=350-ry`)** [was 180° `490-rx/350-ry` which mirrored text],
    30 Hz present-gate (`PRESENT_TICK=19'd399999`), gate bypass = OSD status[10].
  - Quartus build for these = `build_tempest_sw_trailsfix.log` (the flash candidate).

## Root cause (SOLVED) — near-black
~9 HW builds were garbled→near-black. A 4-engineer panel + a ModelSim FB-isolation sim found:
- RULED OUT, byte-identical to the shipping SW core: FB plumbing (FB_*/DDRAM_*), clocks/CDC, and the
  present-gate (gate-OFF build `_f` was STILL near-black). Game module (tempest.vhd/avg_tempest.vhd/
  vector_drawer.vhd/pkg_bwidow/dpram2k/pokey) is byte-identical to the BW core that renders Tempest.
- THE CAUSE: the FB's DDR port SHARES one DDR3 with the ascal HDMI scan-out + HPS, so `DDRAM_BUSY` is
  high much of the time. The original FB sim used `BUSY=0` and hid it. Under real contention the
  per-pixel **read-modify-write (USE_RMW=1) dropped ~75% of pixels** (read round-trip stalls), and the
  358400-word single-beat clear is slow.
- FIX (sim-verified under modeled contention): **`USE_RMW=0`** (fire-and-forget byte-enable write, no
  per-pixel read → drop 75%→19%) **+ `USE_BURST_CLEAR=1`** (burst the clear).

## ✅ SOLVED — DOTTED/BROKEN lines (2026-05-30)
The dots were THREE bugs, not one "19% contention drop". Fixed in `rtl/vector_fb_ddram.sv` (see
the THREE FIXES in the TL;DR). Quantitative result (`fb_metric.py`, golden-compare):
  BUSY_DUTY:        baseline(no fix)   s2_advance   +Z==0 blank   +dedup(all 3)
  0  (no contend):       94%              99%           99%           100.0%
  8  (50% busy):         74%              94%           99%           100.0%   <- HW-realistic-pessimistic
  12 (75% busy):         (n/a)            --            --            100.0%   <- still perfect
  14 (87% busy):         --               --            --           incomplete-drain (unrealistic)
0 dropped, 0 spurious, FIFO max_occ=3. The prior EOF-flush suspicion was WRONG (only 3/53 residual
missing were in the tail; root cause was the read-pipeline desync). The render path is DONE.

### Remaining gates
1. **Multi-frame trails / clear cadence — ✅ DONE (2026-05-30).** Built `sim/fb/tb_fb_trails.sv`:
   draws frame A → swap → draws frame B into the RECYCLED buffer (buf2), which is PRE-FILLED with a
   white MARKER (stale-content stand-in, since the ddr_model's sparse mem reads uninit as 0 and would
   hide a failed clear). **RESULT: frame B renders 100% clean, marker-survivors=0, spurious=0, no
   drops — at BUSY 0/4/8/12.** The inter-frame clear FULLY zeroes the recycled buffer; no trails.
   ⚠️ **BUDGET caveat the sim surfaced:** the full-buffer clear is slow — 8.1 ms @0% / 10.8 ms @25% /
   16.1 ms @50% / 32.3 ms @75% contention (inherent: zeroing 2.87 MB at ~1 word/cyc/50 MHz; the
   ddr_model gates each burst beat on !busy = realistic for a shared bus). The 30 Hz present-gate =
   33 ms budget, so at realistic contention (~25% → 11 ms) it fits with margin; only ~75% approaches
   the limit (then frame pixels could back up past the 8192 FIFO → drops). FIRST AGGRESSIVE run (B fed
   10 µs after the clear started, before it finished) showed the failure mode directly: B's pixels
   stuck in FIFO, buf2 88% marker, swap never happened. So on HW: if frames stutter/drop under heavy
   load, the clear is the cause — fixes = true burst streaming (if real DDR bursts beat the per-beat
   model) or selective-erase (erase only prev-frame's ~7k pixels vs 358400 words). burst-clear "went
   black" in a prior life (FSM) but the FB sim now proves it clears correctly; single-beat
   (USE_BURST_CLEAR=0) is the SW-proven fallback. Run: `vlog ddr_model.sv tb_fb_trails.sv
   ../../rtl/vector_fb_ddram.sv; vsim -gBUSY_DUTY=8 ... tb_fb_trails; python fb_metric.py`.
2. **HW flash + display path** — this sim reads the DRAWN DDR buffer directly; it does NOT model
   the present-gate (in tempest_sw.sv, not vector_fb_ddram), ascal scanout, or the 60/30Hz cadence.
   The earlier near-black HW was likely display-path, not render-path (now proven solid). With the
   render fixed, flashing is the logical next test.
3. **Orientation — ✅ RESOLVED (2026-05-30, orient "C" = flip Y only).** The core HAD flip-X-and-Y
   (`fxs=490-rx; fys=350-ry`) which MIRRORS the text. Rendered all 4 flip combos from the raw
   display list (`sim/fb/render_orient.py` → `orient_montage.png` + `orient_A..D.png`); user picked
   **C**: `fxs=490+rx` (X NOT flipped), `fys=350-ry` (Y flipped → right-side-up). Text now reads
   FORWARD with the ©ATARI/BONUS/CREDITS block along the bottom + INSERT COINS upper-middle = the
   correct attract layout (`sim/fb/fb_replay.png`). Set in `tempest_sw.sv` + tb + fb_metric (all in
   sync). Still 100% solid (orientation is a bijection). Physical portrait-monitor rotation is a
   SEPARATE runtime knob (OSD Rotate/Mirror = status[5:9]); this fixes the framebuffer-content
   baseline only.

### New sim tooling (this session)
- `sim/fb/fb_metric.py` — THE quantitative judge. Golden-compare: retention / missing / spurious /
  erase-risk. Run after any replay. Reads `fb_out.txt`. (Supersedes eyeballing fb_replay.png.)
- `sim/fb/runfb.sh <BUSY_DUTY 0..16> [vlog-defines]` — compile+run+metric in one shot (~2s).
- `tb_fb_replay.sv` — added FIFO/write instrumentation (pushed/popped/max_occ/overflow/accepted/
  issued/clobber) + `+define+TRACE` cycle dump → trace.txt. These pinned the desync.

## Sim harness — `D:\deck\fpga\tempest\Arcade-Tempest-SW\sim\fb\`
- `ddr_model.sv` — behavioral DDR: BUSY-duty contention (param `BUSY_DUTY`/16) + burst-write + sparse mem.
- `tb_fb.sv` — feeds 20 known lit pixels; reads back nonzero words per buffer (pixel-drop test).
- `tb_fb_replay.sv` — replays the real display list (`../../../Arcade-Tempest/sim/tempest_frame.txt`)
  through tempest_sw's coord-map → real `vector_fb_ddram` → dumps `fb_out.txt`.
- `render_fb.py` — `fb_out.txt` → `fb_replay.png` + ASCII density map.
- Run: `MS=C:/intelFPGA_lite/17.0/modelsim_ase/win32aloem; "$MS/vlog.exe" -sv ddr_model.sv
  tb_fb_replay.sv ../../rtl/vector_fb_ddram.sv && "$MS/vsim.exe" -c -do "run -all; quit -f"
  tb_fb_replay` ; then `python render_fb.py`. ModelSim ASE is fast (~1-2 s).
- GHDL AVG capture: `Arcade-Tempest/sim/tb_tempest.vhd` frame_cap → `tempest_frame.txt` (ax ay rgb az);
  `gap_analysis.py` measures walk granularity. (The game module is byte-identical, so this capture is
  faithful to the SW-chassis Tempest.)

## Don't re-litigate
- FB plumbing, clocks/CDC, the present-gate, the game module: all proven NOT the bug. The render path
  is correct (the contended replay renders the attract at 81% pixels). It's a DDR-contention throughput
  problem now (pixel drops → dots; possibly clear cadence → trails), nothing more.
- Image-by-eye is unreliable here — use gap_analysis / pixel-count metrics to judge solidity.

## Major Havoc (parallel project, not blocked on Tempest)
P1 dual-6502 boot gate PASSED in sim. `D:\deck\fpga\majorhavoc\`, see HANDOFF-majorhavoc.md. Next = P2
AVG color, or P1-tail (gamma $2800 flags / 60Hz IRQ).
