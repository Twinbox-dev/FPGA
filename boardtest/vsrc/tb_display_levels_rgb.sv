`timescale 1ns/1ps
module tb_display_levels_rgb;
    reg [23:0] rgb=0;
    reg [3:0] contrast=0,brightness=0;
    wire [23:0] result;
    display_levels_rgb dut(.rgb(rgb),.contrast(contrast),.brightness(brightness),.adjusted(result));
    function automatic [7:0] golden(input integer c,lv,bri);
        integer d,r,t;
        begin
            d=c-128;
            case(lv)
                0:r=d>>>1;1:r=d-(d>>>2);2:r=d;3:r=d+(d>>>2);
                4:r=d+(d>>>1);5:r=d+(d>>>1)+(d>>>2);6:r=d<<<1;default:r=d;
            endcase
            t=r+128+(bri-4)*16;
            golden=t<0 ? 0 : (t>255 ? 255 : t);
        end
    endfunction
    integer c,lv,bri;
    initial begin
        for(lv=0;lv<16;lv=lv+1)for(bri=0;bri<16;bri=bri+1)for(c=0;c<256;c=c+1)begin
            rgb={8'(c),8'(255-c),8'(c^8'h55)};contrast=lv;brightness=bri;#1;
            if(result!=={golden(c,lv,bri),golden(255-c,lv,bri),golden(c^8'h55,lv,bri)})
                $fatal(1,"level transfer changed RGB=%h ct=%0d bri=%0d got=%h",rgb,lv,bri,result);
        end
        $display("PASS: exact legacy RGB levels for every 256 input / 16 contrast / 16 brightness value");$finish;
    end
endmodule
