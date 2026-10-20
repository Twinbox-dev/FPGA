// Two 512-sample PCM windows. Deliberately isolate each BRAM's synchronous
// read/write ports from reset and DFT control logic, like transition_line_buf.
module spectrum_sample_buf (
    input  wire               clk,
    input  wire               wr_en,
    input  wire [9:0]         wr_addr,
    input  wire signed [23:0] wr_data,
    input  wire [9:0]         rd_addr,
    output wire signed [23:0] rd_data
);
    reg [15:0] sample_hi [0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [7:0]  sample_lo [0:1023]; /* fehdl force_ram=1, ram_style="bram" */
    reg [15:0] hi_q;
    reg [7:0]  lo_q;

    always @(posedge clk)
        if (wr_en)
            sample_hi[wr_addr] <= wr_data[23:8];
    always @(posedge clk)
        if (wr_en)
            sample_lo[wr_addr] <= wr_data[7:0];
    always @(posedge clk)
        hi_q <= sample_hi[rd_addr];
    always @(posedge clk)
        lo_q <= sample_lo[rd_addr];

    assign rd_data = {hi_q, lo_q};
endmodule
