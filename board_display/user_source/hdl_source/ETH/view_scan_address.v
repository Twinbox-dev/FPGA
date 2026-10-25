`timescale 1ns/1ps
// Raster-order video words -> contiguous per-window SDRAM slots. One advance
// represents one returned video word, including a synthesized black word.
module view_scan_address (
    input wire clk,rst,frame_begin,advance,
    input wire [20:0] frame_base,
    input wire [20:0] frame_base_alt,
    input wire [3:0] window_buffers,
    input wire [1:0] layout,
    input wire [3:0] valid_mask,
    output wire [20:0] address,
    output wire [1:0] window_index,
    output wire black,
    output wire [9:0] segment_words,
    output reg active,done,error
);
    reg [1:0] mode;
    reg [3:0] mask,buffer_mask;
    reg [9:0] row_y,word_x;
    reg side;
    reg [20:0] slot_offset,row_offset;
    wire [9:0] local_y=(mode==2 && row_y>=10'd360) ? row_y-10'd360 : row_y;
    wire [20:0] page_base=buffer_mask[window_index] ? frame_base_alt : frame_base;
    assign window_index=mode==0 ? 2'd0 : (mode==1 ? {1'b0,side} : {row_y>=10'd360,side});
    assign black=!mask[window_index];
    assign segment_words=(mode==0 ? 10'd640 : 10'd320)-word_x;
    always @* begin
        slot_offset=21'd0;
        row_offset=21'd0;
        if(mode==0)begin
            row_offset=({11'd0,row_y}<<9)+({11'd0,row_y}<<7)+{11'd0,word_x};
        end else if(mode==1)begin
            slot_offset=window_index[0] ? 21'd230400 : 21'd0;
            row_offset=({11'd0,row_y}<<8)+({11'd0,row_y}<<6)+{11'd0,word_x};
        end else begin
            case(window_index)
                0:slot_offset=21'd0;
                1:slot_offset=21'd115200;
                2:slot_offset=21'd230400;
                default:slot_offset=21'd345600;
            endcase
            row_offset=({11'd0,local_y}<<8)+({11'd0,local_y}<<6)+{11'd0,word_x};
        end
    end
    assign address=page_base+slot_offset+row_offset;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            mode<=0;mask<=0;buffer_mask<=0;
            row_y<=0;word_x<=0;side<=0;active<=0;done<=0;error<=0;
        end else begin
            done<=0;
            if(frame_begin)begin
                mode<=layout;mask<=valid_mask;buffer_mask<=window_buffers;
                row_y<=0;word_x<=0;side<=0;
                active<=layout!=3;error<=layout==3;done<=layout==3;
            end else if(active && advance)begin
                if(mode==0)begin
                    if(word_x==639)begin
                        word_x<=0;row_y<=row_y+1'b1;
                        if(row_y==719)begin active<=0;done<=1;end
                    end else word_x<=word_x+1'b1;
                end else if(word_x==319)begin
                    word_x<=0;side<=~side;
                    if(side && row_y==719)begin active<=0;done<=1;end
                    else begin
                        if(side)row_y<=row_y+1'b1;
                        if(!side && mode==1)side<=1'b1;
                        if(side)side<=1'b0;
                    end
                end else word_x<=word_x+1'b1;
            end
        end
    end
endmodule
