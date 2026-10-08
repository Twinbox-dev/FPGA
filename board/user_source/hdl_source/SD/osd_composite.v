// Renderers register their masks from the current video pixel. Delay RGB and
// timing by one clock to match those masks, then register the composited pixel.
// Both bands are fixed half-opacity black; no DSP multipliers are needed.
module osd_composite (
    input  wire        video_clk,
    input  wire        rst,
    input  wire [23:0] video_in,
    input  wire        de_in,
    input  wire        vs_in,
    input  wire        panel_show,
    input  wire        panel_text_on,
    input  wire        panel_band,
    input  wire        subtitle_text_on,
    input  wire        subtitle_band,
    output reg  [23:0] video_out,
    output reg         de_out,
    output reg         vs_out
);
    reg [23:0] video_d;
    reg de_d, vs_d;
    wire text_on = subtitle_text_on || (panel_show && panel_text_on);
    wire band_on = subtitle_band || (panel_show && panel_band);
    wire [23:0] shaded = {1'b0, video_d[23:17],
                          1'b0, video_d[15:9],
                          1'b0, video_d[7:1]};
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            video_d <= 24'd0;
            de_d <= 1'b0;
            vs_d <= 1'b0;
            video_out <= 24'd0;
            de_out <= 1'b0;
            vs_out <= 1'b0;
        end else begin
            video_d <= video_in;
            de_d <= de_in;
            vs_d <= vs_in;
            video_out <= text_on ? 24'hffffff :
                         band_on ? shaded : video_d;
            de_out <= de_d;
            vs_out <= vs_d;
        end
    end
endmodule
