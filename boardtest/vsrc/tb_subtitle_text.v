`timescale 1ns/1ps
module tb_subtitle_text;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,de=0,vs=0;
    reg signed [12:0] ox=13'sd8;
    reg [7:0] len=3,char_data;
    wire [7:0] char_index;
    wire [6:0] font_ascii;
    wire [3:0] font_row;
    wire [7:0] font_row_data;
    wire text_on,in_band;
    wire [23:0] text_rgb;
    reg [7:0] font_mem[0:2047];
    subtitle_text_renderer dut(.video_clk(clk),.rst(rst),.de(de),.vs(vs),
        .ox(ox),.oy(10'd0),.text_len(len),.char_index(char_index),.char_data(char_data),
        .font_ascii(font_ascii),.font_row(font_row),.font_row_data(font_row_data),
        .text_on(text_on),.text_rgb(text_rgb),.in_band(in_band));
    font_rom_2r #(.MEM_FILE("../board_display/user_source/hdl_source/SD/font.mem")) font(
        .video_clk(clk),.ascii_a(font_ascii),.row_a(font_row),.row_data_a(font_row_data),
        .ascii_b(7'd0),.row_b(4'd0),.row_data_b());
    always @(posedge clk)char_data <= 8'd65+(char_index%26);
    function [23:0] palette(input integer col);
        case(col%4)
            0:palette=24'h6EE7F9;1:palette=24'hC4B5FD;
            2:palette=24'hFFADD2;default:palette=24'hA7F3D0;
        endcase
    endfunction
    task automatic scene(input integer origin,input integer length_value);
        integer x,y,rx,col,lit;reg expected;reg [7:0] glyph;
        begin
            @(negedge clk);rst=1;de=0;vs=0;ox=origin;len=length_value;
            repeat(4)@(negedge clk);rst=0;vs=1;
            @(negedge clk);vs=0;repeat(6)@(negedge clk);lit=0;
            for(y=0;y<34;y=y+1)begin
                de=1;
                for(x=0;x<96;x=x+1)begin
                    @(negedge clk);rx=x-origin;expected=0;col=rx/16;
                    if(rx>=0 && rx<length_value*16 && y<32)begin
                        glyph=font_mem[(65+col%26)*16+y/2];
                        expected=glyph[7-((rx%16)/2)];
                    end
                    if(text_on!==expected)$fatal(1,"subtitle pixel x=%0d y=%0d ox=%0d got=%b exp=%b",x,y,origin,text_on,expected);
                    if(expected)begin
                        lit=lit+1;
                        if(text_rgb!==palette(col))$fatal(1,"subtitle palette col=%0d got=%h",col,text_rgb);
                    end
                end
                de=0;repeat(6)@(negedge clk);
            end
            if(origin>-2560 && lit==0)$fatal(1,"expected visible glyphs at ox=%0d",origin);
            if(origin==-2560 && lit!=0)$fatal(1,"text still visible after leaving screen");
        end
    endtask
    initial begin
        $readmemh("../board_display/user_source/hdl_source/SD/font.mem",font_mem);
        scene(8,3);scene(0,3);scene(-3,3);scene(-17,160);scene(-2544,160);scene(-2560,160);
        $display("PASS subtitle: exact 2x glyphs/colors, left clipping, 160-char tail and blanking prefetch");$finish;
    end
endmodule
