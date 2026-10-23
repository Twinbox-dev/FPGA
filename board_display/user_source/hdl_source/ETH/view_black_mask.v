`timescale 1ns/1ps
// Apply after global CV/brightness, before UI overlays, so hidden slots stay
// black even with positive brightness or a nonzero neighborhood filter result.
module view_black_mask(
    input wire clk,rst,de,vs,
    input wire [1:0] layout,
    input wire [3:0] valid_mask,
    output wire black
);
    reg de_d;
    reg [10:0] x;
    reg [9:0] y;
    wire [1:0] window=layout==0 ? 2'd0 : (layout==1 ? {1'b0,x>=640} : {y>=360,x>=640});
    assign black=!valid_mask[window];
    always @(posedge clk or posedge rst)begin
        if(rst)begin de_d<=0;x<=0;y<=0;end
        else begin
            de_d<=de;
            if(de)x<=x+1'b1;else x<=0;
            if(vs)y<=0;else if(de_d && !de)y<=y+1'b1;
        end
    end
endmodule
