// Two 640-word line banks. The write and read ports use independent clocks.
module transition_line_buf (
    input  wire        mem_clk,
    input  wire        wr_en,
    input  wire        wr_bank,
    input  wire [9:0]  wr_addr,
    input  wire [31:0] wr_data,
    input  wire        video_clk,
    input  wire        rd_bank,
    input  wire [9:0]  rd_addr,
    output reg  [31:0] rd_data
);
    // Keep the RAM free of reset and separate from the control registers.
    reg [31:0] mem [0:2047]; /* fehdl force_ram=1, ram_style="bram" */

    always @(posedge mem_clk)
        if (wr_en)
            mem[{wr_bank, wr_addr}] <= wr_data;

    always @(posedge video_clk)
        rd_data <= mem[{rd_bank, rd_addr}];
endmodule
