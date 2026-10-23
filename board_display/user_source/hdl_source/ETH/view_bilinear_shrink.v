`timescale 1ns/1ps
// Image-only, bottom-up RGB565 shrinker. Two single-read-port line memories
// are reused; image reception pauses while a destination row is calculated.
// Audio routing and the surrounding window's black border are handled outside.
module view_bilinear_shrink (
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
    localparam IDLE=0, GEOMETRY=1, FILL=2, READ0=3, READ1=4,
               HORIZONTAL=5, VERTICAL=6, EMIT=7, DRAIN=8, FLUSH=9, PASS=10,HORIZONTAL1=11,
               MULTIPLY=12,ACCUMULATE=13,STORE=14;
    reg [3:0] state;
    wire geometry_done, geometry_error;
    wire [11:0] dw, dh;
    wire [31:0] step_x, step_y, origin_x, origin_y;
    view_scale_geometry u_geometry (
        .clk(clk),.rst(rst),.start(frame_begin),.source_width(source_width),
        .source_height(source_height),.layout(layout),.busy(),.done(geometry_done),
        .error(geometry_error),.dest_width(dw),.dest_height(dh),.left_pad(),.bottom_pad(),
        .x_step(step_x),.y_step(step_y),.x_origin(origin_x),.y_origin(origin_y)
    );
    reg [11:0] sw, sh;
    reg [19:0] pixel_total, pixels_consumed;
    reg [10:0] source_x, dest_x;
    reg [9:0] source_y, dest_y;
    reg [31:0] x_position, y_position;
    reg input_ended;
    reg [31:0] word_hold;
    reg word_valid, word_high;
    reg half_valid;
    reg [15:0] low_pixel;
    reg [31:0] output_word;
    reg output_valid;
    wire output_room = !output_valid || out_ready;
    wire cache_mode = state==FILL || state==DRAIN;
    assign in_ready = state==PASS ? (out_ready && !input_ended) :
                      (cache_mode && !word_valid && !input_ended && pixels_consumed<pixel_total);
    assign out_valid = state==PASS ? (in_valid || input_ended) : output_valid;
    assign out_data = state==PASS ? (in_valid ? in_data : 32'd0) : output_word;
    wire pixel_take = cache_mode && pixels_consumed<pixel_total && (word_valid || input_ended);
    wire [15:0] source_pixel = word_valid ? (word_high ? word_hold[31:16] : word_hold[15:0]) : 16'd0;
    wire [11:0] x0 = dw>1 && dest_x==dw-1 ? sw-1'b1 : x_position[27:16];
    wire [11:0] x1 = x0+1'b1<sw ? x0+1'b1 : x0;
    wire [11:0] y0 = dh>1 && dest_y==dh-1 ? sh-1'b1 : y_position[27:16];
    wire [11:0] y1 = y0+1'b1<sh ? y0+1'b1 : y0;
    wire [7:0] fx = dw>1 && dest_x==dw-1 ? 8'd0 : x_position[15:8];
    wire [7:0] fy = dh>1 && dest_y==dh-1 ? 8'd0 : y_position[15:8];

    reg [15:0] line0[0:1279]; /* fehdl force_ram=1, ram_style="bram_32k" */
    reg [15:0] line1[0:1279]; /* fehdl force_ram=1, ram_style="bram_32k" */
    reg [15:0] q0, q1, a0, a1;
    wire ram_read = (state==READ0 && output_room) || state==READ1;
    wire [10:0] ram_address = state==READ0 ? x0[10:0] : x1[10:0];
    always @(posedge clk) begin
        if(state==FILL && pixel_take) begin
            if(source_y[0])line1[source_x]<=source_pixel;
            else line0[source_x]<=source_pixel;
        end
        if(ram_read)begin q0<=line0[ram_address];q1<=line1[ram_address];end
    end
    reg row0_odd,row1_odd;
    reg [7:0] weight_x,weight_y;
    wire [15:0] b0 = row0_odd ? q1 : q0;
    wire [15:0] b1 = row1_odd ? q1 : q0;
    // One shared RGB/axis interpolator. There is ample inter-packet slack;
    // serializing channels avoids six parallel add/sub/multiply datapaths and
    // their 168-bit intermediate register bank, with identical final rounding.
    reg [15:0] h0,h1,result_pixel;
    reg [1:0] channel;
    function [5:0] component(input [15:0] pixel,input [1:0] ch);
        begin case(ch)
            0:component={1'b0,pixel[15:11]};
            1:component=pixel[10:5];
            default:component={1'b0,pixel[4:0]};
        endcase end
    endfunction
    // operation is registered on the transition into each interpolation
    // phase.  Decoding the 15-state FSM in front of the DSP operands added a
    // long control path; the phase already has a state register, so use it.
    wire [15:0] mix_a=operation==2 ? h0 :
                      {10'd0,component(operation==1 ? a1 : a0,channel)};
    wire [15:0] mix_b=operation==2 ? h1 :
                      {10'd0,component(operation==1 ? b1 : b0,channel)};
    wire [7:0] mix_fraction=operation==2 ? weight_y : weight_x;
    wire signed [16:0] difference=$signed({1'b0,mix_b})-$signed({1'b0,mix_a});
    reg [15:0] base_reg;
    wire signed [25:0] product_reg;
    reg signed [25:0] mixed;
    reg [1:0] operation;
    // Separate subtract, DSP and accumulate boundaries. The combinational
    // version had a measured 23.9 ns path at the 125 MHz UDP clock.
    wire calculate=state==HORIZONTAL || state==HORIZONTAL1 || state==VERTICAL;
`ifdef VERILATOR
    // Same CE/reset/two-edge latency as TD's EG_PHY_MULT18 functional model.
    reg signed [16:0] model_a;
    reg [7:0] model_b;
    reg signed [25:0] model_p;
    always @(posedge clk or posedge rst)begin
        if(rst)begin model_a<=0;model_b<=0;model_p<=0;end
        else begin
            if(calculate)begin model_a<=difference;model_b<=mix_fraction;end
            model_p<=model_a*$signed({1'b0,model_b});
        end
    end
    assign product_reg=model_p;
`else
    // Native input/output registers consume DSP storage, not extra MSlices.
    // Parameters and SOURCE=1 (direct a/b, not cascade) were checked against
    // TD 6.2.1 sim_release/eg4/eg_phy_mult18.v, lines 54-71 and 314-325.
    wire [35:0] native_product;
    EG_PHY_MULT18 #(.MODE("MULT18X18C"),.INPUTREGA("ENABLE"),.INPUTREGB("ENABLE"),
        .OUTPUTREG("ENABLE"),.SRMODE("ASYNC")) u_interpolation_dsp(
        .a({difference[16],difference}),.b({10'd0,mix_fraction}),
        .acin(18'd0),.bcin(18'd0),.sourcea(1'b1),.sourceb(1'b1),
        .signeda(1'b1),.signedb(1'b1),.cea(calculate),.ceb(calculate),.cepd(1'b1),
        .clk(clk),.rstan(~rst),.rstbn(~rst),.rstpdn(~rst),
        .acout(),.bcout(),.p(native_product));
    assign product_reg=native_product[25:0];
`endif
    wire [5:0] rounded=mixed[21:16]+{5'd0,mixed[15]};

    always @(posedge clk or posedge rst) begin
        if(rst)begin
            state<=IDLE;busy<=0;done<=0;error<=0;out_frame_begin<=0;out_width<=0;out_height<=0;
            sw<=0;sh<=0;pixel_total<=0;pixels_consumed<=0;source_x<=0;source_y<=0;
            dest_x<=0;dest_y<=0;x_position<=0;y_position<=0;input_ended<=0;
            word_hold<=0;word_valid<=0;word_high<=0;half_valid<=0;low_pixel<=0;
            output_word<=0;output_valid<=0;a0<=0;a1<=0;
            h0<=0;h1<=0;result_pixel<=0;channel<=0;
            row0_odd<=0;row1_odd<=0;weight_x<=0;weight_y<=0;
            base_reg<=0;mixed<=0;operation<=0;
        end else begin
            done<=0;out_frame_begin<=0;
            if(frame_end)input_ended<=1;
            if(output_valid && out_ready)output_valid<=0;
            if(in_valid && in_ready && state!=PASS)begin
                word_hold<=in_data;word_valid<=1;word_high<=0;
            end
            if(pixel_take)begin
                pixels_consumed<=pixels_consumed+1'b1;
                if(word_valid)begin
                    if(word_high)begin word_high<=0;word_valid<=0;end
                    else word_high<=1;
                end
            end
            case(state)
                IDLE:if(frame_begin)begin
                    busy<=1;error<=0;state<=GEOMETRY;sw<=source_width;sh<=source_height;
                    pixel_total<=source_width*source_height;pixels_consumed<=0;
                    source_x<=0;source_y<=0;dest_x<=0;dest_y<=0;input_ended<=0;
                    word_valid<=0;word_high<=0;half_valid<=0;output_valid<=0;
                end
                GEOMETRY:if(geometry_done)begin
                    error<=geometry_error;out_width<=dw;out_height<=dh;
                    out_frame_begin<=1;x_position<=origin_x;y_position<=origin_y;
                    state<=geometry_error ? FLUSH : ((dw==sw && dh==sh) ? PASS : FILL);
                end
                PASS:if(out_valid && out_ready)begin
                    if(pixels_consumed+20'd2>=pixel_total)begin
                        pixels_consumed<=pixel_total;state<=FLUSH;
                    end else pixels_consumed<=pixels_consumed+20'd2;
                end
                FILL:if(pixel_take)begin
                    if(source_x==sw-1)begin
                        source_x<=0;source_y<=source_y+1'b1;
                        if({2'd0,source_y}>=y1)state<=READ0;
                    end else source_x<=source_x+1'b1;
                end
                READ0:if(output_room)begin
                    row0_odd<=y0[0];row1_odd<=y1[0];weight_x<=fx;weight_y<=fy;state<=READ1;
                end
                READ1:begin a0<=b0;a1<=b1;state<=HORIZONTAL;channel<=0;operation<=0;end
                HORIZONTAL,HORIZONTAL1,VERTICAL:begin
                    base_reg<=mix_a;
                    state<=MULTIPLY;
                end
                MULTIPLY:state<=ACCUMULATE;
                ACCUMULATE:begin mixed<=$signed({2'd0,base_reg,8'd0})+product_reg;state<=STORE;end
                STORE:begin
                    if(operation==0)begin h0<=mixed[15:0];state<=HORIZONTAL1;operation<=1;end
                    else if(operation==1)begin h1<=mixed[15:0];state<=VERTICAL;operation<=2;end
                    else begin
                        case(channel)
                            0:result_pixel[15:11]<=rounded[4:0];
                            1:result_pixel[10:5]<=rounded;
                            default:result_pixel[4:0]<=rounded[4:0];
                        endcase
                        if(channel==2)state<=EMIT;
                        else begin channel<=channel+1'b1;state<=HORIZONTAL;operation<=0;end
                    end
                end
                EMIT:begin
                    if(!half_valid)begin low_pixel<=result_pixel;half_valid<=1;end
                    else begin output_word<={result_pixel,low_pixel};output_valid<=1;half_valid<=0;end
                    if(dest_x==dw-1)begin
                        dest_x<=0;x_position<=origin_x;
                        if(dest_y==dh-1)state<=pixels_consumed>=pixel_total ? FLUSH : DRAIN;
                        else begin dest_y<=dest_y+1'b1;y_position<=y_position+step_y;state<=FILL;end
                    end else begin dest_x<=dest_x+1'b1;x_position<=x_position+step_x;state<=READ0;end
                end
                DRAIN:if(pixels_consumed>=pixel_total || (pixel_take && pixels_consumed+1'b1>=pixel_total))state<=FLUSH;
                FLUSH:if(!output_valid)begin
                    if(half_valid)begin output_word<={16'd0,low_pixel};output_valid<=1;half_valid<=0;end
                    else begin word_valid<=0;busy<=0;done<=1;state<=IDLE;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
