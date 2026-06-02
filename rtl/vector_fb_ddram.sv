// ============================================================================
// Vector Framebuffer — DDRAM Pixel Renderer by Videodr0me 2026:
//
// Vector-to-raster interface convention (X/Y/Z/RGB/BEAM_ON/BEAM_ENA)
// follows the pattern established by Dave Wood's Black Widow renderer.
//
// Renders Atari AVG vector output into a 980×720 8bpp indexed-color
// framebuffer stored in DDRAM, using MISTER_FB for display.
//
//   Vector Generator (12 MHz)         DDRAM Controller (50 MHz)
//   ┌───────────────────┐           ┌─────────────────────────────┐
//   │ AVG + Drawer      │  Async    │  Stage 1: FIFO Pop          │
//   │ X/Y/Z/RGB/BEAM_ON ┼──FIFO───> │  Stage 2: Decode + Address  │
//   │ FRAME_DONE (EOF)  │  (8K×28b) │  Stage 3: DDRAM Write       │
//   └───────────────────┘  CDC      └─────────────────────────────┘
//
// Clock domain crossing:
//   Entries are pushed into an 8K-deep async FIFO using Gray-coded pointers 
//   for safe CDC to the 50 MHz DDRAM domain (clk_sys).
//
// Pixel pipeline (3 stages, clk_sys):
//   Stage 1 — FIFO FETCH: Pop one 28-bit entry.
//   Stage 2 — DECODE/ADDR: If EOF → trigger buffer swap + clear.
//             If pixel → compute DDRAM word address and byte lane:
//             addr = (Y×1024 + X) / 8,  byte_enable = 1 << (addr % 8).
//             Y×1024 = Y<<10 (stride is power of 2, no decomposition needed).
//   Stage 3 — DDRAM WRITE: Issue a single-beat Avalon-MM write with
//             byte enables (no read-modify-write needed).
//
// Triple buffering:
//   980×720 framebuffers (stride 4096) at DDRAM byte offsets 0x30000000,
//   0x302D0000, 0x305A0000 (0x2D0000 each, ~8.8 MB total):
//     display_buf      — being scanned out by the MiSTer scaler
//     draw_buf         — receiving new pixels from the pipeline
//     ready_buf        — completed frame waiting for next VBL swap
//     clear_target_buf — being zeroed after a swap
//   On EOF: draw_buf → ready_buf, free buffer → draw_buf + clear_target_buf.
//   On VBL: ready_buf → display_buf (if valid). Guarantees tear-free output.
//
// OSD_FLICKER mode:
//   When enabled, bypasses triple buffering and uses simple double-buffer.
//   This produces visible (fake) vector flicker, looking best in 120hz.
// ============================================================================

module vector_fb_ddram (
	input         clk_sys,  // Master DDRAM clock (50MHz)
	input         clk_12,   // Vector generator clock
	input         reset,
	
	// Vector inputs
	input  [9:0]  X_VECTOR,
	input  [9:0]  Y_VECTOR,
	input  [4:0]  Z_VECTOR,
	input  [2:0]  RGB,
	input         BEAM_ON,
	input         BEAM_ENA,

	// DDRAM Framebuffer Interface
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

	// MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	// Custom frame sync signals
	input         START_FRAME,
	input         FRAME_DONE,
	input         OSD_FLICKER,
	output        FIFO_FULL_LED
);

	// ------------------------------------------------------------------------
	// MISTER_FB Configuration
	// ------------------------------------------------------------------------
	assign FB_EN     = 1'b1;
	assign FB_FORMAT = 5'b00110; // 32bpp RGBA8888 ([4]=0 RGB; ascal reads byte0=R)
	assign FB_WIDTH  = 980;
	assign FB_HEIGHT = 720;      // 720 (was 700): 720*3=2160 = exact 4K integer scale (700*3=2100 missed it)
	assign FB_STRIDE = 4096;     // 980*4=3920 bytes/line, padded to 2^12 (Y<<12 addressing)
	assign FB_FORCE_BLANK = 1'b0;

	// ------------------------------------------------------------------------
	// DDRAM Clock
	// ------------------------------------------------------------------------
	assign DDRAM_CLK = clk_sys;
	// DDRAM_RD is now driven by the RMW state machine (was tied 0 in the
	// fire-and-forget 8bpp writer). See ddram_rd_reg below.
	reg ddram_rd_reg = 1'b0;
	assign DDRAM_RD = ddram_rd_reg;

	// ------------------------------------------------------------------------
	// Triple Buffers
	// ------------------------------------------------------------------------
	reg [1:0] display_buf;
	reg [1:0] draw_buf;
	reg [1:0] ready_buf;
	reg [1:0] clear_target_buf;

	reg [2:0] vbl_sync;
	wire vbl_edge = vbl_sync[1] && !vbl_sync[2];

	// ===== DISPLAY-PATH DIAGNOSTIC #2 — AVG LIVENESS (temporary; set to 0 to revert) =====
	// Blue test PASSED (ascal scans the FB).  Now: is the Tempest CPU/AVG generating
	// vectors on this chassis?  DIAG_FB_SCANOUT=1 forces FB_BASE to buf1 AND makes buf1
	// STATIC (the EOF handler below skips buffer rotation + re-clear), so vectors
	// accumulate on a black buf1 and stay.  Combined with the present-gate forced bypassed
	// (tempest_sw DIAG_BYPASS), vectors flow continuously.  HW: steady ATTRACT on buf1 =>
	// CPU/AVG run + render works on real HW => the present-gate FSM is the bug.  Pure BLACK
	// => no vectors generated => CPU/AVG/ROM/reset integration issue (chase dbg next).
	localparam        DIAG_FB_SCANOUT = 1'b0;   // 0 = normal (swap-driven FB_BASE, black clear, rotation)
	localparam [63:0] FILL_WORD       = {2{32'h00FF0000}};  // (unused now; kept for the blue test)

	// FB_BASE outputs the ACTIVE buffer for display (byte address),
	// while DDRAM_ADDR is a 64-bit word index (8 bytes per unit).
	// 32bpp buffers are 720*4096 = 0x2D0000 bytes (0x5A000 words) each.
	assign FB_BASE = DIAG_FB_SCANOUT      ? 32'h302D0000 :  // DIAG: force buf1 (reset-cleared)
	                 (display_buf == 2'd2) ? 32'h305A0000 :
	                 (display_buf == 2'd1) ? 32'h302D0000 :
	                                         32'h30000000;

	// Drawing occurs on the INACTIVE buffer
	wire [28:0] draw_base_word = (draw_buf == 2'd2) ? 29'h060B4000 :
	                             (draw_buf == 2'd1) ? 29'h0605A000 :
	                                                  29'h06000000;

	// Clear target buffer immediately after a swap
	wire [28:0] clear_base_word = (clear_target_buf == 2'd2) ? 29'h060B4000 :
	                              (clear_target_buf == 2'd1) ? 29'h0605A000 :
	                                                           29'h06000000;

	// ------------------------------------------------------------------------
	// Palette Initialization
	// ------------------------------------------------------------------------
	reg [7:0] pal_addr = 0;
	reg       pal_wr = 0;

	// 8 primary/secondary colors * 32 intensity levels = 256 Palette entries
	wire [2:0] pal_rgb = pal_addr[7:5];
	wire [4:0] pal_int = pal_addr[4:0];
	wire [7:0] channel_val = {pal_int, pal_int[4:2]};

	assign FB_PAL_DOUT = {
		pal_rgb[2] ? channel_val : 8'h00, // Red
		pal_rgb[1] ? channel_val : 8'h00, // Green
		pal_rgb[0] ? channel_val : 8'h00  // Blue
	};

	assign FB_PAL_CLK  = clk_sys;
	assign FB_PAL_ADDR = pal_addr;
	assign FB_PAL_WR   = pal_wr;
	
	reg pal_init_done = 0;
	always @(posedge clk_sys) begin
		if (reset) begin
			pal_addr <= 0;
			pal_wr <= 0;
			pal_init_done <= 0;
		end else if (!pal_init_done) begin
			pal_wr <= 1'b1;
			if (pal_addr == 8'd255) begin
				pal_init_done <= 1'b1;
				pal_wr <= 1'b0;
			end else begin
				pal_addr <= pal_addr + 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Async FIFO (Vector Gen -> DDRAM Controller)
	// ------------------------------------------------------------------------
	(* ramstyle = "M10K" *) reg [27:0] fifo_mem [0:8191]; 
	reg [13:0] wr_ptr = 0, wr_ptr_g = 0;
	reg [13:0] rd_ptr = 0, rd_ptr_g = 0;
	
	function [13:0] b2g(input [13:0] b);
		b2g = b ^ (b >> 1);
	endfunction
	
	function [13:0] g2b(input [13:0] g);
		reg [13:0] b;
		begin
			b[13] = g[13];
			b[12] = b[13] ^ g[12];
			b[11] = b[12] ^ g[11];
			b[10] = b[11] ^ g[10];
			b[9]  = b[10] ^ g[9];
			b[8]  = b[9]  ^ g[8];
			b[7]  = b[8]  ^ g[7];
			b[6]  = b[7]  ^ g[6];
			b[5]  = b[6]  ^ g[5];
			b[4]  = b[5]  ^ g[4];
			b[3]  = b[4]  ^ g[3];
			b[2]  = b[3]  ^ g[2];
			b[1]  = b[2]  ^ g[1];
			b[0]  = b[1]  ^ g[0];
			g2b = b;
		end
	endfunction

	// --- WRITE SIDE (clk_12) ---
	reg [9:0] last_x, last_y;
	reg       last_beam_on;
	reg       last_frame_done;
	
	// Synchronize read pointer to write domain
	reg [13:0] rd_ptr_g_sync1 = 0, rd_ptr_g_sync2 = 0;
	always @(posedge clk_12) begin
		rd_ptr_g_sync1 <= rd_ptr_g;
		rd_ptr_g_sync2 <= rd_ptr_g_sync1;
	end
	
	wire [13:0] rd_ptr_bin = g2b(rd_ptr_g_sync2);
	wire [13:0] fifo_used = wr_ptr - rd_ptr_bin;
	wire fifo_full_flag = (fifo_used > 14'd8100);

	reg [19:0] led_timer = 0;
	always @(posedge clk_12) begin
		if (fifo_full_flag) led_timer <= 20'hFFFFF;
		else if (led_timer != 0) led_timer <= led_timer - 1'b1;
	end
	assign FIFO_FULL_LED = (led_timer != 0);
	
	// Pre-calculate conditions to ensure a SINGLE RAM assignment
	wire push_eof = (FRAME_DONE && !last_frame_done);
	// Z==0 BLANK: bwidow_dw blanked pixels where Z==0 (beam moves + dim-to-black draws).
	// vector_fb_ddram replaced bwidow_dw and lost that blank.  In overwrite mode (USE_RMW=0)
	// a Z==0 write deposits BLACK and ERASES the geometry it crosses -> dotted lines.  Restore
	// the blank by not pushing invisible (Z==0) points (correct for additive mode too -- a
	// Z==0 pixel adds nothing).  Also cuts FIFO/DDR write traffic.  Sim: +5% retention.
	wire push_pix = (BEAM_ON && (Z_VECTOR != 5'd0) && (X_VECTOR != last_x || Y_VECTOR != last_y || !last_beam_on));
	wire fifo_we  = push_eof || push_pix;
	wire [27:0] fifo_din = push_eof ? 28'hFFFFFFF : {Z_VECTOR, RGB, Y_VECTOR, X_VECTOR};
	
	always @(posedge clk_12) begin
		last_frame_done <= FRAME_DONE;   // EOF edge-detect: must sample every cycle

		if (reset) begin
			wr_ptr <= 0;
			wr_ptr_g <= 0;
			last_beam_on <= 1'b0;
		end else if (fifo_we) begin
			// Single write assignment for Quartus BRAM inference
			fifo_mem[wr_ptr[12:0]] <= fifo_din;
			wr_ptr <= wr_ptr + 1'b1;
			wr_ptr_g <= b2g(wr_ptr + 1'b1);
			// Dedup reference = last COMMITTED (pushed) pixel, NOT last fed point.  If it
			// tracked every fed point, a blanked move (Z==0, not pushed) would advance
			// last_x/last_y and then suppress the draw that starts on that same spot ->
			// the first pixel of every line (move-to-start, draw-from-start) silently
			// dropped.  Updating only on push fixes it and still dedups beam dwell.  Sim: +53 px.
			last_x <= X_VECTOR;
			last_y <= Y_VECTOR;
			last_beam_on <= BEAM_ON;
		end
	end
	// --- READ SIDE (clk_sys, 50MHz) ---
	// Pipeline Stages
	reg        stage2_valid;
	reg [27:0] stage2_data;
	
	reg        stage3_valid;
	reg [28:0] stage3_addr;      // full DDR word address of the target pixel's word
	reg        stage3_slot;      // which 4-byte half of the 64-bit word (byte_offset[2])
	reg [31:0] stage3_pixel;     // RGBA8888 word to write: {8'h00, B, G, R} (byte0=R)

	// Pipeline Data Signals Here
	logic [4:0]  pixel_z;
	logic [2:0]  pixel_c;
	logic [9:0]  pixel_y;
	logic [9:0]  pixel_x;
	logic [22:0] computed_pixel_addr;  // byte offset within buffer: Y*4096 + X*4
	logic [7:0]  chan;                 // 8-bit channel value = {z[4:0], z[4:2]}

	// --- Read-modify-write (RMW) pixel writer ---
	// 32bpp pixels are 4-byte aligned (2 per 64-bit word) -> never straddle a word.
	// Phase 2 merges by OVERWRITE; Phase 3 = saturating-ADD (one-line change here).
	// USE_RMW=0 selects the proven sub-word byte-enable overwrite fallback (no read).
	localparam       USE_RMW   = 1'b0;   // fire-and-forget byte-enable write (no per-pixel
	                                     // read) -- the RMW read stalled + dropped ~75% of
	                                     // pixels under real shared-DDR contention (sim-confirmed)
	localparam [1:0] RMW_IDLE  = 2'd0,
	                 RMW_READ  = 2'd1,
	                 RMW_WRITE = 2'd2;
	reg  [1:0]  rmw_state = RMW_IDLE;
	reg  [63:0] rmw_rdword;
	// --- Phase 3a: additive (saturating-ADD) overlap ---
	// ADD_MODE=1: beams deposit light additively -- crossings sum + color-mix,
	// repeated/over-driven hits brighten and clamp toward white.  =0 = overwrite
	// (Phase-2 parity).  Later this becomes the OSD "Beam overlap" toggle.
	localparam ADD_MODE = 1'b1;

	// per-channel saturating add (8-bit, clamp at 255)
	function automatic [7:0] sat8(input [7:0] a, input [7:0] b);
		logic [8:0] s;
		begin
			s = {1'b0, a} + {1'b0, b};
			sat8 = s[8] ? 8'hFF : s[7:0];
		end
	endfunction

	// old pixel currently in the target 4-byte slot of the read-back word
	wire [31:0] old_pix = stage3_slot ? rmw_rdword[63:32] : rmw_rdword[31:0];
	// saturating-add the new beam contribution onto it, per RGB channel ({00,B,G,R})
	wire [31:0] add_pix = { 8'h00,
	                        sat8(old_pix[23:16], stage3_pixel[23:16]),   // B
	                        sat8(old_pix[15:8],  stage3_pixel[15:8]),    // G
	                        sat8(old_pix[7:0],   stage3_pixel[7:0]) };   // R
	wire [31:0] new_slot = ADD_MODE ? add_pix : stage3_pixel;
	// merge the (additive or overwrite) pixel into the correct slot of the word
	wire [63:0] merged_word = stage3_slot ? {new_slot,         rmw_rdword[31:0]}
	                                      : {rmw_rdword[63:32], new_slot};

	reg [13:0] wr_ptr_g_sync1 = 0, wr_ptr_g_sync2 = 0;
	always @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
	end
	
	wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);

	// stage2_data read pipeline is gated below (see s2_advance, after `clearing` is declared).
	// DDRAM Registers
	reg [63:0] ddram_din_reg;
	reg [28:0] ddram_addr_reg;
	reg [7:0]  ddram_be_reg;
	reg [7:0]  ddram_burst_reg;
	reg        ddram_we_reg;

	assign DDRAM_DIN = ddram_din_reg;
	assign DDRAM_ADDR = ddram_addr_reg;
	assign DDRAM_BE = ddram_be_reg;
	assign DDRAM_BURSTCNT = ddram_burst_reg;
	
	// SAFETY CLAMP — covers 3x 32bpp buffers (word 0x06000000..0x060B4000+0x5A000 = 0x0610DFFF)
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h0610DFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;

	// Clear State
	reg clearing;
	reg [18:0] clear_addr; // 368640 words = 720*4096 bytes = ~2.95MB buffer (368639 fits in 19 bits)

	// stage2_data must update ONLY when the read pipeline actually advances (consumes
	// stage2), so it stays paired with stage2_valid.  The original unconditional
	// `stage2_data <= fifo_mem[rd_ptr]` re-read rd_ptr every cycle; during a stall
	// (DDRAM_BUSY or a pending stage3 write) rd_ptr had already moved on, so stage2_data
	// decoupled from stage2_valid -> the held pixel's data was clobbered (often with the
	// empty-slot X) before decode, and the bounds check then silently dropped it.
	// This is the contention-only pixel loss (sim: 1373/6846 lost at 50% DDR busy).
	// `s2_advance` matches EXACTLY the condition under which the advance branch runs below.
	wire s2_advance = !DDRAM_BUSY && !clearing && (rmw_state == RMW_IDLE) && !stage3_valid;
	always @(posedge clk_sys) begin
		if (s2_advance) stage2_data <= fifo_mem[rd_ptr[12:0]];
	end

	// --- Phase 3b burst-WRITE spike (self-contained, default OFF) ---
	// USE_BURST_CLEAR=1 bursts the buffer-clear: one DDRAM_BURSTCNT=CLEAR_BURST
	// command then CLEAR_BURST zero-word beats, vs single-word writes.  It's the
	// minimal hardware test of burst writes on the emu DDR port (ram1): if the
	// screen still clears with it on, bursts work here (BW's v3.7 scramble was an
	// FSM bug, not a hw wall -> the halation bloom_engine can use bursts).  Left
	// OFF so the default Phase-3 build is the proven single-word clear.
	localparam       USE_BURST_CLEAR = 1'b1;   // burst the clear (16 words/cmd) so it finishes
	                                           // under DDR contention; now verifiable in the FB sim
	localparam [7:0] CLEAR_BURST     = 8'd16;   // 368640/16 = 23040 bursts (exact)
	reg [7:0] clear_beat;                        // beat within the current clear burst

	// --- FULL-buffer clear (was ROW-RANGE for the Half-scale letterbox) ------------------
	// At FILL scale (11/16) the content spans ~rows 9..712 = nearly the whole 720 buffer, so the
	// old row-range optimization (clear only rows 96..623) would leave the top/bottom UNCLEARED ->
	// trails.  No letterbox to exploit anymore -> clear the FULL buffer every frame.  This fits the
	// present_gate 10 ms beam-off window at realistic (<=25%) DDR contention (~7.4-9.8 ms); any
	// overrun under heavier load is masked by the persistence accumulation (N>=3 refills early-beam
	// drops) -- the same mechanism the shipped core already relies on.  The ROW constants are set
	// EQUAL to the FULL constants so the clr_full=0 path is identical (FSM logic untouched).
	reg [2:0] clear_cnt = 3'd0;
	localparam [18:0] CLR_ROW_LO         = 19'd0;        // FILL: full buffer (was row 96 = 49152)
	localparam [18:0] CLR_BURST_END_FULL = 19'd368624;   // 368640-16
	localparam [18:0] CLR_BURST_END_ROW  = 19'd368624;   // == FULL (no row-range at fill scale)
	localparam [18:0] CLR_SINGLE_END_FULL= 19'd368639;
	localparam [18:0] CLR_SINGLE_END_ROW = 19'd368639;   // == FULL
`ifdef SIM_ROWCLEAR
	localparam [2:0] CLR_FULL_N = 3'd1;   // sim: only the reset clear is full -> exercise row-range fast
`else
	localparam [2:0] CLR_FULL_N = 3'd4;   // boot: first 4 clears full (all 3 buffers' unused rows zeroed)
`endif
	wire        clr_full      = (clear_cnt < CLR_FULL_N);
	wire [18:0] clr_start     = clr_full ? 19'd0 : CLR_ROW_LO;
	wire [18:0] clr_burst_end = clr_full ? CLR_BURST_END_FULL  : CLR_BURST_END_ROW;
	wire [18:0] clr_single_end= clr_full ? CLR_SINGLE_END_FULL : CLR_SINGLE_END_ROW;
	reg       clear_setup;                       // 1=SETUP (latch addr, we=0); 0=DATA (stream)

	always @(posedge clk_sys) begin
		vbl_sync <= {vbl_sync[1:0], FB_VBL};

		if (!DDRAM_BUSY) begin
			ddram_we_reg <= 1'b0;
			ddram_rd_reg <= 1'b0;
		end

		if (reset) begin
			display_buf <= 2'd0;
			draw_buf <= 2'd1;
			ready_buf <= 2'd3;
			clear_target_buf <= 2'd1;
			
			clearing <= 1'b1;
			clear_addr <= 0;
			
			rd_ptr <= 0;
			rd_ptr_g <= 0;
			stage2_valid <= 1'b0;
			stage3_valid <= 1'b0;
			ddram_we_reg <= 0;
			ddram_rd_reg <= 0;
			rmw_state <= RMW_IDLE;
			clear_beat <= 0;
			clear_setup <= 1'b1;
			clear_cnt <= 3'd0;       // boot: force the first clears full (clear_addr<=0 above)
		end else begin
		
			// -------------------------------------------------------------
			// VBLANK (Output Side)
			// -------------------------------------------------------------
			if (OSD_FLICKER) begin
				// Unbuffered On
				if (vbl_edge) begin
					display_buf <= draw_buf;
					draw_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clear_target_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clearing <= 1'b1;
					clear_addr <= clr_start;
				end
			end else begin
				// Unbuffered Off: TRIPLE BUFFER
				if (vbl_edge && ready_buf != 2'd3) begin
					display_buf <= ready_buf;
					ready_buf <= 2'd3; // Invalidate
				end
			end

			// -------------------------------------------------------------
			// CLEARING LOGIC
			// -------------------------------------------------------------
			if (DDRAM_BUSY) begin
				// Wait
			end else if (clearing) begin
				// CLEAR the new draw buffer (zeros) before accepting pixels.
				ddram_din_reg <= 64'd0;  // black (ascal scanout already confirmed via blue test)
				ddram_be_reg  <= 8'hFF;
				
				if (USE_BURST_CLEAR) begin
					// 2-state burst writer modelled on ascal's sIDLE/sWRITE master.
					ddram_burst_reg <= CLEAR_BURST;
					if (clear_setup) begin
						// SETUP: latch addr + burstcount one cycle BEFORE asserting we,
						// so the burst command carries a stable address (kills the
						// registered-output address skew). we stays 0 this cycle.
						ddram_addr_reg <= clear_base_word + clear_addr;
						ddram_we_reg   <= 1'b0;
						clear_beat     <= 8'd0;
						clear_setup    <= 1'b0;
					end else begin
						// DATA: stream CLEAR_BURST zero words.  Advance the beat ONLY on a
						// CONFIRMED transfer -- this is the !DDRAM_BUSY branch, so
						// ddram_we_reg=1 means the beat presented last cycle was accepted
						// (== ascal avl_rad_c: write && !waitrequest).  Counting cycles
						// instead was the v1 bug that hung the burst -> black.
						ddram_we_reg <= 1'b1;
						if (ddram_we_reg) begin
							if (clear_beat == CLEAR_BURST - 8'd1) begin
								ddram_we_reg <= 1'b0;       // 16th beat done -> end burst
								clear_setup  <= 1'b1;        // next burst re-enters SETUP
								if (clear_addr == clr_burst_end) begin
									clearing <= 1'b0;
									if (clear_cnt < 3'd7) clear_cnt <= clear_cnt + 3'd1;  // past boot -> row-range
								end else clear_addr <= clear_addr + CLEAR_BURST;
							end else begin
								clear_beat <= clear_beat + 8'd1;
							end
						end
					end
				end else begin
					ddram_burst_reg <= 8'd1;
					ddram_addr_reg  <= clear_base_word + clear_addr;
					ddram_we_reg    <= 1'b1;
					if (clear_addr == clr_single_end) begin
						clearing <= 1'b0;
						if (clear_cnt < 3'd7) clear_cnt <= clear_cnt + 3'd1;
					end else clear_addr <= clear_addr + 1'b1;
				end

				// FLUSH pipeline stages from the previous frame.
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				rmw_state    <= RMW_IDLE;

			end else begin
				// --- RMW pixel writer + FIFO pipeline (replaces fire-and-forget) ---
				// 32bpp pixels are 4 bytes in one 64-bit word (slot 0 or 1).  The FSM
				// owns DDR; the pipeline advances only while IDLE so a pending pixel is
				// never overwritten mid-RMW.  Phase 3 changes the WRITE merge to sat-ADD.
				case (rmw_state)
				RMW_IDLE: if (stage3_valid) begin
					if (USE_RMW) begin
						ddram_addr_reg  <= stage3_addr;      // issue read of target word
						ddram_be_reg    <= 8'hFF;
						ddram_burst_reg <= 8'd1;
						ddram_rd_reg    <= 1'b1;
						rmw_state       <= RMW_READ;
					end else begin
						ddram_addr_reg  <= stage3_addr;      // FALLBACK: BE overwrite (no read)
						ddram_din_reg   <= {2{stage3_pixel}};
						ddram_be_reg    <= stage3_slot ? 8'hF0 : 8'h0F;
						ddram_burst_reg <= 8'd1;
						ddram_we_reg    <= 1'b1;
						stage3_valid    <= 1'b0;
					end
				end else begin

				// --- STAGE 2: DECODE TOKEN OR CALCULATE ADDRESS ---
				stage3_valid <= 1'b0;
				if (stage2_valid) begin
					if (stage2_data == 28'hFFFFFFF) begin
						// RECEIVED EOF TOKEN!
						// DIAG_FB_SCANOUT: skip rotation+reclear so buf1 stays static (vectors accumulate).
						if (!OSD_FLICKER && !DIAG_FB_SCANOUT) begin
							logic [1:0] next_free_buf;

							// 1. Stash the pointer of the buffer we just finished drawing
							ready_buf <= draw_buf;

							// 2. Find the 3rd unused buffer.
							// We cannot use the currently displayed buffer (display_buf)
							// We cannot use the buffer we JUST finished (draw_buf, which is becoming ready_buf)
							if      (display_buf != 2'd0 && draw_buf != 2'd0) next_free_buf = 2'd0;
							else if (display_buf != 2'd1 && draw_buf != 2'd1) next_free_buf = 2'd1;
							else                                              next_free_buf = 2'd2;

							// 3. Assign BOTH registers to the newly calculated free buffer
							draw_buf         <= next_free_buf;
							clear_target_buf <= next_free_buf;

							// 4. Trigger clear (row-range once past boot; see clr_start)
							clearing   <= 1'b1;
							clear_addr <= clr_start;
						end
					end  else begin
						// Normal Pixel Assignments
						// stage2_data: {Z[4:0], RGB[2:0], Y[9:0], X[9:0]}
						pixel_z = stage2_data[27:23];
						pixel_c = stage2_data[22:20];
						pixel_y = stage2_data[19:10];
						pixel_x = stage2_data[9:0];
						
						// Safety bounds check (defense-in-depth)
						if (pixel_x < 10'd980 && pixel_y < 10'd720) begin
							// byte offset within buffer = Y*4096 + X*4 (stride 4096 = 2^12)
							computed_pixel_addr = {pixel_y, 12'd0} + {pixel_x, 2'd0};
							chan = {pixel_z, pixel_z[4:2]};  // == old palette channel_val
							
							stage3_addr  <= draw_base_word + computed_pixel_addr[22:3];
							stage3_slot  <= computed_pixel_addr[2];
							stage3_pixel <= {8'h00,
							                 pixel_c[0] ? chan : 8'h00,   // B (23:16)
							                 pixel_c[1] ? chan : 8'h00,   // G (15:8)
							                 pixel_c[2] ? chan : 8'h00};  // R (7:0)
							stage3_valid <= 1'b1;
						end
					end
				end

				// --- STAGE 1: FETCH FROM FIFO ---
				stage2_valid <= !fifo_empty;
				
				if (!fifo_empty) begin
					rd_ptr <= rd_ptr + 1'b1;
					rd_ptr_g <= b2g(rd_ptr + 1'b1);
				end
				end // RMW_IDLE: pipeline-advance else

				// ---- READ: capture the target word, then write ----
				RMW_READ: begin
					ddram_rd_reg <= 1'b0;
					if (DDRAM_DOUT_READY) begin
						rmw_rdword <= DDRAM_DOUT;
						rmw_state  <= RMW_WRITE;
					end
				end

				// ---- WRITE: merged full word (overwrite slot; Phase 3 = sat-ADD) ----
				RMW_WRITE: begin
					ddram_addr_reg  <= stage3_addr;
					ddram_din_reg   <= merged_word;
					ddram_be_reg    <= 8'hFF;
					ddram_burst_reg <= 8'd1;
					ddram_we_reg    <= 1'b1;
					stage3_valid    <= 1'b0;
					rmw_state       <= RMW_IDLE;
				end
				endcase
			end
		end
	end

endmodule