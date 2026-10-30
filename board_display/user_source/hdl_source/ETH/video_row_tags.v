`timescale 1ns/1ps
// Tags plus CRC seed/expected share one synchronous native RAM table.
// A committed tag includes a
// valid bit, session stamp and extended row number; no wide dynamic FF bitmap.
module video_row_tags #(parameter WIDTH=64)(input wire clk,write_en,read_en,input wire [8:0] write_address,read_address,
 input wire [WIDTH-1:0] write_tag,output wire [WIDTH-1:0] read_tag);
 genvar k;
 generate for(k=0;k<WIDTH/16;k=k+1)begin:g
  direct_video_bram_9k_16 ram(.wr_clk(clk),.wr_en(write_en),.wr_addr(write_address),.wr_data(write_tag[k*16+:16]),
    .rd_clk(clk),.rd_en(read_en),.rd_addr(read_address),.rd_data(read_tag[k*16+:16]));
 end endgenerate
endmodule
