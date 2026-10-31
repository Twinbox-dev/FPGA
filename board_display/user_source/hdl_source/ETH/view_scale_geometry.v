`timescale 1ns/1ps
// Once-per-image aspect fit and Q16 bilinear coordinates. One iterative
// divider is shared by dimension fitting and the two sample steps.
module view_scale_geometry #(parameter COORDINATES_ENABLED=1) (
    input wire clk, rst, start,
    input wire [11:0] source_width, source_height,
    input wire [1:0] layout,
    output reg busy, done, error,
    output reg [11:0] dest_width, dest_height,
    output reg [11:0] left_pad, bottom_pad,
    output reg [31:0] x_step, y_step, x_origin, y_origin
);
    localparam IDLE=0, COMPARE=1, FIT=2, DIVIDE=3, DIV_DONE=4,
               X_SETUP=5, Y_SETUP=6, FINISH=7;
    reg [3:0] state;
    reg [1:0] after_div;
    reg [11:0] sw, sh, limit_w, limit_h;
    reg [23:0] cross_w, cross_h;
    // Legal numerators are <=1279<<16 (<2^27), divisors <=1280.
    // Restoring division keeps remainder<divisor, so a 13-bit trial suffices.
    reg [27:0] dividend, quotient;
    reg [11:0] divisor;
    reg [12:0] remainder;
    reg [5:0] remaining;
    wire [12:0] trial = {remainder[11:0],dividend[27]};
    wire subtract = trial >= {1'b0,divisor};
    task begin_divide(input [31:0] numerator, input [31:0] denominator,
                      input [1:0] continuation);
        begin
            dividend<=numerator[27:0];divisor<=denominator[11:0];quotient<=0;
            remainder<=0;remaining<=28;after_div<=continuation;state<=DIVIDE;
        end
    endtask
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;busy<=0;done<=0;error<=0;sw<=0;sh<=0;limit_w<=0;limit_h<=0;
            cross_w<=0;cross_h<=0;dest_width<=0;dest_height<=0;left_pad<=0;bottom_pad<=0;
            x_step<=0;y_step<=0;x_origin<=0;y_origin<=0;
            dividend<=0;divisor<=0;quotient<=0;remainder<=0;remaining<=0;after_div<=0;
        end else begin
            done<=0;
            case(state)
                IDLE:if(start) begin
                    busy<=1;error<=0;sw<=source_width;sh<=source_height;
                    limit_w<=layout==0 ? 12'd1280 : 12'd640;
                    limit_h<=layout==2 ? 12'd360 : 12'd720;
                    x_origin<=0;y_origin<=0;
                    if(source_width==0 || source_width>1280 || source_height==0 ||
                       source_height>720 || layout==3) begin error<=1;state<=FINISH;end
                    else state<=COMPARE;
                end
                COMPARE:begin
                    cross_w<=sw*limit_h;cross_h<=sh*limit_w;state<=FIT;
                end
                FIT:begin
                    if(sw<=limit_w && sh<=limit_h) begin
                        dest_width<=sw;dest_height<=sh;state<=COORDINATES_ENABLED ? X_SETUP : FINISH;
                    end else if(cross_w>=cross_h) begin
                        dest_width<=limit_w;begin_divide({8'd0,cross_h},{20'd0,sw},0);
                    end else begin
                        dest_height<=limit_h;begin_divide({8'd0,cross_w},{20'd0,sh},1);
                    end
                end
                DIVIDE:begin
                    dividend<={dividend[26:0],1'b0};
                    quotient<={quotient[26:0],subtract};
                    remainder<=subtract ? trial-{1'b0,divisor} : trial;
                    remaining<=remaining-1'b1;
                    if(remaining==1)state<=DIV_DONE;
                end
                DIV_DONE:case(after_div)
                    0:begin dest_height<=quotient==0 ? 12'd1 : quotient[11:0];state<=COORDINATES_ENABLED ? X_SETUP : FINISH;end
                    1:begin dest_width<=quotient==0 ? 12'd1 : quotient[11:0];state<=COORDINATES_ENABLED ? X_SETUP : FINISH;end
                    2:begin x_step<={4'd0,quotient};state<=Y_SETUP;end
                    3:begin y_step<={4'd0,quotient};state<=FINISH;end
                endcase
                X_SETUP:if(dest_width<=1) begin
                    x_step<=0;x_origin<=({20'd0,sw}-1'b1)<<15;state<=Y_SETUP;
                end else begin_divide(({20'd0,sw}-1'b1)<<16,{20'd0,dest_width}-1'b1,2);
                Y_SETUP:if(dest_height<=1) begin
                    y_step<=0;y_origin<=({20'd0,sh}-1'b1)<<15;state<=FINISH;
                end else begin_divide(({20'd0,sh}-1'b1)<<16,{20'd0,dest_height}-1'b1,3);
                FINISH:begin
                    left_pad<=(limit_w-dest_width)>>1;
                    bottom_pad<=(limit_h-dest_height)-((limit_h-dest_height)>>1);
                    busy<=0;done<=1;state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
