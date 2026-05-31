// ============================================================================
// tb_gate2.sv -- verify the REAL present_gate.sv (phosphor-persistence gate).
//
// Models the AVG as a continuous list generator: a list of LIST_PER cycles, with
// vggo_rise (list start) at the wrap and "drawing" high for the first DRAW cycles.
//
// What the gate must do now (accumulate N complete lists per displayed buffer):
//   - Between consecutive EOFs it holds beam_window high across exactly N complete
//     lists (N = nlists(persist)), then pulses eof.
//   - The Nth (last) list is COMPLETE: eof coincides with a real vggo (list
//     boundary), NEVER a mid-list timeout -> no tail-drop -> firing-safe.
//   - frame_start pulses once per accumulation; exactly one eof per accumulation.
//
// METRIC per accumulation = vggo_rise events seen while beam_window high.  That
// counts complete lists accumulated; must equal N for the selected persist.
//
// Scenarios: persist 0/1/2/3 -> N 3/4/6/2 (NORMAL + FIRING list lengths), plus a
// DEAD case (vggo never fires -> degrade: eof still pulses, never hangs).
// (ModelSim ASE rejects SV `string` as a task arg -> use ints.)
// ============================================================================
`timescale 1ns/1ps
module tb_gate2;
	logic clk = 0; always #5 clk = ~clk;

	localparam int LIST_N = 480;   // normal list period (~4ms-equiv @ /100 scale)
	localparam int DRAW_N = 360;   // normal draw cycles
	localparam int LIST_F = 900;   // firing list period (grown tail)
	localparam int DRAW_F = 780;   // firing draw cycles

	int  list_per = LIST_N;
	int  draw_cyc = DRAW_N;
	bit  vggo_en  = 1'b1;
	bit  rst_stim = 1'b1;
	bit  reset    = 1'b1;
	logic [1:0] persist = 2'd0;

	// AVG list generator
	int lc = 0;
	always @(posedge clk) begin
		if (rst_stim) lc <= 0;
		else          lc <= (lc >= list_per-1) ? 0 : lc + 1;
	end
	wire drawing   = (lc < draw_cyc);
	wire vggo_rise = vggo_en & (lc == 0);

	// DUT: real present_gate, timeouts scaled /100 so the TB is fast.
	wire beam_window, eof, frame_start;
	present_gate #(
		.BLANK_CYC     (20'd200),    // ~10ms-equiv beam-off (clear)
		.ARMED_TIMEOUT (20'd1440),   // ~12ms-equiv (> firing list 900)
		.CAP_TIMEOUT   (22'd7200)    // ~60ms-equiv (> N=6 firing lists)
	) dut (
		.clk(clk), .reset(reset),
		.vggo_rise(vggo_rise), .persist(persist),
		.beam_window(beam_window), .eof(eof), .frame_start(frame_start)
	);

	// measurement
	// eof is REGISTERED in present_gate, so it is observed one clk AFTER the vggo_rise
	// that triggers it.  Track vggo_rise delayed 1 cycle so "did eof land on a list
	// boundary?" is checked correctly (vggo_rise_d is high the cycle eof is seen when
	// the close was vggo-driven; both low => a real mid-list timeout = tail cut).
	reg vggo_rise_d = 1'b0;
	always @(posedge clk) vggo_rise_d <= vggo_rise;

	int vggo_in_cap = 0;      // vggo seen while beam on, current accumulation
	int lists_at_eof = 0;     // snapshot at eof
	int neof = 0, nstart = 0;
	bit eof_on_vggo = 1'b1;   // was every eof coincident (within 1 clk) with a vggo?
	always @(posedge clk) if (!reset) begin
		if (frame_start) nstart <= nstart + 1;
		if (beam_window && vggo_rise) vggo_in_cap <= vggo_in_cap + 1;
		if (eof) begin
			lists_at_eof <= vggo_in_cap;     // # complete lists accumulated
			vggo_in_cap  <= 0;
			neof <= neof + 1;
			if (vggo_en && !(vggo_rise || vggo_rise_d)) eof_on_vggo <= 1'b0; // mid-list = tail cut
		end
	end

	int fails = 0;

	task automatic run(input int scn, input logic [1:0] p, input int lp, input int dc,
	                   input bit ve, input int expectN, input bit expect_complete);
		int got;
		begin
			@(posedge clk); reset <= 1; rst_stim <= 1;
			persist <= p; list_per <= lp; draw_cyc <= dc; vggo_en <= ve;
			repeat (8) @(posedge clk);
			eof_on_vggo = 1'b1;     // reset the "complete" tracker for this scenario
			reset <= 0; rst_stim <= 0;
			repeat (40000) @(posedge clk);     // many accumulations
			got = lists_at_eof;
			$display("[scn %0d] persist=%0d list=%0d draw=%0d  eof=%0d start=%0d  lists/eof=%0d (want %0d)  lastListComplete=%0b",
			         scn, p, lp, dc, neof, nstart, got, expectN, eof_on_vggo);
			if (ve) begin
				if (got == expectN && eof_on_vggo == expect_complete && neof >= 3)
					$display("         PASS");
				else begin
					$display("         FAIL%s%s%s",
					         (got!=expectN)?" [wrong list count]":"",
					         (eof_on_vggo!=expect_complete)?" [last list NOT complete = tail-drop]":"",
					         (neof<3)?" [too few eofs]":"");
					fails = fails + 1;
				end
			end else begin // DEAD: vggo never fires -> degrade, eof must still pulse
				if (neof >= 2) $display("         PASS: degrade (eof still pulses, never black)");
				else begin $display("         FAIL: degrade broken (neof=%0d)", neof); fails = fails + 1; end
			end
		end
	endtask

	initial begin
		$display("persist->N: 0->3(default) 1->4 2->6 3->2");
		// NORMAL list length, each persistence setting
		run(1, 2'd0, LIST_N, DRAW_N, 1'b1, 3, 1'b1);
		run(2, 2'd1, LIST_N, DRAW_N, 1'b1, 4, 1'b1);
		run(3, 2'd2, LIST_N, DRAW_N, 1'b1, 6, 1'b1);
		run(4, 2'd3, LIST_N, DRAW_N, 1'b1, 2, 1'b1);
		// FIRING (grown list): default persistence must STILL accumulate N COMPLETE
		// lists with the last one complete -> the projectile tail is never cut.
		run(5, 2'd0, LIST_F, DRAW_F, 1'b1, 3, 1'b1);
		// DEAD vggo -> degrade
		run(6, 2'd0, LIST_N, DRAW_N, 1'b0, 0, 1'b1);
		$display("=====================================================");
		if (fails == 0) $display("ALL GATE TESTS PASSED");
		else            $display("GATE TESTS FAILED: %0d", fails);
		$display("=====================================================");
		$finish;
	end
endmodule
