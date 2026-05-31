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
// FB is 980×700. Integer scales: ×1=980×700, ×1.5=1470×1050, ×2=1960×1400, ×3=2940×2100
reg [12:0] auto_arx, auto_ary;
always @(*) begin
	if (HDMI_HEIGHT >= 2100) begin
		// 4K (3840×2160): ×3 integer scale (4K not supported yet ;-)
		auto_arx = 13'h1B7C;  // 0x1000 | 2940
		auto_ary = 13'h1834;  // 0x1000 | 2100
	end else if (HDMI_HEIGHT >= 1400) begin
		// 1440p (2560×1440): ×2 integer scale
		auto_arx = 13'h17A8;  // 0x1000 | 1960
		auto_ary = 13'h1578;  // 0x1000 | 1400
	end else if (HDMI_HEIGHT >= 1050) begin
		// 1080p (1920×1080): ×1.5 scale (3:2)
		auto_arx = 13'h15BE;  // 0x1000 | 1470
		auto_ary = 13'h141A;  // 0x1000 | 1050
	end else begin
		// 720p (1280×720) or smaller: 1:1 pixel perfect
		auto_arx = 13'h13D4;  // 0x1000 | 980
		auto_ary = 13'h12BC;  // 0x1000 | 700
	end
end

// Aspect menu = {0:Optimized, 1:Pixel Perfect} (Stretched removed).  ar==0 ->
// auto-detected integer scale; else (ar==1) -> 1:1 pixel-perfect.  Both modes
// HW-tested good; the dropped Stretched arm (was ar==1) is simply gone.
assign VIDEO_ARX = (ar == 0) ? auto_arx :  // Optimized (auto-detect)
                               13'h13D4;   // Pixel Perfect (1:1, 980)

assign VIDEO_ARY = (ar == 0) ? auto_ary :  // Optimized (auto-detect)
                               13'h12BC;   // Pixel Perfect (1:1, 700)

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
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Fire,Superzapper,Fire Down,Fire Up,Start 1P,Start 2P,Coin,Pause;",
	"jn,A,B,X,Y,Start,Select,R,L;",
	"V,v1.10.",`BUILD_DATE
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
	.joystick_l_analog_0(joy_l_analog_0)
);

// DIP switch loading — currently unused (game settings via Test Mode / NVRAM)
// reg [7:0] sw[8];
// always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// ===== Tempest inputs =====
// MRA DIP switches (ioctl_index=254): sw[0]=DSW1, sw[1]=DSW2,
// sw[2]=difficulty(1:0)/rating(2)/cabinet(4)  (read via the POKEY pots).
reg [7:0] sw[8];
always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

// Analog spinner -> 4-bit knob counter via a rate-proportional NCO (full throw = max
// spin, feather = fine; ~10% deadzone).  D-pad L/R is the fixed-rate fallback.
wire signed [7:0] t_ax       = $signed(joy_l_analog_0[7:0]);
wire        [7:0] t_amag_raw = t_ax[7] ? (~joy_l_analog_0[7:0] + 8'd1) : joy_l_analog_0[7:0];
wire        [7:0] t_amag     = (t_amag_raw > 8'd12) ? t_amag_raw : 8'd0;
wire        [7:0] t_rate     = (t_amag != 8'd0) ? t_amag : ((joy[1]|joy[0]) ? 8'd56 : 8'd0);
wire              t_inc      = (t_amag != 8'd0) ? ~t_ax[7] : joy[0];
reg  [3:0]  t_spin = 4'd0;
reg  [22:0] t_phase = 23'd0;
reg         t_pamsb = 1'b0;
always @(posedge clk_12) begin
	t_phase  <= t_phase + t_rate;
	t_pamsb  <= t_phase[22];
	if (t_phase[22] & ~t_pamsb) t_spin <= t_spin + (t_inc ? 4'd1 : -4'd1);
end

// Buttons (CONF_STR J1: Fire,Superzapper,FireDn,FireUp,Start1,Start2,Coin,Pause -> joy[4..11])
wire t_fire   = joy[4];
wire t_zap    = joy[5];
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

wire [7:0] m_dsw0 = {
	~status[16],       // [7] Freeze (OG, 0=Off, 1=On -> ~0 = 1 = Off)
	status[13],        // [6] Demo Sounds (OD, 0=On, 1=Off)
	status[12:11],     // [5:4] Bonus Shields (OBC)
	status[10:9] + 2'd1,   // [3:2] Difficulty (O9A, rotated +1: 0=Mod,1=Hard,2=Hrd+,3=Easy)
	status[8:7]        // [1:0] Starting Shields (O78)
};

wire [7:0] m_dsw1 = {
	status[24:22],     // [7:5] Bonus Coin Adder (OMNO)
	status[21],        // [4] Left Coin (OL)
	status[20:19],     // [3:2] Right Coin (OJK)
	status[18:17] + 2'd2   // [1:0] Coinage (OHI, rotated +2: 0=1P/C,1=2C/P,2=Free,3=2P/C)
};

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
	.osd_scale(2'd0),              // Vector Scale fixed at Half (OSD option removed)
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
