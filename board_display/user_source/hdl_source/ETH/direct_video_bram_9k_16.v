module direct_video_bram_9k_16(
    input              wr_clk,
    input              wr_en,
    input      [8:0]   wr_addr,
    input      [15:0]  wr_data,
    input              rd_clk,
    input              rd_en,
    input      [8:0]   rd_addr,
    output reg [15:0]  rd_data
);
    // 512 x 16 uses 8192 payload bits in one 9K block.
    reg [15:0] mem [0:511]; /* fehdl force_ram=1, ram_style="bram_9k" */

    always @(posedge wr_clk)
        if (wr_en) mem[wr_addr] <= wr_data;

    always @(posedge rd_clk)
        if (rd_en) rd_data <= mem[rd_addr];
endmodule
