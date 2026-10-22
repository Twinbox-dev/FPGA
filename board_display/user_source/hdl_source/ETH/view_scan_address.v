`timescale 1ns/1ps
// Raster-order video words -> contiguous per-window SDRAM slots. One advance
// represents one returned video word, including a synthesized black word.
module view_scan_address (
    input wire clk,rst,frame_begin,advance,
    input wire [20:0] frame_base,
    input wire [1:0] layout,
    input wire [3:0] valid_mask,
    output reg [20:0] address,
    output wire [1:0] window_index,
    output wire black,
    output wire [9:0] segment_words,
    output reg active,done,error
);
    reg [20:0] base,left_row,slot_words;
    reg [1:0] mode;
    reg [3:0] mask;
    reg [9:0] row_y,word_x;
    reg side;
    assign window_index=mode==0 ? 2'd0 : (mode==1 ? {1'b0,side} : {row_y>=10'd360,side});
    assign black=!mask[window_index];
    assign segment_words=(mode==0 ? 10'd640 : 10'd320)-word_x;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            address<=0;base<=0;left_row<=0;slot_words<=0;mode<=0;mask<=0;
            row_y<=0;word_x<=0;side<=0;active<=0;done<=0;error<=0;
        end else begin
            done<=0;
            if(frame_begin)begin
                base<=frame_base;left_row<=frame_base;address<=frame_base;
                mode<=layout;mask<=valid_mask;row_y<=0;word_x<=0;side<=0;
                slot_words<=layout==1 ? 21'd230400 : 21'd115200;
                active<=layout!=3;error<=layout==3;done<=layout==3;
            end else if(active && advance)begin
                if(mode==0)begin
                    address<=address+1'b1;
                    if(word_x==639)begin
                        word_x<=0;row_y<=row_y+1'b1;
                        if(row_y==719)begin active<=0;done<=1;end
                    end else word_x<=word_x+1'b1;
                end else if(word_x==319)begin
                    word_x<=0;side<=~side;
                    if(!side)address<=left_row+slot_words;
                    else if(row_y==719)begin active<=0;done<=1;end
                    else begin
                        row_y<=row_y+1'b1;
                        if(mode==2 && row_y==359)begin
                            left_row<=base+21'd230400;address<=base+21'd230400;
                        end else begin left_row<=left_row+21'd320;address<=left_row+21'd320;end
                    end
                end else begin word_x<=word_x+1'b1;address<=address+1'b1;end
            end
        end
    end
endmodule
