`timescale 1ns/1ps

// Small independent ingress queues for USB UART and HC-08.  The consumer
// asserts cmd_ready only when the shared command core can accept one byte.
// Each source has four entries so a busy display-control transaction cannot
// silently discard short command bursts.  Overflow counters are sticky/saturating
// diagnostic evidence; command payload and protocol remain unchanged.
module media_uart_arbiter #(
    parameter integer DEPTH = 4
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] usb_cmd,
    input  wire       usb_valid,
    input  wire [7:0] bt_cmd,
    input  wire       bt_valid,
    input  wire [1:0] source_lock, // 0=fair, 1=USB only, 2=BT only, 3=pause UART
    output wire [7:0] cmd,
    output wire [1:0] cmd_source, // 1=USB UART, 2=HC-08
    output wire       cmd_valid,
    input  wire       cmd_ready,
    output reg  [7:0] usb_overflow_count,
    output reg  [7:0] bt_overflow_count,
    input wire view_busy,
    output wire cmd_was_busy
);
    reg [7:0] usb_fifo [0:DEPTH-1];
    reg [7:0] bt_fifo  [0:DEPTH-1];
    reg [1:0] usb_wr_ptr,usb_rd_ptr,bt_wr_ptr,bt_rd_ptr;
    reg [2:0] usb_count,bt_count;
    reg prefer_bt;
    reg usb_busy_fifo[0:DEPTH-1],bt_busy_fifo[0:DEPTH-1];

    wire choose_bt=(source_lock==2'd2) ||
                   ((source_lock==2'd0) && (bt_count!=0) && ((usb_count==0)||prefer_bt));
    assign cmd_valid=(source_lock==2'd3) ? 1'b0 :
                     (source_lock==2'd1) ? (usb_count!=0) :
                     (source_lock==2'd2) ? (bt_count!=0) : ((usb_count!=0)||(bt_count!=0));
    assign cmd=choose_bt?bt_fifo[bt_rd_ptr]:usb_fifo[usb_rd_ptr];
    assign cmd_source=choose_bt?2'd2:2'd1;
    assign cmd_was_busy=choose_bt ? bt_busy_fifo[bt_rd_ptr] : usb_busy_fifo[usb_rd_ptr];
    wire pop=cmd_valid && cmd_ready;
    wire usb_pop=pop && !choose_bt;
    wire bt_pop=pop && choose_bt;
    wire usb_push=usb_valid && ((usb_count<DEPTH)||usb_pop);
    wire bt_push=bt_valid && ((bt_count<DEPTH)||bt_pop);

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            usb_wr_ptr<=0;usb_rd_ptr<=0;bt_wr_ptr<=0;bt_rd_ptr<=0;
            usb_count<=0;bt_count<=0;prefer_bt<=0;
            usb_overflow_count<=0;bt_overflow_count<=0;
        end else begin
            if(usb_push)begin usb_fifo[usb_wr_ptr]<=usb_cmd;usb_busy_fifo[usb_wr_ptr]<=view_busy;usb_wr_ptr<=usb_wr_ptr+1'b1;end
            if(bt_push)begin bt_fifo[bt_wr_ptr]<=bt_cmd;bt_busy_fifo[bt_wr_ptr]<=view_busy;bt_wr_ptr<=bt_wr_ptr+1'b1;end
            if(usb_pop)usb_rd_ptr<=usb_rd_ptr+1'b1;
            if(bt_pop)bt_rd_ptr<=bt_rd_ptr+1'b1;
            case({usb_push,usb_pop})
                2'b10:usb_count<=usb_count+1'b1;
                2'b01:usb_count<=usb_count-1'b1;
                default:usb_count<=usb_count;
            endcase
            case({bt_push,bt_pop})
                2'b10:bt_count<=bt_count+1'b1;
                2'b01:bt_count<=bt_count-1'b1;
                default:bt_count<=bt_count;
            endcase
            if(pop)prefer_bt<=!choose_bt;
            if(usb_valid && !usb_push && usb_overflow_count!=8'hFF)
                usb_overflow_count<=usb_overflow_count+1'b1;
            if(bt_valid && !bt_push && bt_overflow_count!=8'hFF)
                bt_overflow_count<=bt_overflow_count+1'b1;
        end
    end
endmodule
