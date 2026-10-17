// HDMI-only 64x64 Ganyu cursor, after OSD. The source's 8x8 pixel blocks
// become a 32x32 ROM; each ROM pixel is shown as 2x2 HDMI pixels. This keeps
// the exact 64x64 image while using only one 32k BRAM.
// The synchronous sprite ROM adds
// one cycle to the old overlay; RGB/DE/VS all travel through the same two
// stages. Pointer position is committed once per video frame.
module gt911_cursor_overlay #(
    parameter [10:0] INIT_X = 11'd640,
    parameter [9:0] INIT_Y = 10'd360,
    parameter MEM_FILE = "gt911_ganyu_cursor.mem"
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
    wire in_box = online_frame && de_in &&
                  (x_cnt >= frame_x) && (y_cnt >= frame_y) &&
                  (rel_x < 11'd64) && (rel_y < 10'd64);
    wire [9:0] sprite_addr = {rel_y[5:1], rel_x[5:1]};
    reg [15:0] sprite_mem [0:1023]; /* fehdl force_ram=1, ram_style="bram_32k" */
    reg [15:0] sprite_word;
    initial $readmemh(MEM_FILE, sprite_mem);
    always @(posedge video_clk)
        sprite_word <= sprite_mem[sprite_addr];

    reg [23:0] rgb_d;
    reg de_pipe, vs_pipe, hit_pipe;
    wire [23:0] sprite_rgb = {sprite_word[15:11], sprite_word[15:13],
                              sprite_word[10:5], sprite_word[10:9],
                              sprite_word[4:0], sprite_word[4:2]};
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
            rgb_d <= 24'd0;
            de_pipe <= 1'b0;
            vs_pipe <= 1'b0;
            hit_pipe <= 1'b0;
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
            rgb_d <= video_in;
            de_pipe <= de_in;
            vs_pipe <= vs_in;
            hit_pipe <= in_box;
            video_out <= (hit_pipe && sprite_word != 16'd0) ? sprite_rgb : rgb_d;
            de_out <= de_pipe;
            vs_out <= vs_pipe;
        end
    end
endmodule
