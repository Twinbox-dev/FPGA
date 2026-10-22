`timescale 1ns/1ps
module tb_media_tx_mux_lifetime;
    reg clk=0,rst=1,ready=0,ack=0;
    always #4 clk=~clk;
    reg cr=0,cv=0,mr=0,mv=0;
    reg [15:0] cl=0,ml=0;
    wire ca,ma,sr,sv;
    wire [7:0] data;
    wire [15:0] length;
    media_tx_mux dut(.clk(clk),.rst(rst),.stack_ready(ready),.stack_ack(ack),
        .ctrl_req(cr),.ctrl_valid(cv),.ctrl_data(8'hc1),.ctrl_length(cl),.ctrl_ready(),.ctrl_ack(ca),
        .chunk_req(mr),.chunk_valid(mv),.chunk_data(8'hd2),.chunk_length(ml),
        .chunk_ready(),.chunk_ack(ma),.chunk_active(),.chunk_owner(),.stack_req(sr),.stack_valid(sv),
        .stack_data(data),.stack_length(length));
    integer i;
    initial begin
        repeat(5)@(negedge clk);rst=0;ready=1;cr=1;
        wait(sr);@(negedge clk);ack=1;
        wait(ca);@(negedge clk);cl=16;cr=0;ack=0;cv=1;
        repeat(16)@(negedge clk);
        cv=0;cl=0;ready=0;mr=1;ml=11;
        repeat(6)begin
            @(negedge clk);
            if(length!=16)$fatal(1,"previous UDP length changed before stack-ready: got%0d expected16",length);
        end
        ready=1;wait(sr);@(negedge clk);ack=1;
        wait(ma);@(negedge clk);mr=0;ack=0;mv=1;
        repeat(11)@(negedge clk);
        mv=0;ml=72;ready=0;
        repeat(6)begin
            @(negedge clk);
            if(length!=11)$fatal(1,"formal reply length changed after final app byte: got%0d expected11",length);
        end
        $display("PASS: control length published at ACK and both lengths held through downstream UDP drain");
        $finish;
    end
    initial begin #10000;$fatal(1,"mux lifetime timeout");end
endmodule
