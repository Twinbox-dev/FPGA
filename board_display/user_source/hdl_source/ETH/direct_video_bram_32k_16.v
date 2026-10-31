module direct_video_bram_32k_16(
    input              wr_clk,
    input              wr_en,
    input      [10:0]  wr_addr,
    input      [15:0]  wr_data,
    input              rd_clk,
    input              rd_en,
    input      [10:0]  rd_addr,
    output reg [15:0]  rd_data
);
    // 2048 x 16 exactly fills one 32K-bit block.
    reg [15:0] mem [0:2047]; /* fehdl force_ram=1, ram_style="bram_32k" */

    always @(posedge wr_clk)
        if (wr_en) mem[wr_addr] <= wr_data;

    always @(posedge rd_clk)
        if (rd_en) rd_data <= mem[rd_addr];
endmodule
