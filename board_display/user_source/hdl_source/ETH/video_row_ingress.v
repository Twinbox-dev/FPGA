`timescale 1ns/1ps
// Two complete CRC-validated rows. Pixel RAM is not exposed across domains
// until the row descriptor is published; a bad row reuses its unpublished page.
module video_row_ingress #(parameter WIDTH=640,PAGES=2,LP=$clog2(PAGES),STATUS_ENABLED=1)(
 input wire app_clk,app_rst,row_begin,row_start,pixel_write,row_commit,row_reject,
 input wire [15:0] row_frame,row_sequence,pixel_data,crc_seed,crc_expected,
 input wire [8:0] row_index,input wire [9:0] pixel_index,
 output wire source_ready,output reg [31:0] accepted,rejected,
 input wire mem_clk,mem_rst,desc_pop,data_read,input wire [8:0] data_index,
 output wire desc_valid,output wire [15:0] desc_frame,desc_sequence,desc_seed,desc_crc,
 output wire [8:0] desc_row,output wire desc_start,output wire [31:0] data_out,output reg data_valid
);
 localparam WORDS=WIDTH/2;
 reg [LP:0] wb,wg,rb,rg,wgm,wgs,rgm,rgs;
 reg [15:0] frames[0:PAGES-1],sequences[0:PAGES-1],seeds[0:PAGES-1],crcs[0:PAGES-1];
 reg [8:0] rows[0:PAGES-1];reg starts[0:PAGES-1];
 function [LP:0] ungray(input [LP:0] g);
  integer i;begin ungray[LP]=g[LP];for(i=LP-1;i>=0;i=i-1)ungray[i]=ungray[i+1]^g[i];end
 endfunction
 wire [LP:0] used_rows=wb-ungray(rgs);
 wire full=used_rows==PAGES;
 assign source_ready=!full&&!app_rst;assign desc_valid=rb!=ungray(wgs);
 wire [LP-1:0] wp=wb[LP-1:0],rp=rb[LP-1:0];
 assign desc_frame=frames[rp];assign desc_sequence=sequences[rp];assign desc_seed=seeds[rp];assign desc_crc=crcs[rp];
 assign desc_row=rows[rp];assign desc_start=starts[rp];
 reg admitted;reg [15:0] low_pixel;reg write_q;reg [8:0] write_index;reg [31:0] word_q;reg [LP-1:0] write_page,read_page;
 wire [31:0] q[0:PAGES-1];
 genvar p;
 generate for(p=0;p<PAGES;p=p+1)begin:page_ram
  direct_video_bram_9k_16 lo(.wr_clk(app_clk),.wr_en(write_q&&write_page==p),.wr_addr(write_index),.wr_data(word_q[15:0]),
    .rd_clk(mem_clk),.rd_en(data_read&&desc_valid&&rp==p),.rd_addr(data_index),.rd_data(q[p][15:0]));
  direct_video_bram_9k_16 hi(.wr_clk(app_clk),.wr_en(write_q&&write_page==p),.wr_addr(write_index),.wr_data(word_q[31:16]),
    .rd_clk(mem_clk),.rd_en(data_read&&desc_valid&&rp==p),.rd_addr(data_index),.rd_data(q[p][31:16]));
 end endgenerate
 assign data_out=q[read_page];
 always @(posedge app_clk or posedge app_rst)begin
  if(app_rst)begin wb<=0;wg<=0;rgm<=0;rgs<=0;admitted<=0;low_pixel<=0;write_q<=0;write_index<=0;word_q<=0;write_page<=0;accepted<=0;rejected<=0;end
  else begin
   rgm<=rg;rgs<=rgm;write_q<=0;
   if(row_begin)begin
    admitted<=source_ready;
    if(source_ready)begin frames[wp]<=row_frame;sequences[wp]<=row_sequence;rows[wp]<=row_index;starts[wp]<=row_start;seeds[wp]<=crc_seed;end
   end
   if(pixel_write&&admitted&&pixel_index<WIDTH)begin
    if(!pixel_index[0])low_pixel<=pixel_data;
    else begin write_q<=1;word_q<={pixel_data,low_pixel};write_page<=wp;write_index<=pixel_index[9:1];end
   end
   if(row_commit||row_reject)begin
    admitted<=0;
    if(row_commit&&admitted)begin crcs[wp]<=crc_expected;wb<=wb+1'b1;wg<=(wb+1'b1)^((wb+1'b1)>>1);if(STATUS_ENABLED) accepted<=accepted+1'b1;end
    else if(STATUS_ENABLED) rejected<=rejected+1'b1;
   end
  end
 end
 always @(posedge mem_clk or posedge mem_rst)begin
  if(mem_rst)begin rb<=0;rg<=0;wgm<=0;wgs<=0;read_page<=0;data_valid<=0;end
  else begin
   wgm<=wg;wgs<=wgm;data_valid<=data_read&&desc_valid;
   if(data_read&&desc_valid)read_page<=rp;
   if(desc_pop&&desc_valid)begin rb<=rb+1'b1;rg<=(rb+1'b1)^((rb+1'b1)>>1);end
  end
 end
`ifdef VERILATOR
 initial if(PAGES<2 || (PAGES&(PAGES-1))!=0 || WIDTH%2!=0 || WIDTH>1024)$fatal(1,"ingress configuration invalid");
 always @(posedge app_clk)if(!app_rst && row_commit && admitted && (pixel_write||write_q))$fatal(1,"descriptor published before final RAM write drained");
`endif
endmodule
