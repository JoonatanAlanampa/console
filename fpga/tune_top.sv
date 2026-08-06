`default_nettype none
//
// tune_top.sv - ULX3S 85F bench toy: press a button, hear it.
//
// Plays Beethoven's "Ode to Joy" (public domain) out of the ULX3S ONBOARD
// 3.5 mm jack. That jack is a 4-bit R2R ladder per channel driven straight
// from FPGA pins, so this needs NO Pmod and NO header - it is the one audio
// path that works on a board with bare J1/J2.
//
//   F1    (btn[1])  hold -> the melody, looping
//   F2    (btn[2])  hold -> steady 440 Hz A4, a clean reference tone
//   UP    (btn[3])  -> C5      DOWN (btn[4]) -> C4
//   LEFT  (btn[5])  -> E4      RIGHT(btn[6]) -> G4
//
//   DIP sw[1:0] = VOLUME.  00 (both OFF) = full, as before.
//                          01 = half, 10 = quarter, 11 = mute.
//
//   led[0]    heartbeat ~0.75 Hz  - the design is alive
//   led[6:1]  the six buttons     - proves input works even in silence
//   led[7]    a note is sounding  - proves audio is being generated
//
// Every pin site is copied from console/fpga/ulx3s.lpf, which was diffed
// against upstream ulx3s_v20.lpf. None of them are in the set that moved on
// PCB v3.1.x (only five wifi_* pins did), so they are correct on a v3.1.8.
//
module tune_top (
    input  wire        clk_25mhz,
    input  wire  [6:0] btn,
    input  wire  [3:0] sw,
    output wire  [7:0] led,
    output wire  [3:0] audio_l,
    output wire  [3:0] audio_r
);

  // ---------------------------------------------------------------- reset
  // BTN0 (PWR) is active low and pulled up. Same shape as console's harness:
  // hold reset until a power-on counter saturates, and while PWR is pressed.
  reg [15:0] por = 16'd0;
  always @(posedge clk_25mhz) if (!(&por)) por <= por + 16'd1;
  wire rst = !(btn[0] && (&por));

  // ------------------------------------------------------------ note table
  // Phase accumulator is 32 bits, so  f = INC * 25e6 / 2^32,
  // i.e. INC = f * 171.7987.  Values rounded; worst error here is < 0.01 %.
  localparam [31:0] INC_C4 = 32'd44947;   // 261.6 Hz
  localparam [31:0] INC_D4 = 32'd50450;   // 293.7 Hz
  localparam [31:0] INC_E4 = 32'd56629;   // 329.6 Hz
  localparam [31:0] INC_F4 = 32'd59996;   // 349.2 Hz
  localparam [31:0] INC_G4 = 32'd67345;   // 392.0 Hz
  localparam [31:0] INC_A4 = 32'd75591;   // 440.0 Hz
  localparam [31:0] INC_C5 = 32'd89893;   // 523.3 Hz

  localparam [2:0] N_R = 3'd0, N_C = 3'd1, N_D = 3'd2,
                   N_E = 3'd3, N_F = 3'd4, N_G = 3'd5;

  // ------------------------------------------------------------- sequencer
  // One eighth note = 200 ms = 5,000,000 clocks at 25 MHz (=> 150 BPM).
  localparam [22:0] EIGHTH = 23'd5_000_000;

  wire melody_on = btn[1];

  reg  [3:0]  step;     // which note of the phrase
  reg  [2:0]  beats;    // eighths elapsed inside the current note
  reg  [22:0] tick;

  // "Ode to Joy", first phrase. Durations are in eighth notes:
  // quarter = 2, dotted quarter = 3, eighth = 1, half = 4.
  reg [2:0] mel_note, mel_dur;
  always @* begin
    case (step)
      4'd0 : begin mel_note = N_E; mel_dur = 3'd2; end
      4'd1 : begin mel_note = N_E; mel_dur = 3'd2; end
      4'd2 : begin mel_note = N_F; mel_dur = 3'd2; end
      4'd3 : begin mel_note = N_G; mel_dur = 3'd2; end
      4'd4 : begin mel_note = N_G; mel_dur = 3'd2; end
      4'd5 : begin mel_note = N_F; mel_dur = 3'd2; end
      4'd6 : begin mel_note = N_E; mel_dur = 3'd2; end
      4'd7 : begin mel_note = N_D; mel_dur = 3'd2; end
      4'd8 : begin mel_note = N_C; mel_dur = 3'd2; end
      4'd9 : begin mel_note = N_C; mel_dur = 3'd2; end
      4'd10: begin mel_note = N_D; mel_dur = 3'd2; end
      4'd11: begin mel_note = N_E; mel_dur = 3'd2; end
      4'd12: begin mel_note = N_E; mel_dur = 3'd3; end  // dotted quarter
      4'd13: begin mel_note = N_D; mel_dur = 3'd1; end  // eighth
      4'd14: begin mel_note = N_D; mel_dur = 3'd4; end  // half
      default: begin mel_note = N_R; mel_dur = 3'd2; end // rest before repeat
    endcase
  end

  always @(posedge clk_25mhz) begin
    if (rst || !melody_on) begin
      tick <= 23'd0; beats <= 3'd0; step <= 4'd0;
    end else if (tick == EIGHTH - 23'd1) begin
      tick <= 23'd0;
      if (beats == mel_dur - 3'd1) begin
        beats <= 3'd0;
        step  <= step + 4'd1;          // 4 bits: wraps 15 -> 0 by itself
      end else begin
        beats <= beats + 3'd1;
      end
    end else begin
      tick <= tick + 23'd1;
    end
  end

  // ------------------------------------------------- which pitch, if any
  reg [31:0] inc;
  always @* begin
    if (melody_on) begin
      case (mel_note)
        N_C:     inc = INC_C4;
        N_D:     inc = INC_D4;
        N_E:     inc = INC_E4;
        N_F:     inc = INC_F4;
        N_G:     inc = INC_G4;
        default: inc = 32'd0;          // rest
      endcase
    end
    else if (btn[2]) inc = INC_A4;     // reference tone
    else if (btn[3]) inc = INC_C5;
    else if (btn[4]) inc = INC_C4;
    else if (btn[5]) inc = INC_E4;
    else if (btn[6]) inc = INC_G4;
    else             inc = 32'd0;      // silence
  end

  // -------------------------------------------------- oscillator + output
  reg [31:0] phase;
  always @(posedge clk_25mhz) begin
    // Parking phase at 0 while silent matters: the sine is stored as a SIGNED
    // offset and entry 0 is zero, so idle sits exactly at mid-scale and there
    // is no DC step (click) when a note starts or ends - at any volume.
    if (rst || inc == 32'd0) phase <= 32'd0;
    else                     phase <= phase + inc;
  end

  // 32-entry sine held as a signed offset about mid-scale: round(7*sin).
  // Symmetric -7..+7, so attenuating by a shift stays centred and cannot clip.
  reg signed [4:0] osc;
  always @* begin
    case (phase[31:27])
      5'd0 : osc =  5'sd0;   5'd1 : osc =  5'sd1;
      5'd2 : osc =  5'sd3;   5'd3 : osc =  5'sd4;
      5'd4 : osc =  5'sd5;   5'd5 : osc =  5'sd6;
      5'd6 : osc =  5'sd6;   5'd7 : osc =  5'sd7;
      5'd8 : osc =  5'sd7;   5'd9 : osc =  5'sd7;
      5'd10: osc =  5'sd6;   5'd11: osc =  5'sd6;
      5'd12: osc =  5'sd5;   5'd13: osc =  5'sd4;
      5'd14: osc =  5'sd3;   5'd15: osc =  5'sd1;
      5'd16: osc =  5'sd0;   5'd17: osc = -5'sd1;
      5'd18: osc = -5'sd3;   5'd19: osc = -5'sd4;
      5'd20: osc = -5'sd5;   5'd21: osc = -5'sd6;
      5'd22: osc = -5'sd6;   5'd23: osc = -5'sd7;
      5'd24: osc = -5'sd7;   5'd25: osc = -5'sd7;
      5'd26: osc = -5'sd6;   5'd27: osc = -5'sd6;
      5'd28: osc = -5'sd5;   5'd29: osc = -5'sd4;
      5'd30: osc = -5'sd3;   default: osc = -5'sd1;
    endcase
  end

  // Volume on the DIP switch. 00 = full, so the default (all switches OFF)
  // is exactly the behaviour before this control existed.
  // NOTE this is genuinely coarse: the DAC is 4 bits, so >>1 leaves ~3 bits
  // and >>2 leaves ~2 bits (levels 7/8/9 only). Use the speaker knob for fine
  // control; this is for when the knob is already at its minimum.
  reg signed [4:0] scaled;
  always @* begin
    case (sw[1:0])
      2'b00:   scaled = osc;            // full
      2'b01:   scaled = osc >>> 1;      // half
      2'b10:   scaled = osc >>> 2;      // quarter
      default: scaled = 5'sd0;          // mute
    endcase
  end

  wire signed [5:0] sum = 6'sd8 + {{1{scaled[4]}}, scaled};
  wire [3:0] sample = sum[3:0];         // 1..15, centred on 8

  assign audio_l = sample;
  assign audio_r = sample;              // mono: same signal both channels

  // ------------------------------------------------------------------ LEDs
  reg [24:0] hb;
  always @(posedge clk_25mhz) hb <= hb + 25'd1;

  assign led = { (inc != 32'd0), btn[6:1], hb[24] };

endmodule
`default_nettype wire
