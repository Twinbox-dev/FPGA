`timescale 1ns / 1ps
// FAT32 BMP selection, decode and RGB565 raw-stream probe.
module media_bmp_probe (
 input wire clk, input wire rst,
 input wire bmp_start, input wire bmp_next_req, input wire bmp_prev_req,
 output wire SD_nCS, output wire SD_DCLK, output wire SD_MOSI, input wire SD_MISO,
 output wire sd_init_done, output wire fat_mounted, output wire fat_error,
 output wire [5:0] file_count, output wire [5:0] bmp_count, output wire [5:0] wav_count,
 output wire [5:0] first_bmp, output wire [7:0] fat_state,
 output wire bmp_busy,
 output reg tap_val, output reg [31:0] tap_word, output reg tap_end
);
 wire [31:0] lba;
 wire sector_req, sector_ready, sector_valid, sector_done, sector_error;
 wire [7:0] sector_data;
 wire sd_sec_read, sd_sec_read_data_valid, sd_sec_read_end;
 wire [31:0] sd_sec_read_addr;
 wire [7:0] sd_sec_read_data;
 sd_card_top #(.SPI_LOW_SPEED_DIV(16'd248), .SPI_HIGH_SPEED_DIV(16'd0)) u_sd_card (
  .clk(clk), .rst(rst), .SD_nCS(SD_nCS), .SD_DCLK(SD_DCLK), .SD_MOSI(SD_MOSI),
  .SD_MISO(SD_MISO), .sd_init_done(sd_init_done), .sd_sec_read(sd_sec_read),
  .sd_sec_read_addr(sd_sec_read_addr), .sd_sec_read_data(sd_sec_read_data),
  .sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_end(sd_sec_read_end),
  .sd_sec_write(1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
  .sd_sec_write_data_req(), .sd_sec_write_end()
 );
 sd_adapter u_sd_adapter (
  .clk(clk), .rst(rst), .sd_init_done(sd_init_done), .o_lba(lba), .o_req(sector_req),
  .i_ready(sector_ready), .i_data(sector_data), .i_dval(sector_valid),
  .i_done(sector_done), .i_err(sector_error), .sd_sec_read(sd_sec_read),
  .sd_sec_read_addr(sd_sec_read_addr), .sd_sec_read_data(sd_sec_read_data),
  .sd_sec_read_data_valid(sd_sec_read_data_valid), .sd_sec_read_end(sd_sec_read_end)
 );
 wire [7:0] file_byte;
 wire file_bval, file_done, cur_is_wav, file_idle;
 wire [5:0] type_map;
 wire [191:0] bmp_next, bmp_prev;
 wire [63:0] pl_name;
 wire pl_is_wav, pl_valid;
 reg [4:0] file_idx, selected_idx;
 reg selected_valid;
 reg file_req, dec_restart, busy;
 assign bmp_busy = busy;
 wire [5:0] next_idx = bmp_next[6*selected_idx +: 6];
 wire [5:0] prev_idx = bmp_prev[6*selected_idx +: 6];
 wire [4:0] target_idx = bmp_next_req ? next_idx[4:0] :
                         bmp_prev_req ? prev_idx[4:0] : selected_idx;
 wire launch_req = (bmp_start || bmp_next_req || bmp_prev_req) &&
                   fat_mounted && selected_valid && (bmp_count != 6'd0) &&
                   file_idle && !busy;
 fat32_ro u_fat32 (
  .clk(clk), .rst_n(~rst), .o_lba(lba), .o_req(sector_req), .i_ready(sector_ready),
  .i_data(sector_data), .i_dval(sector_valid), .i_done(sector_done), .i_err(sector_error),
  .o_byte(file_byte), .o_bval(file_bval), .o_file_done(file_done),
  .i_file_idx(file_idx), .i_file_req(file_req), .o_mounted(fat_mounted),
  .o_file_cnt(file_count), .o_bmp_cnt(bmp_count), .o_wav_cnt(wav_count),
  .o_type_map(type_map), .o_first_bmp(first_bmp), .o_bmp_nxt(bmp_next),
  .o_bmp_prv(bmp_prev), .o_err(fat_error), .o_cur_is_wav(cur_is_wav),
  .o_file_idle(file_idle), .o_dbg_state(fat_state), .i_pl_idx(5'd0),
  .o_pl_name(pl_name), .o_pl_is_wav(pl_is_wav), .o_pl_valid(pl_valid)
 );
 wire pix_val, hdr_ok, img_ok, img_err;
 wire [23:0] pix;
 wire [11:0] img_w, img_h;
 wire [7:0] dec_state;
 bmp_dec u_bmp_dec (
  .clk(clk), .rst_n(~rst), .i_byte(file_byte), .i_bval(file_bval),
  .i_restart(dec_restart), .o_pix_val(pix_val), .o_pix(pix),
  .o_img_w(img_w), .o_img_h(img_h), .o_hdr_ok(hdr_ok),
  .o_img_ok(img_ok), .o_img_err(img_err), .o_dbg_state(dec_state)
 );
 reg img_ok_d, have_pixel;
 reg [15:0] pixel_low;
 wire [15:0] pixel_565={pix[23:19],pix[15:10],pix[7:3]};
 always @(posedge clk) begin
  if (rst) begin
   file_idx<=0; selected_idx<=0; selected_valid<=0;
   file_req<=0; dec_restart<=0; busy<=0; img_ok_d<=0;
   have_pixel<=0; pixel_low<=0; tap_val<=0; tap_word<=0; tap_end<=0;
  end else begin
   file_req<=0; dec_restart<=0; tap_val<=0; tap_end<=0; img_ok_d<=img_ok;
   if (fat_mounted && !selected_valid && bmp_count != 6'd0) begin
    selected_idx<=first_bmp[4:0];
    selected_valid<=1;
   end
   if (launch_req) begin
    selected_idx<=target_idx;
    file_idx<=target_idx;
    file_req<=1;
    dec_restart<=1;
    have_pixel<=0;
    busy<=1;
   end
   if (pix_val) begin
    if (!have_pixel) begin pixel_low<=pixel_565; have_pixel<=1; end
    else begin tap_word<={pixel_565,pixel_low}; tap_val<=1; have_pixel<=0; end
   end
   // bmp_dec raises pix_val and img_ok together for the final pixel.
   // Preserve the just-formed pair; only pad when the total pixel count is odd.
   if (img_ok && !img_ok_d) begin
    if (pix_val) begin
     if (!have_pixel) begin
      tap_word<={16'h0000,pixel_565}; tap_val<=1; have_pixel<=0;
     end
    end else if (have_pixel) begin
     tap_word<={16'h0000,pixel_low}; tap_val<=1; have_pixel<=0;
    end
    tap_end<=1;
   end
   if (file_done || fat_error) busy<=0;
  end
 end
 wire _unused=&{1'b0,type_map,cur_is_wav,pl_name,
                pl_is_wav,pl_valid,hdr_ok,img_err,img_w,img_h,dec_state};
endmodule
