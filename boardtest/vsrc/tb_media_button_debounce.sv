`timescale 1ns/1ps
module tb_media_button_debounce;
    reg clk=0; always #5 clk=~clk;
    reg rst=1;
    reg button_n=0;
    wire press_pulse;
    integer pulses=0;

    media_button_debounce #(.CLK_FREQ_HZ(1000),.DEBOUNCE_MS(3)) dut (
        .clk(clk),.rst(rst),.button_n(button_n),.press_pulse(press_pulse)
    );

    always @(posedge clk) if(!rst && press_pulse) pulses<=pulses+1;

    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        // A key held low through reset must not become a startup click.
        repeat(12) @(negedge clk);
        if(pulses!=0) $fatal(1,"startup-low generated a press pulse");

        // Release long enough to arm, then require one pulse for a real press.
        button_n=1;
        repeat(8) @(negedge clk);
        if(!dut.armed) $fatal(1,"released key did not arm");
        button_n=0;
        repeat(8) @(negedge clk);
        if(pulses!=1) $fatal(1,"press count after first click=%0d",pulses);
        repeat(8) @(negedge clk);
        if(pulses!=1) $fatal(1,"held key repeated unexpectedly: %0d",pulses);

        button_n=1;
        repeat(8) @(negedge clk);
        button_n=0;
        repeat(8) @(negedge clk);
        if(pulses!=2) $fatal(1,"press count after second click=%0d",pulses);

        $display("PASS: startup-held key is ignored; released physical clicks remain one-shot");
        $finish;
    end
    initial begin #10000;$fatal(1,"timeout");end
endmodule
