module direct_video_region_mux #(
    parameter integer H_ACTIVE=1280,
    parameter integer V_ACTIVE=720,
    parameter integer VIDEO_WIDTH=640,
    parameter integer VIDEO_HEIGHT=360
)(
    input wire clk,
    input wire rst,
    input wire video_mode,
    input wire de,
    input wire vs,
    input wire [23:0] video_rgb,
    input wire [23:0] still_rgb,
    output wire [23:0] rgb_out
);
    localparam integer X_BITS=$clog2(H_ACTIVE+1);
    localparam integer Y_BITS=$clog2(V_ACTIVE+1);
    localparam [X_BITS-1:0] VIDEO_WIDTH_X=VIDEO_WIDTH;
    localparam [Y_BITS-1:0] VIDEO_HEIGHT_Y=VIDEO_HEIGHT;
    localparam [Y_BITS-1:0] V_ACTIVE_Y=V_ACTIVE;
    reg [X_BITS-1:0] x;
    reg [Y_BITS-1:0] y;
    reg de_d,vs_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            x<=0;y<=0;de_d<=0;vs_d<=1;
        end else begin
            de_d<=de;vs_d<=vs;
            if (vs_d && !vs)
                y<=0;
            else if (de_d && !de && y<V_ACTIVE_Y)
                y<=y+1'b1;
            if (!de)
                x<=0;
            else
                x<=x+1'b1;
        end
    end

    assign rgb_out=video_mode ?
                   ((x<VIDEO_WIDTH_X)&&(y<VIDEO_HEIGHT_Y)?video_rgb:24'd0) : still_rgb;
endmodule
