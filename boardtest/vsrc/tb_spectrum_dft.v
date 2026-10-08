`timescale 1ns/1ps
module tb_spectrum_dft;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, aud_tick = 0, aud_valid = 1, ack_toggle = 0;
    reg signed [23:0] pcm = 0;
    wire [127:0] levels;
    wire done_toggle;
    integer n, i;
    reg signed [23:0] tone;
    spectrum_dft #(
        .COEFF_FILE("../board/user_source/hdl_source/SD/spectrum_twiddle_512.mem")
    ) dut (
        .clk(clk), .rst(rst), .aud_tick(aud_tick), .aud_valid(aud_valid),
        .pcm(pcm), .sens_gray(2'b01), // binary sensitivity level 1
        .ack_toggle(ack_toggle), .levels(levels), .done_toggle(done_toggle)
    );

    task automatic tick(input signed [23:0] sample_word);
        begin
            @(negedge clk); pcm = sample_word; aud_tick = 1;
            @(negedge clk); aud_tick = 0;
            repeat (78) @(negedge clk);
        end
    endtask
    task automatic window(input integer frequency_bin_a, input integer frequency_bin_b);
        begin
            for (n = 0; n < 512; n = n + 1) begin
                if (frequency_bin_a == 0) tone = 24'sd0;
                else tone = $rtoi((frequency_bin_b == 0 ? 4000000.0 : 2000000.0) *
                                  $sin(6.283185307179586 * frequency_bin_a * n / 512));
                if (frequency_bin_b != 0)
                    tone = tone + $rtoi(2000000.0 *
                            $sin(6.283185307179586 * frequency_bin_b * n / 512));
                tick(tone);
                tick(tone); // HDMI output repeats each 24 kHz source sample
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0;
        window(8, 0); // configured display band 5 is DFT coefficient k=8
        wait (done_toggle == 1'b1);
        repeat (4) @(negedge clk);
        if (levels[5*8 +: 8] !== 8'd20)
            $fatal(1, "k=8 tone not detected: band5=%0d", levels[5*8 +: 8]);
        for (i=0; i<16; i=i+1)
            if (i != 5 && levels[i*8 +: 8] > 8'd5)
                $fatal(1, "k=8 tone leaked to band%0d=%0d", i, levels[i*8 +: 8]);
        ack_toggle = 1;
        window(8, 40); // independent second tone belongs to band 10
        wait (done_toggle == 1'b0);
        repeat (4) @(negedge clk);
        if (levels[5*8 +: 8] !== 8'd40 || levels[10*8 +: 8] !== 8'd20)
            $fatal(1, "two-tone band isolation failed: k8=%0d k40=%0d",
                   levels[5*8 +: 8], levels[10*8 +: 8]);
        ack_toggle = 0;
        window(0, 0);
        wait (done_toggle == 1'b1);
        repeat (4) @(negedge clk);
        if (levels[5*8 +: 8] !== 8'd35 || levels[10*8 +: 8] !== 8'd15)
            $fatal(1, "silent frame did not release both bands");
        $display("PASS spectrum DFT: selected-bin tone, two-tone isolation, silence release");
        $finish;
    end
    initial begin
        #30_000_000;
        $fatal(1, "spectrum DFT timeout");
    end
endmodule
