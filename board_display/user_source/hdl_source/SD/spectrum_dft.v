`timescale 1ns/1ps
// Sixteen selected coefficients of a real 512-point DFT. One registered
// multiplier is reused over samples, real/imaginary terms, and power. The
// input is 24-bit signed PCM; with today's WAV source only its top eight bits
// carry information. A future native 24-bit source needs no DFT port change.
module spectrum_dft #(
    parameter COEFF_FILE = "spectrum_twiddle_512.mem"
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              aud_tick,       // one 100 MHz cycle at each 48 kHz output sample
    input  wire              aud_valid,
    input  wire signed [23:0] pcm,
    input  wire [1:0]        sens_gray,
    input  wire              ack_toggle,     // video side copied the completed level bus
    output reg  [127:0]      levels,         // 16 x 8-bit bar heights, 0..120
    output reg               done_toggle
);
    localparam [3:0] S_IDLE      = 4'd0,
                     S_READ      = 4'd1,
                     S_MUL_RE    = 4'd2,
                     S_ACC_RE    = 4'd3,
                     S_ACC_IM    = 4'd4,
                     S_SCALE     = 4'd5,
                     S_POWER_RE  = 4'd6,
                     S_POWER_IM  = 4'd7,
                     S_ENERGY    = 4'd8,
                     S_LEVEL     = 4'd9;

    // The sample windows live in a separate reset-free module so TD can
    // recognize the same synchronous BRAM pattern as transition_line_buf.
    // 0..511: cos; 512..1023: sin. Two synchronous reads on consecutive
    // cycles keep this ROM at a supported 16-bit width and one read port.
    reg [15:0] coeff_mem [0:1023]; /* fehdl force_ram=1, ram_style="bram_32k" */
    initial $readmemh(COEFF_FILE, coeff_mem);

    reg capture_phase, capture_bank, ready_bank, ready_valid;
    reg [8:0] capture_index;
    reg [3:0] state, bin_index;
    reg process_bank;
    reg [8:0] sample_index, phase;
    wire capture_sample = aud_tick && !capture_phase;
    wire signed [23:0] sample_q;
    spectrum_sample_buf u_sample_buf (
        .clk (clk), .wr_en (capture_sample),
        .wr_addr ({capture_bank, capture_index}),
        .wr_data (aud_valid ? pcm : 24'sd0),
        .rd_addr ({process_bank, sample_index}),
        .rd_data (sample_q)
    );

    reg signed [15:0] coeff_q;
    always @(posedge clk)
        if (state == S_READ) begin
            coeff_q <= coeff_mem[{1'b0, phase}];
        end
        else if (state == S_MUL_RE)
            coeff_q <= coeff_mem[{1'b1, phase}];

    function [8:0] bin_number;
        input [3:0] index;
        begin
            case (index)
                4'd0:  bin_number = 9'd1;    // 46.9 Hz at 24 kHz sample rate
                4'd1:  bin_number = 9'd2;
                4'd2:  bin_number = 9'd3;
                4'd3:  bin_number = 9'd4;
                4'd4:  bin_number = 9'd6;
                4'd5:  bin_number = 9'd8;
                4'd6:  bin_number = 9'd11;
                4'd7:  bin_number = 9'd15;
                4'd8:  bin_number = 9'd21;
                4'd9:  bin_number = 9'd29;
                4'd10: bin_number = 9'd40;
                4'd11: bin_number = 9'd56;
                4'd12: bin_number = 9'd78;
                4'd13: bin_number = 9'd108;
                4'd14: bin_number = 9'd150;
                default: bin_number = 9'd210; // 9.84 kHz
            endcase
        end
    endfunction
    wire [8:0] current_bin = bin_number(bin_index);

    reg signed [39:0] product_q;
    reg signed [49:0] sum_re, sum_im;
    reg signed [15:0] scaled_re, scaled_im;
    reg [31:0] power_re, power_im;
    reg [32:0] energy;
    wire signed [23:0] multiply_sample =
        (state == S_POWER_RE) ? {{8{scaled_re[15]}}, scaled_re} :
        (state == S_POWER_IM) ? {{8{scaled_im[15]}}, scaled_im} : sample_q;
    wire signed [15:0] multiply_coeff =
        (state == S_POWER_RE) ? scaled_re :
        (state == S_POWER_IM) ? scaled_im : coeff_q;
    wire signed [39:0] multiply_result = multiply_sample * multiply_coeff;

    function [7:0] energy_height;
        input [32:0] value;
        integer bit_index;
        reg [5:0] highest;
        reg [7:0] delta;
        begin
            highest = 6'd0;
            for (bit_index = 0; bit_index < 33; bit_index = bit_index + 1)
                if (value[bit_index]) highest = bit_index[5:0];
            if (highest < 6'd14) energy_height = 8'd0;
            else if (highest >= 6'd26) energy_height = 8'd120;
            else begin
                delta = {2'b00, highest} - 8'd14;
                energy_height = (delta << 3) + (delta << 1);
            end
        end
    endfunction
    wire [1:0] sens_bin = {sens_gray[1], sens_gray[1] ^ sens_gray[0]};
    wire signed [8:0] sensitivity_offset =
        (sens_bin == 2'd0) ? -9'sd8 :
        (sens_bin == 2'd1) ?  9'sd0 :
        (sens_bin == 2'd2) ?  9'sd8 : 9'sd16;
    wire signed [8:0] tuned_height = $signed({1'b0, energy_height(energy)}) + sensitivity_offset;
    wire [7:0] target_height = (tuned_height <= 9'sd0) ? 8'd0 :
                               (tuned_height >= 9'sd120) ? 8'd120 : tuned_height[7:0];
    wire [7:0] old_height = levels[{bin_index, 3'b000} +: 8];
    wire [7:0] next_height =
        (target_height > old_height) ?
            ((target_height > old_height + 8'd20) ? old_height + 8'd20 : target_height) :
            ((old_height > target_height + 8'd5) ? old_height - 8'd5 : target_height);

    reg ack_s0, ack_s1, ack_s2, done_pending;
    wire ack_pulse = ack_s1 ^ ack_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            capture_phase <= 1'b0; capture_bank <= 1'b0;
            capture_index <= 9'd0;
            ready_bank <= 1'b0; ready_valid <= 1'b0;
            process_bank <= 1'b0;
            state <= S_IDLE; bin_index <= 4'd0;
            sample_index <= 9'd0; phase <= 9'd0;
            product_q <= 40'sd0;
            sum_re <= 50'sd0; sum_im <= 50'sd0;
            scaled_re <= 16'sd0; scaled_im <= 16'sd0;
            power_re <= 32'd0; power_im <= 32'd0; energy <= 33'd0;
            levels <= 128'd0; done_toggle <= 1'b0; done_pending <= 1'b0;
            ack_s0 <= 1'b0; ack_s1 <= 1'b0; ack_s2 <= 1'b0;
        end else begin
            ack_s0 <= ack_toggle;
            ack_s1 <= ack_s0;
            ack_s2 <= ack_s1;
            if (ack_pulse) done_pending <= 1'b0;

            case (state)
                S_IDLE: if (ready_valid && !done_pending) begin
                    process_bank <= ready_bank;
                    ready_valid <= 1'b0;
                    bin_index <= 4'd0;
                    sample_index <= 9'd0;
                    phase <= 9'd0;
                    sum_re <= 50'sd0;
                    sum_im <= 50'sd0;
                    state <= S_READ;
                end
                S_READ: state <= S_MUL_RE;
                S_MUL_RE: begin
                    product_q <= multiply_result;
                    state <= S_ACC_RE;
                end
                S_ACC_RE: begin
                    sum_re <= sum_re + {{10{product_q[39]}}, product_q};
                    product_q <= multiply_result;
                    state <= S_ACC_IM;
                end
                S_ACC_IM: begin
                    sum_im <= sum_im - {{10{product_q[39]}}, product_q};
                    if (sample_index == 9'd511) state <= S_SCALE;
                    else begin
                        sample_index <= sample_index + 9'd1;
                        phase <= phase + current_bin;
                        state <= S_READ;
                    end
                end
                S_SCALE: begin
                    scaled_re <= sum_re[47:32];
                    scaled_im <= sum_im[47:32];
                    state <= S_POWER_RE;
                end
                S_POWER_RE: begin
                    power_re <= multiply_result[31:0];
                    state <= S_POWER_IM;
                end
                S_POWER_IM: begin
                    power_im <= multiply_result[31:0];
                    state <= S_ENERGY;
                end
                S_ENERGY: begin
                    energy <= {1'b0, power_re} + {1'b0, power_im};
                    state <= S_LEVEL;
                end
                S_LEVEL: begin
                    levels[{bin_index, 3'b000} +: 8] <= next_height;
                    if (bin_index == 4'd15) begin
                        done_toggle <= ~done_toggle;
                        done_pending <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        bin_index <= bin_index + 4'd1;
                        sample_index <= 9'd0;
                        phase <= 9'd0;
                        sum_re <= 50'sd0;
                        sum_im <= 50'sd0;
                        state <= S_READ;
                    end
                end
                default: state <= S_IDLE;
            endcase

            if (aud_tick) capture_phase <= ~capture_phase;
            if (capture_sample) begin
                if (capture_index == 9'd511) begin
                    capture_index <= 9'd0;
                    ready_bank <= capture_bank;
                    ready_valid <= 1'b1;
                    capture_bank <= ~capture_bank;
                end else capture_index <= capture_index + 9'd1;
            end
        end
    end
endmodule
