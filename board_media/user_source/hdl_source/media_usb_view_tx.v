// Non-interleaving USB UART packet arbiter: legacy 8-byte control replies and
// A7 + 16-byte authoritative view state. Latest state is bounded/coalesced.
module media_usb_view_tx(
    input wire clk,rst,physical_ready,
    input wire control_request,
    input wire [63:0] control_packet,
    output wire control_ready,
    input wire view_valid,
    input wire [127:0] view_body,
    output reg tx_request,
    output reg [135:0] tx_packet,
    output reg [4:0] tx_count
);
    reg pending;
    reg [127:0] pending_body;
    reg [1:0] quiet;
    // Revoke a control grant two cycles before starting an unsolicited view
    // packet: the core registers its request one cycle after observing ready.
    assign control_ready=physical_ready && !pending && quiet==0 && !tx_request;
    always @(posedge clk)begin
        if(rst)begin pending<=0;pending_body<=0;quiet<=0;tx_request<=0;tx_packet<=0;tx_count<=8;end
        else begin
            tx_request<=0;
            if(!physical_ready || tx_request)quiet<=0;
            else if(control_request)begin
                tx_request<=1;tx_packet<={72'd0,control_packet};tx_count<=8;quiet<=0;
            end else if(pending)begin
                if(quiet==2)begin
                    tx_request<=1;tx_packet<={pending_body,8'ha7};tx_count<=17;quiet<=0;pending<=0;
                end else quiet<=quiet+1'b1;
            end else quiet<=0;
            if(view_valid)begin pending<=1;pending_body<=view_body;end
        end
    end
endmodule
