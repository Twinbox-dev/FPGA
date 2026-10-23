// Move a variable-length ASCII caption from right to left at two pixels/frame.
module subtitle_scroll #(
    parameter signed [12:0] X_START = 13'sd1280,
    parameter [9:0] Y_TOP = 10'd480,
    parameter signed [12:0] STEP = 13'sd2
)(
    input  wire               video_clk,
    input  wire               rst,
    input  wire               vs,
    input  wire               text_changed_pulse,
    input  wire [7:0]         text_len,
    output reg  signed [12:0] ox,
    output wire [9:0]         oy
);
    reg vs_d;
    wire vs_rise = vs && !vs_d;
    // 160 doubled 16-pixel cells reach -2560, beyond a signed 12-bit offset.
    wire signed [12:0] x_end = -$signed({1'b0, text_len, 4'b0000});
    assign oy = Y_TOP;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d <= 1'b0;
            ox <= X_START;
        end else begin
            vs_d <= vs;
            if (text_changed_pulse || text_len == 8'd0)
                ox <= X_START;
            else if (vs_rise)
                ox <= (ox <= x_end) ? X_START : (ox - STEP);
        end
    end
endmodule
