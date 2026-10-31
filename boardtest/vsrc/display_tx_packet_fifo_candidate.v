`timescale 1ns/1ps
// Experimental single-packet mailbox for the display's short reply frames.
// Native dual-clock RAM keeps the payload stable until the MAC finishes it.
module display_tx_packet_fifo #(
    parameter MAX_BYTES=128
)(
    input wire rd_clk,rd_sreset,rd_enable,
    output reg [7:0] tx_data,output reg tx_data_valid,
    input wire tx_ack,tx_collision,tx_retransmit,
    output reg overflow,
    input wire wr_clk,wr_sreset,input wire [7:0] wr_data,
    input wire wr_sof_n,wr_eof_n,wr_src_rdy_n,
    output wire wr_dst_rdy_n,output wire [3:0] wr_fifo_status
);
    reg request_toggle;
    reg [7:0] packet_length;
    reg [7:0] write_count;
    reg dropping;
    reg [1:0] done_sync;
    reg done_toggle;
    wire pending=request_toggle!=done_sync[1];
    assign wr_dst_rdy_n=pending;
    assign wr_fifo_status=pending ? 4'hf : 4'h0;
    wire take=!wr_src_rdy_n&&!wr_dst_rdy_n;
    wire store=take&&!dropping&&write_count<MAX_BYTES;
    wire [15:0] ram_data;
    reg [7:0] read_address;
    direct_video_bram_9k_16 payload(
        .wr_clk(wr_clk),.wr_en(store),.wr_addr({1'b0,write_count}),.wr_data({8'd0,wr_data}),
        .rd_clk(rd_clk),.rd_en(rd_enable),.rd_addr({1'b0,read_address}),.rd_data(ram_data));
    always @(posedge wr_clk)begin
        if(wr_sreset)begin
            request_toggle<=0;packet_length<=0;write_count<=0;dropping<=0;done_sync<=0;overflow<=0;
        end else begin
            done_sync<={done_sync[0],done_toggle};
            if(take)begin
                if(write_count==0&&wr_sof_n)begin dropping<=1;overflow<=1;end
                if(write_count>=MAX_BYTES)begin dropping<=1;overflow<=1;end
                if(!wr_eof_n)begin
                    if(!dropping&&write_count<MAX_BYTES&&!(write_count==0&&wr_sof_n))begin
                        packet_length<=write_count+1'b1;request_toggle<=~request_toggle;
                    end
                    write_count<=0;dropping<=0;
                end else if(write_count!=255)write_count<=write_count+1'b1;
            end
        end
    end
    localparam IDLE=0,PRIME0=1,PRIME1=2,PRIME2=3,WAIT_ACK=4,SEND=5;
    reg [2:0] state;
    reg [1:0] request_sync;
    reg [7:0] length_held,current_index,prefetch;
    always @(posedge rd_clk)begin
        if(rd_sreset)begin
            state<=IDLE;request_sync<=0;done_toggle<=0;read_address<=0;
            length_held<=0;current_index<=0;prefetch<=0;tx_data<=0;tx_data_valid<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            if(rd_enable)case(state)
                IDLE:begin
                    tx_data_valid<=0;
                    if(request_sync[1]!=done_toggle)begin
                        length_held<=packet_length;read_address<=0;state<=PRIME0;
                    end
                end
                PRIME0:begin read_address<=1;state<=PRIME1;end
                PRIME1:begin tx_data<=ram_data[7:0];read_address<=2;state<=PRIME2;end
                PRIME2:begin prefetch<=ram_data[7:0];tx_data_valid<=1;state<=WAIT_ACK;end
                WAIT_ACK:if(tx_ack)begin
                    if(length_held==1)begin tx_data_valid<=0;done_toggle<=request_sync[1];state<=IDLE;end
                    else begin tx_data<=prefetch;current_index<=1;read_address<=3;state<=SEND;end
                end
                SEND:if(current_index+9'd1>=length_held)begin
                    tx_data_valid<=0;done_toggle<=request_sync[1];state<=IDLE;
                end else begin
                    tx_data<=ram_data[7:0];current_index<=current_index+1'b1;read_address<=read_address+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
`ifdef VERILATOR
    initial if(MAX_BYTES<1||MAX_BYTES>128)$fatal(1,"display packet FIFO capacity must be 1..128");
    always @(posedge rd_clk)if(!rd_sreset&&(tx_collision||tx_retransmit))$fatal(1,"display packet FIFO requires full-duplex MAC");
`endif
endmodule
