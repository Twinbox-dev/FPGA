`timescale 1ns/1ps
// Isolated acceptance builds only. V1 type 004B / length 4 supplies LE x,y to
// the view manager, allowing unattended tests to select every window. It does
// not replace or enter the product GT911/cursor renderer or source-file list.
module display_test_cursor(
    input wire clk,rst,
    input wire [7:0] data,
    input wire valid,
    output reg enabled,
    output reg [10:0] x,
    output reg [9:0] y
);
    reg [4:0] position;
    reg [15:0] kind,length,px,py;
    reg good;
    always @(posedge clk or posedge rst)begin
        if(rst)begin position<=0;kind<=0;length<=0;px<=0;py<=0;
            good<=0;enabled<=0;x<=640;y<=360;end
        else if(valid)begin
            if(position!=31)position<=position+1'b1;else good<=0;
            case(position)
                0:good<=data==8'haa;1:good<=good && data==8'hbb;
                2:good<=good && data==8'hcc;3:good<=good && data==8'hdd;
                4:kind[15:8]<=data;5:kind[7:0]<=data;
                6:length[15:8]<=data;7:length[7:0]<=data;
                8:px[7:0]<=data;9:px[15:8]<=data;
                10:py[7:0]<=data;11:py[15:8]<=data;
            endcase
        end else begin
            if(good && kind==16'h004b && length==4 && position==12 && px<1280 && py<720)begin
                enabled<=1;x<=px[10:0];y<=py[9:0];
            end
            position<=0;
        end
    end
endmodule
