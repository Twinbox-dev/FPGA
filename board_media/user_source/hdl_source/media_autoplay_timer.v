module media_autoplay_timer #(
    parameter integer CLK_HZ=125000000
)(
    input wire clk,rst,enable,busy,committed_valid,
    input wire [3:0] period_s,
    output reg next_pulse
);
    localparam [26:0] LAST_CYCLE=CLK_HZ-1;
    reg [26:0] cycle_count;
    reg [3:0] elapsed_seconds;
    wire [3:0] effective_period=period_s==0?4'd1:period_s;
    always @(posedge clk or posedge rst) begin
        if(rst)begin cycle_count<=0;elapsed_seconds<=0;next_pulse<=0;end
        else begin
            next_pulse<=0;
            if(!enable || !committed_valid || busy)begin cycle_count<=0;elapsed_seconds<=0;end
            else if(cycle_count==LAST_CYCLE)begin
                cycle_count<=0;
                if(elapsed_seconds+4'd1>=effective_period)begin
                    elapsed_seconds<=0;next_pulse<=1;
                end else elapsed_seconds<=elapsed_seconds+4'd1;
            end else cycle_count<=cycle_count+1'b1;
        end
    end
endmodule
