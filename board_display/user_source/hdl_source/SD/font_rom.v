// Shared synchronous font storage for two independent raster consumers.
// The OSD panel and subtitle renderer use the same font.mem and video clock,
// so a true dual-read-port RAM preserves both one-cycle read latencies while
// avoiding two copies of the 2048 x 8 bitmap.
module font_rom_2r #(
    // TD first resolves readmemh paths beside this source file. A basename
    // works for both GUI project builds and CLI syn_1 working directories.
    parameter MEM_FILE = "font.mem"
)(
    input  wire        video_clk,
    input  wire [6:0]  ascii_a,
    input  wire [3:0]  row_a,
    output reg  [7:0]  row_data_a,
    input  wire [6:0]  ascii_b,
    input  wire [3:0]  row_b,
    output reg  [7:0]  row_data_b
);
    reg [7:0] font_mem [0:2047]; /* fehdl force_ram=1, ram_style="bram_32k" */

    initial $readmemh(MEM_FILE, font_mem);

    always @(posedge video_clk) begin
        row_data_a <= font_mem[{ascii_a, row_a}];
        row_data_b <= font_mem[{ascii_b, row_b}];
    end
endmodule
