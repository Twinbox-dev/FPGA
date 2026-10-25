`timescale 1ns/1ps
// One stable mailbox, installed at input VS before the next read-request CDC.
// The actual safety ACK is generated later by frame_fifo_read after drain.
module view_video_config(
    input wire clk,rst,vs,
    input wire raw_epoch,raw_buffer,
    input wire [1:0] raw_layout,
    input wire [3:0] raw_mask,
    input wire [3:0] raw_window_buffers,
    output reg epoch,buffer_index,
    output reg [1:0] layout,
    output reg [3:0] valid_mask,
    output reg [3:0] window_buffers
);
    reg [2:0] epoch_sync;
    reg [10:0] fields0,fields1;
    reg vs_d;
    always @(posedge clk or posedge rst)begin
        if(rst)begin epoch_sync<=0;fields0<=0;fields1<=0;vs_d<=0;
            epoch<=0;buffer_index<=0;layout<=0;valid_mask<=0;window_buffers<=0;end
        else begin
            epoch_sync<={epoch_sync[1:0],raw_epoch};
            fields0<={raw_buffer,raw_layout,raw_mask,raw_window_buffers};fields1<=fields0;vs_d<=vs;
            if(vs && !vs_d && epoch_sync[2]!=epoch)begin
                {buffer_index,layout,valid_mask,window_buffers}<=fields1;epoch<=epoch_sync[2];
            end
        end
    end
endmodule
