# Tempest (Atari, 1981) for MiSTer FPGA

A MiSTer FPGA core for **Tempest**, Atari's 1981 color-vector tube shooter. There
is no Tempest core on MiSTer main; this one is built by grafting a new Tempest
game module onto the proven **Star Wars** color-vector chassis
([Videodr0me/Arcade-StarWars_MiSTer](https://github.com/Videodr0me/Arcade-StarWars_MiSTer)),
reusing its DDR3 vector framebuffer, display path, audio chain, and OSD.

> **Status:** boots and is playable on real DE10-Nano hardware — spinner, fire,
> superzapper, coins, and audio all confirmed, and the display is stable (see
> [Vector presentation](#vector-presentation--the-flicker-fix)).

> ⚠️ **ROMs required — not included.** This core does nothing without the Tempest
> romset. You must supply **`tempest.zip`** (MAME `tempest`) in your MiSTer's
> `games/mame/` folder. No ROMs are distributed here (Tempest is © 1981 Atari).
> See [Install](#install).

---

## Why "Star Wars chassis"?

Tempest and Star Wars run on closely related Atari Analog Vector Generator (AVG)
hardware. Rather than re-implement the hard parts — the DDR3 triple-buffered vector
framebuffer, the MISTER_FB scan-out, clock/CDC plumbing, the OSD — this core hosts
a Tempest **game module** inside Videodr0me's Star Wars project and routes its AVG
vector output into the same `vector_fb_ddram` rasterizer that ships in Star Wars.

One consequence: the Quartus project, the top-level entity, and the output bitstream
are still named `Arcade-StarWars` internally. What you flash is renamed to
**`Arcade-Tempest.rbf`**, and the MRA's `<rbf>Arcade-Tempest</rbf>` points at it.

## What's in this core (vs. the Star Wars chassis it sits on)

**New — the Tempest game module** (`rtl/tempest.vhd`, `rtl/avg/avg_tempest.vhd`,
`rtl/tempest_sw.sv`):

- **6502 (T65)** CPU with Tempest's memory map, transcribed from MAME's
  `atari/tempest.cpp` — program ROM/RAM, vector RAM (4K) + vector ROM (4K),
  the 16-entry color RAM at `$0800`, IN0/DSW decode, coin/flip latches, and the
  ~250 Hz IRQ.
- **Color AVG** (`avg_tempest.vhd`) — a Tempest variant of Jeroen Domburg's
  behavioral Black Widow AVG, with Tempest's color-RAM lookup and X/Y handling.
- **2× POKEY** audio, the **spinner** (read through POKEY 1's pot lines), the Atari
  **math box** (shared Battlezone/Red Baron/Tempest behavioral model), and the
  EAROM stub.
- A **coordinate map** (Tempest tube → the 980×700 framebuffer) and a
  **phosphor-persistence vector present-gate** (`rtl/present_gate.sv`) — see below.

**Reused, unchanged — Videodr0me's Star Wars chassis:** `vector_fb_ddram.sv` (the
DDR3 triple-buffer vector framebuffer), the MISTER_FB display path, the `sys/`
MiSTer framework, clock/CDC plumbing, and the OSD/DIP infrastructure.

## Vector presentation — the flicker fix

A real Tempest redraws its whole vector display list ~200–250 times a second, and
the CRT phosphor *integrates* those redraws: any beam a single redraw happens to
miss is refilled by the next, and fast objects leave a soft trail. That integration
is what makes a real tube look rock-steady.

A DDR framebuffer has no phosphor, so presenting one redraw per displayed frame
exposes every beam the shared-DDR bus drops (intermittent dropped beams when idle)
and any list cut mid-draw drops its tail (flashing projectiles when firing).

`rtl/present_gate.sv` emulates the phosphor: it accumulates **N complete AVG lists**
(each bounded by the CPU's once-per-list `vggo`/`$4800` strobe) into one draw buffer
with no clear between them — a union of N redraws. Dropped beams get refilled across
redraws (no idle flicker), and because every accumulated list is *complete*, the
projectile tail is never cut (no firing flash). The framebuffer keeps swapping on
its own scan-out vblank, so the per-frame clear window is never visible. **N is a
live OSD knob** ("Persistence") so you can dial the amount of ghosting on hardware.
The fix is verified in simulation (`sim/fb/tb_gate2.sv`).

## Install

1. Copy **`releases/Arcade-Tempest_<date>.rbf`** to your MiSTer's
   `_Arcade/cores/` and rename it to **`Arcade-Tempest.rbf`** (keep exactly one
   `Arcade-Tempest*.rbf` there).
2. Copy **`releases/Tempest.mra`** to `_Arcade/`.
3. **Required:** put the Tempest romset **`tempest.zip`** (MAME `tempest`, the
   Rev-3 parent set) in `games/mame/`. **The core will not run without it** — the
   MRA loads the ROMs from this zip and lists the exact CRCs it expects. ROMs are
   not included in this repo or release.

Launch the MRA from the MiSTer arcade menu.

## Controls

| Input | Action |
|---|---|
| **Spinner** (or paddle) | Rotate around the tube |
| **Fire** | Fire |
| **Superzapper** | Superzapper (screen-clear, limited) |
| **Start 1P / 2P** | Start |
| **Coin** | Insert coin |

The MRA also maps these to a standard pad (Fire / Superzapper / Start / Coin); a
real spinner gives the intended control.

## OSD options

Beyond the standard MiSTer video/scaler options, this core exposes:

- **Aspect ratio** — *Optimized* (auto integer scale to your output) or
  *Pixel Perfect* (1:1).
- **Rotate / Flip** — orientation relative to the built-in baseline, for portrait
  cabinet monitors.
- **Frame Gate** — *On* (normal) presents via the persistence gate; *Off* is a
  native AVG pass-through diagnostic.
- **Persistence** — how many complete vector redraws are accumulated per displayed
  frame (3 default / 4 / 6 / 2). Higher = more phosphor-like ghosting/trails and
  more resistance to dropped beams; lower = crisper but flickerier.

## Known limitations

- **Hi-score persistence** is not implemented (the EAROM is stubbed), so scores
  reset on power cycle.
- Internal project/bitstream identity is `Arcade-StarWars` (see
  [above](#why-star-wars-chassis)).

## Building

Quartus Prime 17.0 (Cyclone V / DE10-Nano):

```
quartus_sh --flow compile Arcade-StarWars
# -> output_files/Arcade-StarWars.rbf  ->  rename to Arcade-Tempest_<date>.rbf
```

Simulation lives in `sim/` (ModelSim ASE present-gate / framebuffer tests) and the
GHDL boot/cadence testbench. See `HANDOFF-tempest-sw-resume.md` for the sim recipes
and design history.

## Credits & license

This core stands on a lot of prior work:

- **Videodr0me** — the Star Wars MiSTer port and the `vector_fb_ddram` DDR3 vector
  framebuffer chassis this core is built on.
- **Jeroen Domburg (Sprite_tm)** — the behavioral Black Widow AVG that
  `avg_tempest` is derived from.
- **Dave Wood / fpgaarcade / alanswx** and the broader MiSTer/MAME communities —
  the Atari vector hardware lineage, T65, POKEY, math box, and reference models.
- **MAME** — the authoritative Tempest memory map and hardware behavior.

Original code is **GPLv3** (see `COPYING`); third-party modules retain their own
licenses (see file headers and `LICENSES`). This is a non-commercial,
preservation-oriented project and is not affiliated with Atari.
