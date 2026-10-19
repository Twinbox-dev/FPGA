// Synchronized 50 ms debounce for the media board's active-low push buttons.
module media_button_debounce #(
    parameter integer CLK_FREQ_HZ=50000000,
    parameter integer DEBOUNCE_MS=50
)(
    input wire clk,rst,
    input wire button_n,
    output reg press_pulse
);
    localparam integer DEBOUNCE_CYCLES=(CLK_FREQ_HZ/1000)*DEBOUNCE_MS;
    reg sync0,sync1,stable;
    reg [31:0] count;
    always @(posedge clk or posedge rst) begin
        if(rst)begin sync0<=1;sync1<=1;stable<=1;count<=0;press_pulse<=0;end
        else begin
            sync0<=button_n;sync1<=sync0;press_pulse<=0;
            if(sync1==stable)count<=0;
            else if(count>=DEBOUNCE_CYCLES-1)begin
                if(stable && !sync1)press_pulse<=1;
                stable<=sync1;count<=0;
            end else count<=count+1'b1;
        end
    end
endmodule
