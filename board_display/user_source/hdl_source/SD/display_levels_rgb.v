// Exact V2 contrast/brightness transfer, using spare native multipliers.
// Q2 gains: 2,3,4,5,6,7,8. Two remainder corrections preserve the original
// arithmetic-shift rounding (especially negative centered RGB values).
module display_levels_rgb(
    input wire [23:0] rgb,
    input wire [3:0] contrast,brightness,
    output wire [23:0] adjusted
);
    reg [3:0] coefficient;
    always @*case(contrast)
        0:coefficient=2;1:coefficient=3;2:coefficient=4;3:coefficient=5;
        4:coefficient=6;5:coefficient=7;6:coefficient=8;default:coefficient=4;
    endcase
    wire signed [10:0] base=$signed({3'd0,brightness,4'd0})+11'sd64;
    genvar ch;
    generate for(ch=0;ch<3;ch=ch+1)begin:g_channel
        wire [7:0] value=rgb[ch*8+:8];
        wire signed [7:0] centered={~value[7],value[6:0]};
        wire signed [12:0] product;
`ifdef VERILATOR
        assign product=centered*$signed({1'b0,coefficient});
`else
        wire [35:0] native_product;
        EG_PHY_MULT18 #(.MODE("MULT18X18C"),.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),
            .OUTPUTREG("DISABLE")) u_gain(
            .a({{10{centered[7]}},centered}),.b({14'd0,coefficient}),
            .acin(18'd0),.bcin(18'd0),.sourcea(1'b1),.sourceb(1'b1),
            .signeda(1'b1),.signedb(1'b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),
            .clk(1'b0),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),
            .acout(),.bcout(),.p(native_product));
        assign product=native_product[12:0];
`endif
        wire signed [10:0] correction=contrast==1 && value[1:0]!=0 ? 11'sd1 :
                                      (contrast==5 && value[1:0]==3 ? -11'sd1 : 11'sd0);
        wire signed [10:0] level=($signed(product)>>>2)+base+correction;
        assign adjusted[ch*8+:8]=level<0 ? 8'd0 : (level>255 ? 8'd255 : level[7:0]);
    end endgenerate
endmodule
