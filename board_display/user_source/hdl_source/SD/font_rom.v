// Synchronous 8x16 printable-ASCII font ROM (95 glyphs, 2048 x 8 bits).
// The MEM_FILE parameter is relative to the synthesis/simulation working directory.
module font_rom #(
    parameter MEM_FILE = "../user_source/hdl_source/SD/font.mem"
)(
    input  wire        video_clk,
    input  wire [6:0]  ascii,        // 字符 ASCII 码（0~127）
    input  wire [3:0]  row,          // 字符内行号（0~15）
    output reg  [7:0]  row_data      // 该行 8bit 位图（读延迟 1 拍）
);

  reg [7:0] font_mem [0:2047];  /* fehdl force_ram=1, ram_style="bram" */

  initial $readmemh(MEM_FILE, font_mem);

  //同步读
  always @(posedge video_clk) begin
      row_data <= font_mem[{ascii, row}];
  end

endmodule
