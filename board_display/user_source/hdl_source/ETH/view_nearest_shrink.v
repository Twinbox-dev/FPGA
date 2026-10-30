`timescale 1ns/1ps
// Bottom-up RGB565, center-sampled nearest neighbour. Source rows are consumed
// once; no line RAM, interpolation DSP or fractional-coordinate registers.
// Samples floor((destination+0.5)*source/destination_size) independently per axis.
module view_nearest_shrink (
    input wire clk, rst, frame_begin, frame_end,
    input wire [11:0] source_width, source_height,
    input wire [1:0] layout,
    input wire [31:0] in_data,
    input wire in_valid,
    output wire in_ready,
    output reg out_frame_begin,
    output reg [11:0] out_width, out_height,
    output wire [31:0] out_data,
    output wire out_valid,
    input wire out_ready,
    output reg busy, done, error
);
    localparam IDLE=0, GEOMETRY=1, STREAM=2, FLUSH=3;
    reg [1:0] state;
    wire geometry_done, geometry_error;
    wire [11:0] dw,dh;
    view_scale_geometry #(.COORDINATES_ENABLED(0)) u_geometry (
        .clk(clk),.rst(rst),.start(frame_begin),.source_width(source_width),
        .source_height(source_height),.layout(layout),.busy(),.done(geometry_done),
        .error(geometry_error),.dest_width(dw),.dest_height(dh),.left_pad(),.bottom_pad(),
        .x_step(),.y_step(),.x_origin(),.y_origin()
    );
    reg [11:0] sw,sh,sx,sy;
    // Doubled integer phases preserve the exact half-pixel center even for
    // odd dimensions. Maximum phase is <2*1280, hence twelve bits suffice.
    reg [11:0] phase_x,phase_y;
    wire [12:0] stride_x={dw,1'b0},stride_y={dh,1'b0};
    wire selected=({1'b0,phase_x}<stride_x) && ({1'b0,phase_y}<stride_y);
    reg input_ended,word_valid,word_high,half_valid,output_valid;
    reg [31:0] word_hold,output_word;
    reg [15:0] low_pixel;
    wire [15:0] pixel=word_valid ? (word_high ? word_hold[31:16] : word_hold[15:0]) : 16'd0;
    wire output_room=!output_valid || out_ready;
    wire take=state==STREAM && (word_valid || input_ended) && (!selected || output_room);
    assign in_ready=state==STREAM && !word_valid && !input_ended;
    assign out_valid=output_valid;
    assign out_data=output_word;
    always @(posedge clk or posedge rst) begin
        if(rst)begin
            state<=IDLE;busy<=0;done<=0;error<=0;out_frame_begin<=0;
            out_width<=0;out_height<=0;sw<=0;sh<=0;sx<=0;sy<=0;
            phase_x<=0;phase_y<=0;input_ended<=0;word_valid<=0;word_high<=0;
            half_valid<=0;output_valid<=0;word_hold<=0;output_word<=0;low_pixel<=0;
        end else begin
            done<=0;out_frame_begin<=0;
            if(frame_end)input_ended<=1;
            if(output_valid && out_ready)output_valid<=0;
            if(in_valid && in_ready)begin word_hold<=in_data;word_valid<=1;word_high<=0;end
            case(state)
                IDLE:if(frame_begin)begin
                    busy<=1;error<=0;state<=GEOMETRY;sw<=source_width;sh<=source_height;
                    sx<=0;sy<=0;input_ended<=0;word_valid<=0;word_high<=0;
                    half_valid<=0;output_valid<=0;
                end
                GEOMETRY:if(geometry_done)begin
                    error<=geometry_error;out_width<=dw;out_height<=dh;out_frame_begin<=1;
                    phase_x<=sw;phase_y<=sh;state<=geometry_error ? FLUSH : STREAM;
                end
                STREAM:if(take)begin
                    if(word_valid)begin
                        if(word_high)begin word_valid<=0;word_high<=0;end
                        else word_high<=1;
                    end
                    if(selected)begin
                        if(!half_valid)begin low_pixel<=pixel;half_valid<=1;end
                        else begin output_word<={pixel,low_pixel};output_valid<=1;half_valid<=0;end
                    end
                    if(sx==sw-1'b1)begin
                        sx<=0;phase_x<=sw;
                        phase_y<=({1'b0,phase_y}<stride_y ? {1'b0,phase_y}+{sh,1'b0} : {1'b0,phase_y})-stride_y;
                        if(sy==sh-1'b1)begin state<=FLUSH;word_valid<=0;end
                        else sy<=sy+1'b1;
                    end else begin
                        sx<=sx+1'b1;
                        phase_x<=({1'b0,phase_x}<stride_x ? {1'b0,phase_x}+{sw,1'b0} : {1'b0,phase_x})-stride_x;
                    end
                end
                FLUSH:if(!output_valid)begin
                    if(half_valid)begin output_word<={16'd0,low_pixel};output_valid<=1;half_valid<=0;end
                    else begin busy<=0;done<=1;state<=IDLE;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
