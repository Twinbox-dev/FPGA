// HDMI-only cursor, after OSD. Input RGB and DE/VS all gain one clock of
// latency together. Pointer position is committed once per video frame.
module gt911_cursor_overlay #(
    parameter [10:0] INIT_X = 11'd640,
    parameter [9:0] INIT_Y = 10'd360
)(
    input  wire        video_clk,
    input  wire        rst,
    input  wire [23:0] video_in,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire        online_raw,
    input  wire        cursor_req_toggle,
    input  wire [10:0] cursor_mailbox_x,
    input  wire [9:0]  cursor_mailbox_y,
    output reg         cursor_ack_toggle,
    output reg  [23:0] video_out,
    output reg         de_out,
    output reg         vs_out
);
    reg req_s0, req_s1;
    reg online_s0, online_s1, online_frame;
    reg [10:0] pending_x, frame_x;
    reg [9:0] pending_y, frame_y;
    reg [10:0] x_cnt;
    reg [9:0] y_cnt;
    reg de_d, vs_d;
    wire vs_rise = vs_in && !vs_d;
    wire de_fall = !de_in && de_d;

    wire [10:0] rel_x = x_cnt - frame_x;
    wire [9:0] rel_y = y_cnt - frame_y;
    wire in_box = (x_cnt >= frame_x) && (y_cnt >= frame_y) &&
                  (rel_x < 11'd13) && (rel_y < 10'd18);
    wire arrow_head = (rel_y < 10'd13) && (rel_x <= {1'b0, rel_y});
    wire arrow_stem = (rel_y >= 10'd8) && (rel_y < 10'd18) &&
                      (rel_x >= 11'd3) && (rel_x <= 11'd6);
    wire cursor_hit = online_frame && de_in && in_box &&
                      (arrow_head || arrow_stem);
    wire cursor_edge = (rel_x == 11'd0) || (rel_y == 10'd0) ||
                       ((rel_y < 10'd13) && (rel_x == {1'b0, rel_y})) ||
                       ((rel_y >= 10'd13) &&
                        ((rel_x == 11'd3) || (rel_x == 11'd6) ||
                         (rel_y == 10'd17)));
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            req_s0 <= 1'b0;
            req_s1 <= 1'b0;
            online_s0 <= 1'b0;
            online_s1 <= 1'b0;
            online_frame <= 1'b0;
            cursor_ack_toggle <= 1'b0;
            pending_x <= INIT_X;
            pending_y <= INIT_Y;
            frame_x <= INIT_X;
            frame_y <= INIT_Y;
            x_cnt <= 11'd0;
            y_cnt <= 10'd0;
            de_d <= 1'b0;
            vs_d <= 1'b0;
            video_out <= 24'd0;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end else begin
            req_s0 <= cursor_req_toggle;
            req_s1 <= req_s0;
            online_s0 <= online_raw;
            online_s1 <= online_s0;
            if (req_s1 != cursor_ack_toggle) begin
                pending_x <= cursor_mailbox_x;
                pending_y <= cursor_mailbox_y;
                cursor_ack_toggle <= req_s1;
            end
            de_d <= de_in;
            vs_d <= vs_in;
            if (vs_rise) begin
                y_cnt <= 10'd0;
                frame_x <= pending_x;
                frame_y <= pending_y;
                online_frame <= online_s1;
            end else if (de_fall) y_cnt <= y_cnt + 10'd1;
            if (de_in) x_cnt <= x_cnt + 11'd1;
            else x_cnt <= 11'd0;
            video_out <= cursor_hit ? (cursor_edge ? 24'h101820 :
                                       24'hffffff) : video_in;
            de_out <= de_in;
            vs_out <= vs_in;
        end
    end
endmodule
