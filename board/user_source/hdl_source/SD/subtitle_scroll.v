// Move a variable-length ASCII caption from right to left at two pixels/frame.
module subtitle_scroll #(
    parameter signed [11:0] X_START = 12'sd1280,
    parameter [9:0] Y_TOP = 10'd504,
    parameter signed [11:0] STEP = 12'sd2
)(
    input  wire               video_clk,
    input  wire               rst,
    input  wire               vs,
    input  wire               text_changed_pulse,
    input  wire [7:0]         text_len,
    output reg  signed [11:0] ox,
    output wire [9:0]         oy
);
    reg vs_d;
    wire vs_rise = vs && !vs_d;
    wire signed [11:0] x_end = -$signed({1'b0, text_len, 3'b000});
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
