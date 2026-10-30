`timescale 1ns/1ps
// Validated native pixels -> aspect-fit RGB565 -> padded bottom-up window slot.
// Original source dimensions remain separate metadata; audio bypasses unchanged.
module view_image_pipeline(
    input wire clk,rst,frame_begin,frame_end,
    input wire [11:0] image_width,image_height,
    input wire [1:0] layout,
    input wire in_audio,in_start,in_done,
    input wire [8:0] in_count,
    input wire [31:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output wire out_audio,out_start,out_done,
    output wire [8:0] out_count,
    output wire [31:0] out_data,
    output wire out_valid,
    input wire out_ready,
    output wire frame_done
);
    wire shrink_begin,shrink_done,shrink_ready,shrink_valid,shrink_take;
    wire [11:0] width,height;
    wire [31:0] pixels;
    wire pad_ready;
    view_nearest_shrink u_shrink(.clk(clk),.rst(rst),.frame_begin(frame_begin),
        .frame_end(frame_end),.source_width(image_width),.source_height(image_height),
        .layout(layout),.in_data(in_data),.in_valid(in_valid && !in_audio),
        .in_ready(shrink_take),.out_frame_begin(shrink_begin),.out_width(width),
        .out_height(height),.out_data(pixels),.out_valid(shrink_valid),
        .out_ready(shrink_ready),.busy(),.done(shrink_done),.error());
    assign in_ready=in_audio ? pad_ready : shrink_take;
    assign shrink_ready=pad_ready && !in_audio;
    media_frame_pad #(.VIEW_ENABLE(1)) u_pad(.clk(clk),.rst(rst),
        .frame_begin(shrink_begin),.image_width(width),.image_height(height),
        .frame_end(shrink_done),.layout(layout),.in_is_audio(in_audio),
        .in_start(in_start),.in_count(in_count),.in_data(in_audio ? in_data : pixels),
        .in_valid(in_audio ? in_valid : shrink_valid),.in_ready(pad_ready),
        .in_done(in_done),.out_start(out_start),.out_is_audio(out_audio),
        .out_count(out_count),.out_data(out_data),.out_valid(out_valid),
        .out_ready(out_ready),.out_done(out_done),.frame_done(frame_done));
endmodule
