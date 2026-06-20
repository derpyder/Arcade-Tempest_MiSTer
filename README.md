# Tempest (Atari, 1981) for MiSTer FPGA

A MiSTer FPGA core for **Tempest**, Atari's 1981 color-vector tube shooter. There
is no Tempest core on MiSTer main; this one is built by grafting a new Tempest
game module onto the proven **Star Wars** color-vector chassis
([Videodr0me/Arcade-StarWars_MiSTer](https://github.com/Videodr0me/Arcade-StarWars_MiSTer)),
reusing its DDR3 vector framebuffer, display path, audio chain, and OSD.

> **Status:** boots and is playable on real DE10-Nano hardware — fire,
> superzapper, coins, audio, and a stable flicker-free display all confirmed, and
> the picture fills the screen with clean integer scaling up to 4K (see
> [Vector presentation](#vector-presentation--the-flicker-fix)). Rotation is
> confirmed on hardware via both the analog stick and a **USB mouse / spinner**
> (velocity-sensitive, with an OSD direction toggle) — see [Controls](#controls).

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
   `_Arcade/cores/` and rename it to **`Tempest.rbf`** (keep exactly one
   `Tempest*.rbf` there). The MRA's `<rbf>Tempest</rbf>` matches this name; the
   firmware ignores any `_<date>` suffix, so `Tempest_20260602.rbf` works too.
   *(This matches the MiSTer Distribution layout, where the `Arcade-` prefix is
   stripped — see [update_all](#update_all-distribution).)*
2. Copy **`releases/Tempest.mra`** to `_Arcade/`.
3. **Required:** put the Tempest romset **`tempest.zip`** (MAME `tempest`, the
   Rev-3 parent set) in `games/mame/`. **The core will not run without it** — the
   MRA loads the ROMs from this zip and lists the exact CRCs it expects. ROMs are
   not included in this repo or release.

Launch the MRA from the MiSTer arcade menu.

## Controls

Tempest's tube is controlled by a knob (a 4-bit up/down encoder in the real
hardware). This core feeds that knob from any of three sources, in priority order:

| Input | Action |
|---|---|
| **Spinner / paddle** (USB) | Rotate around the tube — the authentic control |
| **USB mouse** (move L / R) | Rotate (same path as a spinner; velocity-sensitive) |
| **Left analog stick** | Rotate (rate-proportional: full throw = fast, feather = fine) |
| **D-pad ← / →** | Rotate (fixed rate) |
| **Fire** / mouse left btn | Fire |
| **Superzapper** / mouse right btn | Superzapper (screen-clear, limited) |
| **Start 1P / 2P** | Start |
| **Coin** | Insert coin |

> **Spinner / mouse:** rotation is **velocity-sensitive** — small movements nudge
> the tube one notch at a time, faster movements spin proportionally faster, all
> kept within the game's 4-bit knob decode so the direction is always correct at any
> speed. The path is confirmed on hardware with a **USB mouse** (which is how most
> USB spinners enumerate). If your spinner turns the wrong way, flip **Spinner
> Reverse** in the OSD. Dedicated spinner devices feed the same internal stepper; if
> yours needs a tweak, please
> [report back](https://github.com/derpyder/Arcade-Tempest_MiSTer/issues).

## OSD options

Beyond the standard MiSTer video/scaler options, this core exposes:

- **Aspect ratio** — *Optimized* (auto integer scale: the 980×720 frame is scaled
  ×1/×1.5/×2/×3 to best fit your output — ×3 fills 4K vertically exactly) or
  *Pixel Perfect* (1:1). The vector image is drawn to fill the frame either way.
- **Rotate / Flip** — orientation relative to the built-in baseline, for portrait
  cabinet monitors.
- **Frame Gate** — *On* (normal) presents via the persistence gate; *Off* is a
  native AVG pass-through diagnostic.
- **Persistence** — how many complete vector redraws are accumulated per displayed
  frame (3 default / 4 / 6 / 2). Higher = more phosphor-like ghosting/trails and
  more resistance to dropped beams; lower = crisper but flickerier.
- **Spinner Reverse** — flip the spinner/mouse rotation direction (Off / On), so a
  clockwise turn of your device matches clockwise on the tube.

## update_all / Distribution

This repo follows the MiSTer external-core layout that theypsilon's
[Distribution_Unofficial_MiSTer](https://github.com/theypsilon/Distribution_Unofficial_MiSTer)
scanner expects, so it can be tracked by `update_all`:

- The core lives in **`releases/`** as a **date-stamped** `Arcade-Tempest_<YYYYMMDD>.rbf`
  (the scanner skips any un-dated `.rbf` and always picks the newest date).
- The installer copies it to `_Arcade/cores/` **stripping the `Arcade-` prefix** →
  `Tempest_<date>.rbf`, which is why the MRA uses `<rbf>Tempest</rbf>`.
- The `.mra` sits in `releases/` and is copied to `_Arcade/`.

To get it tracked, theypsilon adds one row to that repo's `external_mister_repos.csv`:
`https://github.com/derpyder/Arcade-Tempest_MiSTer, _Arcade,,`. (Note: that repo's
README currently says "No new cores will be added," so acceptance is at theypsilon's
discretion — until then, users can add the repo to their own `downloader.ini`.)

## 480p @ 120 Hz on a CRT PC monitor

This core can be driven at **480p120 on a multisync CRT PC monitor** via `MiSTer.ini`
(no rebuild needed). See **[docs-480p120-crt.md](docs-480p120-crt.md)** for the exact
settings, the scan-rate math, and the monitor requirement.

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
