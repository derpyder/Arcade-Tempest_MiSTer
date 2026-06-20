//============================================================================
//  Arcade: Star Wars
//
//  Port to MiSTer FPGA by Videodr0me 2026
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1    = 0;
assign VGA_SCALER= 1;
assign VGA_DISABLE = 0;
assign VGA_SL = 0;
assign USER_OUT  = '1;
wire [2:0] core_led;
assign LED_USER  = core_led[2] | ioctl_download;
assign LED_DISK  = {1'b1, core_led[1]};
assign LED_POWER = {1'b1, core_led[0]};
assign BUTTONS   = 0;
assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;

assign CLK_VIDEO = clk_108; // Direct PLL output (109 MHz)
assign CE_PIXEL = ce_pix;   // Video clock enable: gates CLK_VIDEO to derive 60Hz/120Hz
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_DE = ~(hblank | vblank);
assign VGA_R = 0;
assign VGA_G = 0;
assign VGA_B = 0;

wire [1:0] ar = status[15:14];

// Auto-detect optimal display size from HDMI output resolution.
// Pick the largest clean scale factor that fits the output.
// FB is 980×720. Integer scales: ×1=980×720, ×1.5=1470×1080, ×2=1960×1440, ×3=2940×2160.
// 720 height makes EVERY step land on a real panel height (×3 = 2160 = exact 4K fill — the
// whole reason for 700->720; 700×3=2100 letterboxed 4K).  Thresholds gate on OUTPUT height
// and now equal the scaled height exactly (×3 needs >=2160, ×2 >=1440, ×1.5 >=1080).
reg [12:0] auto_arx, auto_ary;
always @(*) begin
	if (HDMI_HEIGHT >= 2160) begin
		// 4K (3840×2160): ×3 integer scale, fills vertical EXACTLY
		auto_arx = 13'h1B7C;  // 0x1000 | 2940
		auto_ary = 13'h1870;  // 0x1000 | 2160
	end else if (HDMI_HEIGHT >= 1440) begin
		// 1440p (2560×1440): ×2 integer scale
		auto_arx = 13'h17A8;  // 0x1000 | 1960
		auto_ary = 13'h15A0;  // 0x1000 | 1440
	end else if (HDMI_HEIGHT >= 1080) begin
		// 1080p (1920×1080): ×1.5 scale (3:2)
		auto_arx = 13'h15BE;  // 0x1000 | 1470
		auto_ary = 13'h1438;  // 0x1000 | 1080
	end else begin
		// 720p (1280×720) or smaller: 1:1 pixel perfect
		auto_arx = 13'h13D4;  // 0x1000 | 980
		auto_ary = 13'h12D0;  // 0x1000 | 720
	end
end

// Aspect menu = {0:Optimized, 1:Pixel Perfect} (Stretched removed).  ar==0 ->
// auto-detected integer scale; else (ar==1) -> 1:1 pixel-perfect.  Both modes
// HW-tested good; the dropped Stretched arm (was ar==1) is simply gone.
assign VIDEO_ARX = (ar == 0) ? auto_arx :  // Optimized (auto-detect)
                               13'h13D4;   // Pixel Perfect (1:1, 980)

assign VIDEO_ARY = (ar == 0) ? auto_ary :  // Optimized (auto-detect)
                               13'h12D0;   // Pixel Perfect (1:1, 720)

// 120Hz MODE — SAFE ACTIVATION
// The HPS restores saved status bits (including status[25]=120Hz ON)
// during boot, BEFORE HDMI_HEIGHT is valid during initialization → HDMI sync loss.

// --- Stage 1: Boot holdoff (~1.3 seconds after FPGA config) ---
// Core ALWAYS starts outputting 60Hz timing regardless of saved settings.
reg [26:0] boot_cnt = 0;
reg boot_done = 0;
always @(posedge clk_50) begin
	if (!boot_cnt[26])
		boot_cnt <= boot_cnt + 1'd1;
	else
		boot_done <= 1;
end

// --- Stage 2: HDMI_HEIGHT validation
// Require height to be in a valid range (256-720) and stable for ~335ms.
wire is_720p_valid = (HDMI_HEIGHT >= 12'd256) & (HDMI_HEIGHT <= 12'd720);
reg [24:0] stable_720p_cnt = 0;
reg is_720p_stable = 0;
always @(posedge clk_50) begin
	if (!is_720p_valid) begin
		stable_720p_cnt <= 0;
		is_720p_stable <= 0;
	end else if (!stable_720p_cnt[24]) begin
		stable_720p_cnt <= stable_720p_cnt + 1'd1;
	end else begin
		is_720p_stable <= 1;
	end
end

// --- Stage 3: 120Hz mode signal
// If boot holdoff expired, user wants 120Hz, and HDMI_HEIGHT has been stable.
wire osd_120hz_mode = boot_done & status[25] & is_720p_stable;
wire not_720p = ~is_720p_stable;

// --- Video mode change notification ---
reg new_vmode_toggle = 0;
reg mode_120_prev = 0;
reg boot_done_prev = 0;
always @(posedge clk_50) begin
	boot_done_prev <= boot_done;

	if (!boot_done) begin
		// During boot: silently track status[25] without firing vmode
		mode_120_prev <= status[25];
	end else begin
		// After boot: fire vmode on user OSD toggle
		mode_120_prev <= status[25];
		if (mode_120_prev != status[25])
			new_vmode_toggle <= ~new_vmode_toggle;
	end

	// Fire once when boot holdoff expires and 120Hz is activating
	if (boot_done & !boot_done_prev & osd_120hz_mode)
		new_vmode_toggle <= ~new_vmode_toggle;
end

`include "build_id.v" 
localparam CONF_STR = {
	"Tempest;;",
	"-;",
	"OEF,Aspect ratio,Optimized,Pixel Perfect;",
	"D2OP,120Hz (720p only),Off,On;",
	"-;",
	"O56,Rotate,0,90,180,270;",
	"O7,Mirror,Off,On;",
	"OA,Frame Gate,On,Off;",
	"OST,Persistence,3 (default),4,6,2;",
	"OU,Spinner Reverse,Off,On;",
	"OBD,Spinner Sensitivity,Default,Low,Lower,High,Higher;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Fire,Superzapper,Fire Down,Fire Up,Start 1P,Start 2P,Coin,Pause;",
	"jn,A,B,X,Y,Start,Select,R,L;",
	"V,v1.2.",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_6, clk_12, clk_50, clk_108;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_50),
	.outclk_1(clk_12),
	.outclk_2(clk_6),
	.outclk_3(clk_108),
	.locked(pll_locked)
);


///////////////////////////////////////////////////

wire [31:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        ioctl_wr;
wire        ioctl_rd;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;

wire [15:0] joy_0, joy_1;
wire [15:0] joy = joy_0 | joy_1;
wire [15:0] joy_l_analog_0;
wire  [8:0] spinner_0, spinner_1;   // dedicated USB spinner devices (hps_io)
wire [24:0] ps2_mouse;              // USB/PS2 mouse: [15:8]=X, [4]=Xsign, [1:0]=R/L btn, [24]=toggle
wire        rom_download = ioctl_download && !ioctl_index;
wire        nvram_download = ioctl_download && (ioctl_index == 8'd4);
wire [24:0] dl_addr = ioctl_addr;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_12),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.status_menumask({not_720p, mod_starwars, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.new_vmode(new_vmode_toggle),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joy_0),
	.joystick_1(joy_1),
	.joystick_l_analog_0(joy_l_analog_0),
	.spinner_0(spinner_0),         // dedicated USB spinner P1: [7:0]=signed delta, [8]=toggle
	.spinner_1(spinner_1),         // dedicated USB spinner P2
	.ps2_mouse(ps2_mouse)          // USB/PS2 mouse: movement (X) + L/R buttons -> knob + fire/zap
);

// DIP switch loading — currently unused (game settings via Test Mode / NVRAM)
// reg [7:0] sw[8];
// always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// ===== Tempest inputs =====
// MRA DIP switches (ioctl_index=254): sw[0]=DSW1, sw[1]=DSW2,
// sw[2]=difficulty(1:0)/rating(2)/cabinet(4)  (read via the POKEY pots).
reg [7:0] sw[8];
always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// ===== Spinner -> 4-bit knob counter (t_spin) =====
// MAME models Tempest's knob as a 4-bit (0x0f) up/down count read on IN1_DSW0[3:0]
// (atari/tempest.cpp: IPT_DIAL, FULL_TURN_COUNT 72, into POKEY1).  The game reads this
// nibble and deltas it; t_spin IS that counter.  Three input sources:
//
//   1. REAL USB spinner (hps_io spinner_0/1): the authentic path.  spinner_x[8] toggles
//      on every HPS poll that has new movement; spinner_x[7:0] is the signed delta.
//   2. Left analog stick: rate-proportional NCO (full throw = fast, feather = fine).
//   3. D-pad L/R: fixed-rate fallback.
//
// ── SPINNER SCALING BUG FIX (was: dead spinners on every release) ──────────────────────
// The old code did `t_spin += sp_delta[7:2]` — an arithmetic >>2 applied PER POLL.  Real
// MiSTer spinners send SMALL per-poll deltas (often +-1..+-3); >>2 floors those to 0, so the
// movement was silently DISCARDED and the spinner felt dead unless cranked violently (and
// asymmetric: -1>>2 = -1 but +1>>2 = 0).  Reference: the proven Arkanoid core scales spinner
// deltas UP (x2..x16), never down — raw spinner deltas are small, not large.
// FIX: a LOSSLESS accumulator (Arkanoid pattern).  Add the FULL signed delta into a wide
// accumulator every poll; emit one knob step per SPIN_DIV accumulated units and KEEP the
// remainder.  Nothing is ever floored away, so slow spinning registers; SPIN_DIV sets feel.
wire signed [7:0] t_ax       = $signed(joy_l_analog_0[7:0]);
wire        [7:0] t_amag_raw = t_ax[7] ? (~joy_l_analog_0[7:0] + 8'd1) : joy_l_analog_0[7:0];
wire        [7:0] t_amag     = (t_amag_raw > 8'd12) ? t_amag_raw : 8'd0;
wire        [7:0] t_rate     = (t_amag != 8'd0) ? t_amag : ((joy[1]|joy[0]) ? 8'd56 : 8'd0);
wire              t_inc      = (t_amag != 8'd0) ? ~t_ax[7] : joy[0];

reg  [3:0]  t_spin = 4'd0;
reg  [22:0] t_phase = 23'd0;
reg         t_pamsb = 1'b0;

// Real-spinner edge detect: each device's bit 8 toggles on a new delta.  XOR (not OR) so a
// single-device update always makes an edge (OR can mask updates; one knob is the norm).
wire        sp_tgl  = spinner_0[8] ^ spinner_1[8];
reg         sp_tgl_d = 1'b0;

// Mouse/spinner -> 4-bit relative knob.  The knob is a RELATIVE dial the game reads-and-deltas,
// so per movement event we ADD the (gained) signed delta straight into t_spin in ONE cycle.
//
// VELOCITY GAIN (analog feel): the gain TRACKS how fast you move -- slow drag ~2x (fine aim),
// fast flick ~8x (quick rotation), smooth between.  gain = clamp(|delta|, 2, 8): a 1-2 count
// poll gives 2x, a >=8 count poll gives 8x, and 3..7 ramp linearly.  This interpolates the two
// fixed bookends (2x/8x) the user liked into a continuous analog response.  (Replaces the fixed
// "Mouse Speed" menu; per-poll |delta| IS the mouse/spinner velocity since the HPS polls steadily.)
//
// DIRECTION: CW knob should turn the claw CW.  Absolute polarity is hardware-dependent (encoder
// wiring + our 720 Y-flip in the coord map can invert it) and -- because Tempest's level 1 is a
// CIRCLE -- screen +-x can't disambiguate rotation (same spin looks opposite at top vs bottom of
// the rim).  So expose a runtime OSD "Spinner Reverse" (status[30]); set CW->CW on the cab.
wire osd_sp_rev = status[30];

// --- input source: PS/2 MOUSE or a dedicated USB SPINNER ---
// A plain USB mouse lands in ps2_mouse (NOT spinner_0): ps2_mouse[15:8] is the X delta as a
// SIGNED 8-bit 2's-complement value (-1 = 0xFF; bit[4] is just the redundant PS/2 sign copy --
// do NOT treat [15:8] as magnitude or you get -255 for -1).  Strobe = ps2_mouse[24] toggling;
// buttons in [1:0].  A dedicated spinner lands in spinner_0/1 ([8] toggles, [7:0] signed).
// Accept EITHER: edge on ps2_mouse[24] OR the spinner toggle, use whichever moved (X-axis only).
reg  ps2_tgl_d = 1'b0;
wire ps2_tgl   = ps2_mouse[24];
wire ps2_evt   = ps2_tgl ^ ps2_tgl_d;
wire spin_evt  = sp_tgl  ^ sp_tgl_d;
// mouse X delta -- EXACTLY the HW-proven Arcade-Arkanoid decode (read verbatim from its source):
//     position <= position + {{4{ps2_mouse[4]}}, ps2_mouse[15:8]};
// i.e. ps2_mouse[15:8] is the 8-bit X byte and ps2_mouse[4] is its sign EXTENSION bit; the value
// is the two's-complement formed by replicating bit[4] above byte[15:8].  (My earlier "negate the
// magnitude" decode computed -255 for a real -1 = 0xFF -> constant runaway spin.  Copy the
// working core, don't re-derive.)  9-bit signed result here = {1 more sign bit, the 8 byte bits}.
wire signed [8:0] ps2_dx = $signed({ps2_mouse[4], ps2_mouse[15:8]});
wire signed [8:0] sp_dx  = $signed(spinner_0[7:0]) + $signed(spinner_1[7:0]); // dedicated spinner X
wire signed [8:0] sp_in  = ps2_evt ? ps2_dx : sp_dx;                 // raw per-event delta
wire signed [8:0] sp_raw = osd_sp_rev ? -sp_in : sp_in;             // optional direction reverse

wire        [8:0] sp_mag  = sp_raw[8] ? (~sp_raw + 9'd1) : sp_raw;   // |sp_raw| = move distance

// ===== RATE-PACED +-1 STEPPER (velocity = step RATE, not step SIZE) =====
// PROVEN on HW: the game decodes the 4-bit dial by (new-old) wrap, so any per-frame jump >=8
// reads as the WRONG direction (that was the long-standing "always spins one way" bug -- our old
// velocity gain emitted +-8 jumps).  At pure +-1/event, direction is CORRECT (HW-confirmed) but
// slow.  FIX: keep every knob change to +-1, but EMIT MORE OF THEM when the mouse moves fast --
// velocity drives the RATE, never the size.  Per move event, ADD |delta| into a pending-step
// queue and latch the direction; a fast pacer drains the queue at +-1 per tick.  Small move = a
// few steps (fine/incremental); fast move = many steps drained quickly (fast spin); in between
// scales smoothly.  Steps are spaced (PACE_DIV) so a 60 Hz game sample never sees >=8 -> direction
// stays correct at any speed.  Queue capped so a huge flick can't run away.
// PACING IS RELATIVE TO THE GAME'S ~60 Hz DIAL READ (200000 clk_12/frame).  The previous
// PACE_DIV=24 emitted a step every ~2 us = ~8000 steps/frame -- so a burst of USB mouse polls
// (mice poll 125-1000 Hz, game reads ~60 Hz) dumped many steps into ONE frame -> the game saw a
// big (>=8) jump -> the same direction-inversion/"confused movement" we fixed, sneaking back via
// poll bursts.  Fix: pace at ~2.3 ms/step = ~7 steps per 60 Hz frame -- the MAX that stays under
// the 8-step inversion threshold -- so even a fast poll burst is spread to <=7/frame (direction
// always correct) and reads as SMOOTH motion.  ~6 turns/sec top speed (plenty).  Queue cap small
// (~14) so a hard flick glides at most ~2 frames, not a long coast.
localparam [15:0] PACE_DIV  = 16'd28000; // one +-1 every ~2.33 ms -> ~7 steps / 60Hz frame
localparam [9:0]  STEP_CAP  = 10'd14;    // bound a flick to ~2 frames of glide
reg  [9:0]  sp_queue = 10'd0;            // pending +-1 steps remaining
reg         sp_qdir  = 1'b0;             // direction of the queued steps (1=down)
reg  [15:0] sp_pace  = 16'd0;            // pace counter (widened for PACE_DIV)
// --- SLOW-END de-sensitize (input gain 3/4, lossless 2-bit carry) -----------------------
// "Fast is great, slow is a touch too sensitive": cut the INPUT gain to 3/4 with a CARRIED
// remainder so small moves are never floored to zero (that flooring was an old bug).  FAST
// flicks already saturate STEP_CAP, so this leaves fast feel UNCHANGED and only calms SLOW
// drags (small per-poll deltas now accumulate 3:4 instead of 1:1).
// Retune one spot: calmer 1/2 = ({1'b0,sp_mag}+{9'd0,sp_frac1})>>1 ; original 1/1 = sp_mag.
reg  [1:0]  sp_frac   = 2'd0;            // carried 1/4-steps (lossless)
// OSD Spinner Sensitivity (status[13:11]): scales the INPUT gain via a selectable numerator over a
// fixed /4 denominator (so the lossless 2-bit carry is preserved).  Index 0 = Default = x3/4 (the
// HW-tuned value, identical to the previous fixed mag*3>>2); higher = more on-screen rotation per
// unit of spinner/mouse motion.  The direction-safe pacer (PACE_DIV) and glide cap (STEP_CAP) are
// deliberately UNCHANGED -- sensitivity only sets how fast the +-1 step queue fills.
reg  [3:0] sp_gain_num;                                                  // gain = sp_gain_num / 4
always @(*) case (status[13:11])
	3'd0: sp_gain_num = 4'd3;   // Default  x3/4 (current)
	3'd1: sp_gain_num = 4'd2;   // Low      x1/2
	3'd2: sp_gain_num = 4'd1;   // Lower    x1/4
	3'd3: sp_gain_num = 4'd4;   // High     x1
	3'd4: sp_gain_num = 4'd6;   // Higher   x3/2
	default: sp_gain_num = 4'd3;
endcase
wire [12:0] sp_scaled = sp_mag * sp_gain_num + {11'd0, sp_frac};         // |delta|*num + carry
wire [10:0] sp_full   = sp_scaled[12:2];                                 // >>2  -> gain num/4
wire [8:0]  sp_steps  = (sp_full > 11'd511) ? 9'd511 : sp_full[8:0];     // 9-bit (STEP_CAP=14 caps anyway)
wire [1:0]  sp_remn   = sp_scaled[1:0];                                  // remainder, kept

always @(posedge clk_12) begin
	sp_tgl_d  <= sp_tgl;
	ps2_tgl_d <= ps2_tgl;
	t_pamsb   <= t_phase[22];
	t_phase   <= t_phase + t_rate;

	if ((ps2_evt | spin_evt) && (sp_mag != 9'd0)) begin
		// New mouse/spinner movement: queue |delta| steps in its direction.  If the queue still
		// holds steps of the SAME direction, add to them; a direction change replaces the queue
		// (latest intent wins -> instant reversal, no leftover wrong-way steps).
		if (sp_raw[8] == sp_qdir) begin
			sp_frac  <= sp_remn;                                            // keep lossless carry
			sp_queue <= (sp_queue + sp_steps > STEP_CAP) ? STEP_CAP : (sp_queue + sp_steps);
		end else begin
			sp_qdir  <= sp_raw[8];
			sp_frac  <= sp_remn;                                            // fresh carry, new dir
			sp_queue <= ({1'b0, sp_steps} > STEP_CAP) ? STEP_CAP : {1'b0, sp_steps}; // zero-ext
		end
	end else if (sp_queue != 10'd0) begin
		// Drain the queue at one +-1 step per PACE_DIV ticks (velocity = rate).
		if (sp_pace == 16'd0) begin
			sp_pace  <= PACE_DIV;
			sp_queue <= sp_queue - 10'd1;
			t_spin   <= t_spin + (sp_qdir ? -4'sd1 : 4'sd1);   // <-- always +-1: direction-safe
		end else begin
			sp_pace  <= sp_pace - 16'd1;
		end
	end else if (t_phase[22] & ~t_pamsb) begin
		// analog-stick NCO tick (or D-pad fallback) when no mouse/spinner queue is draining
		t_spin <= t_spin + (t_inc ? 4'd1 : -4'd1);
	end
end

// Buttons (CONF_STR J1: Fire,Superzapper,FireDn,FireUp,Start1,Start2,Coin,Pause -> joy[4..11])
// Mouse buttons fold in: ps2_mouse[0]=Left->Fire, ps2_mouse[1]=Right->Superzapper (so a mouse
// is fully playable: move=rotate, LMB=fire, RMB=zap).  OR'd with the gamepad buttons.
wire t_fire   = joy[4] | ps2_mouse[0];
wire t_zap    = joy[5] | ps2_mouse[1];
wire t_start1 = joy[8];
wire t_start2 = joy[9];
wire t_coin   = joy[10];

// IN0 (coins/tilt/service, active low): COIN1 = bit2 (MAME tempest)
wire [7:0] tempest_in0 = ~{2'b00, 3'b000, t_coin, 1'b0, 1'b0};
// IN1_DSW0 -> POKEY1: {111, cabinet(sw2[4]), spinner[3:0]}
wire [7:0] tempest_in1 = {3'b111, sw[2][4], t_spin};
// IN2 -> POKEY2: {1, ~start2, ~start1, fire(active-high), zap(active-high), rating, difficulty[1:0]}
wire [7:0] tempest_in2 = {1'b1, ~t_start2, ~t_start1, t_fire, t_zap, sw[2][2], sw[2][1:0]};

wire mod_starwars = 1'b0;

// ESB mod selector.  The MRA's <rom index="1"><part>1</part></rom>
// drives ioctl_index=1 with data=0x01 when ESB is loaded; mod=0 (the
// default at boot) selects Star Wars.  Sticky after rom_download
// completes so the value survives once the MRA is in.
reg [7:0] mod_byte = 8'h00;
always @(posedge clk_12) begin
	if (ioctl_wr && (ioctl_index == 8'd1)) mod_byte <= ioctl_dout;
end
wire mod_esb = (mod_byte == 8'h01);

// Video signals
wire hblank, vblank;
wire hs, vs;
wire [3:0] r,g,b;

// CE_PIXEL generation on CLK_VIDEO domain (109 MHz)
reg ce_pix;
always @(posedge clk_108) begin
	if (osd_120hz_mode)
		ce_pix <= 1'b1;       // Full 109 MHz → 120Hz
	else
		ce_pix <= ~ce_pix;    // ~54.5 MHz → 60Hz
end

wire reset = (RESET | status[0] |  buttons[1] | rom_download | nvram_download);
wire [15:0] audio_l, audio_r;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_S = 0;   // Tempest POKEY audio is UNSIGNED (pokey.vhd: 0=silence..255=max).
                      // (Was 1/signed from the Star Wars core -> samples >=0x80 folded negative
                      //  -> torn waveform = harsh/thin "half the chip" sound.  Both POKEYs are fine.)
wire vgade;

// (Removed dead Star Wars m_dsw0/m_dsw1 leftovers: they were never read by the Tempest core, and
//  they referenced status bits now reused by Spinner Sensitivity (status[13:11]).  Tempest's real
//  DIPs come from the MRA via sw[0..2] -> tempest_in1/in2 + dsw1/dsw2.)

tempest_sw tempest_core
(
	.clk_12(clk_12),
	.clk_50(clk_50),
	.clk_vid(clk_108),
	.reset(reset),

	.osd_raster_flicker(status[2]),
	.osd_120hz_mode(osd_120hz_mode),
	.osd_rotate(status[6:5]),
	.osd_flip(status[7]),
	.osd_scale(2'd0),              // UNUSED: content scale pinned to FILL (11/16) inside tempest_sw
	.osd_gate_bypass(status[10]),
	.osd_persist(status[29:28]),   // Persistence: 0=3(default ~_n),1=4,2=6,3=2 lists/frame

	// DDRAM Framebuffer Interface (proven SW DDR renderer)
	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),

	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),
	.FB_FORCE_BLANK(FB_FORCE_BLANK),
`ifdef MISTER_FB_PALETTE
	.FB_PAL_CLK(FB_PAL_CLK),
	.FB_PAL_ADDR(FB_PAL_ADDR),
	.FB_PAL_DOUT(FB_PAL_DOUT),
	.FB_PAL_DIN(FB_PAL_DIN),
	.FB_PAL_WR(FB_PAL_WR),
`endif

	.audio_out_l(audio_l),
	.audio_out_r(audio_r),

	.video_r(r),
	.video_g(g),
	.video_b(b),
	.hsync(hs),
	.vsync(vs),
	.vblank(vblank),
	.hblank(hblank),

	// Tempest inputs (POKEY pots + IN0 + DSW1/2)
	.sw_b4(tempest_in2),
	.sw_d4(tempest_in1),
	.in0(tempest_in0),
	.dsw1(sw[0]),
	.dsw2(sw[1]),

	.led(core_led),

	// ROM Download
	.dn_addr(dl_addr),
	.dn_data(ioctl_dout),
	.dn_wr(ioctl_wr & rom_download)
);

// --- NVRAM Save/Load/Clear Logic ---
wire nvram_cs_ioctl = (ioctl_index == 8'd4);
wire nvram_wr_ioctl = nvram_cs_ioctl && ioctl_download && ioctl_wr;

reg [7:0] clear_addr;
reg clearing;
reg old_clear_req;

always @(posedge clk_12) begin
	old_clear_req <= status[3];
	if (status[3] && !old_clear_req) begin
		clearing <= 1;
		clear_addr <= 0;
	end else if (clearing) begin
		if (clear_addr == 255) clearing <= 0;
		clear_addr <= clear_addr + 8'd1;
	end
end

wire        nvram_wr_ext   = nvram_wr_ioctl || clearing;
wire  [7:0] nvram_addr_ext = clearing ? clear_addr : ioctl_addr[7:0];
wire  [7:0] nvram_din_ext  = clearing ? 8'h00 : ioctl_dout;
wire  [7:0] nvram_dout_ext   = 8'h00;  // Tempest: hiscore/NVRAM stubbed (EAROM = 0xFF stub)
wire        nvram_write_pulse = 1'b0;  // -> upload path pushes zeros, never dirty (harmless)

// --- NVRAM Auto-Save & Manual Save  ---
reg nvram_dirty;
reg force_save;


always @(posedge clk_12) begin
	if (reset) begin
		nvram_dirty <= 0;
		force_save <= 0;
	end else begin
		if (ioctl_upload && ioctl_index == 8'd4) begin
			nvram_dirty <= 0;
			force_save <= 0;
		end else if (nvram_write_pulse) begin
			nvram_dirty <= 1;
		end

		// If NVRAM is cleared we force a save.
		if (clearing && clear_addr == 255) begin
			force_save <= 1;
		end
	end
end

assign ioctl_upload_req = (status[27] & nvram_dirty) | status[4] | force_save;
assign ioctl_din = (ioctl_index == 8'd4) ? nvram_dout_ext : 8'h00;

endmodule
