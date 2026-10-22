`timescale 1ns/1ps
// Bottom-up padded-window stream -> one vertically flipped persistent slot.
module view_write_address (
    input wire clk,rst,start,advance,
    input wire [20:0] frame_base,
    input wire [1:0] layout,window,
    output reg [20:0] address,total_words,
    output wire [9:0] line_words,
    output reg active,done,error
);
    reg [9:0] width_words,height_rows,x,y;
    reg [20:0] initial_offset;
    always @* begin
        if(layout==0)initial_offset=21'd460160;
        else if(layout==1)initial_offset=window[0] ? 21'd460480 : 21'd230080;
        else case(window)
            0:initial_offset=21'd114880;
            1:initial_offset=21'd230080;
            2:initial_offset=21'd345280;
            default:initial_offset=21'd460480;
        endcase
    end
    assign line_words=width_words-x;
    always @(posedge clk or posedge rst)begin
        if(rst)begin address<=0;total_words<=0;width_words<=0;height_rows<=0;
            x<=0;y<=0;active<=0;done<=0;error<=0;end
        else begin
            done<=0;
            if(start)begin
                width_words<=layout==0 ? 10'd640 : 10'd320;
                height_rows<=layout==2 ? 10'd360 : 10'd720;
                total_words<=layout==0 ? 21'd460800 : (layout==1 ? 21'd230400 : 21'd115200);
                address<=frame_base+initial_offset;x<=0;y<=0;
                error<=layout==3 || (layout==0 && window!=0) || (layout==1 && window>1);
                active<=layout!=3 && !(layout==0 && window!=0) && !(layout==1 && window>1);
            end else if(active && advance)begin
                if(x==width_words-1)begin
                    x<=0;
                    if(y==height_rows-1)begin active<=0;done<=1;end
                    else begin
                        y<=y+1'b1;
                        address<=address-(width_words==640 ? 21'd1279 : 21'd639);
                    end
                end else begin x<=x+1'b1;address<=address+1'b1;end
            end
        end
    end
endmodule
