`timescale 1ns/1ps
module tb_snow_field;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,frame_tick=0;
    reg [10:0] x=0;reg [9:0] y=0;wire hit;
    cv_snow_field dut(.clk(clk),.rst(rst),.frame_tick(frame_tick),.x(x),.y(y),.hit(hit));
    reg old_hit[0:921599];
    reg [12:0] crystal[0:12];
    integer px,py,total0,total16,moved,f,fd;string ppm;
    task automatic shape(input integer left,input integer top);
        integer cx,cy;
        begin
            for(cy=0;cy<13;cy=cy+1)for(cx=0;cx<13;cx=cx+1)begin
                x=left+cx;y=top+cy;#1;
                if(hit!==crystal[cy][12-cx])$fatal(1,"crystal shape at %0d,%0d got=%b",left+cx,top+cy,hit);
            end
        end
    endtask
    initial begin
        crystal[0]=13'h0040;crystal[1]=13'h0040;crystal[2]=13'h05F4;
        crystal[3]=13'h0248;crystal[4]=13'h0554;crystal[5]=13'h00E0;
        crystal[6]=13'h0040;crystal[7]=13'h00E0;crystal[8]=13'h0554;
        crystal[9]=13'h0248;crystal[10]=13'h05F4;crystal[11]=13'h0040;crystal[12]=13'h0040;
        repeat(3)@(negedge clk);rst=0;shape(0,0);
        fd=0;if($value$plusargs("PPM=%s",ppm))begin fd=$fopen(ppm,"wb");$fwrite(fd,"P6\n1280 720\n255\n");end
        total0=0;
        for(py=0;py<720;py=py+1)for(px=0;px<1280;px=px+1)begin
            x=px;y=py;#1;old_hit[py*1280+px]=hit;if(hit)total0=total0+1;
            if(fd)begin
                if(hit)$fwrite(fd,"%c%c%c",255,255,255);
                else $fwrite(fd,"%c%c%c",20+px/12,32+py/9,72+py/6);
            end
        end
        if(fd)$fclose(fd);
        for(f=0;f<16;f=f+1)begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;end
        shape(1,32);
        total16=0;moved=0;
        for(py=0;py<720;py=py+1)for(px=0;px<1280;px=px+1)begin
            x=px;y=py;#1;if(hit)total16=total16+1;if(hit!=old_hit[py*1280+px])moved=moved+1;
        end
        if(total0<2000 || total0>20000 || total16<2000 || total16>20000 || moved<2000)
            $fatal(1,"snow density/motion: %0d -> %0d moved=%0d",total0,total16,moved);
        $display("PASS snow: six-arm sprite, full 720p density %0d/%0d, fall+wind changed %0d pixels",total0,total16,moved);$finish;
    end
endmodule
