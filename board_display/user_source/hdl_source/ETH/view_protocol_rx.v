`timescale 1ns/1ps
// V1 big-endian envelope; PREPARE body and its generation are little-endian.
// 49 body: seq, action, layout, preferred-window, generation:u16, reserved:u16.
module view_protocol_rx(
    input wire clk,rst,
    input wire [7:0] data,
    input wire valid,
    output reg prepare_valid,status_request,
    output wire [63:0] prepare_body
);
    reg [4:0] position;
    reg good,kind_high_ok,length_high_ok,length_ok,is_prepare,is_status;
    reg [63:0] body;
    // Consumed on the valid pulse before any later packet can reach byte 8;
    // retaining a second 64-bit body register adds no handshake protection.
    assign prepare_body=body;
    always @(posedge clk or posedge rst)begin
        if(rst)begin position<=0;good<=0;body<=0;kind_high_ok<=0;
            length_high_ok<=0;length_ok<=0;is_prepare<=0;is_status<=0;
            prepare_valid<=0;status_request<=0;end
        else begin
            prepare_valid<=0;status_request<=0;
            if(valid)begin
                if(position!=31)position<=position+1'b1;else good<=0;
                case(position)
                    0:good<=data==8'haa;
                    1:good<=good && data==8'hbb;
                    2:good<=good && data==8'hcc;
                    3:good<=good && data==8'hdd;
                    4:kind_high_ok<=data==0;
                    5:begin is_prepare<=kind_high_ok && data==8'h49;
                        is_status<=kind_high_ok && (data==8'h48 || data==8'h42);end
                    6:length_high_ok<=data==0;
                    7:length_ok<=length_high_ok && ((is_prepare && data==8) || (is_status && data==1));
                    default:if(is_prepare && position>=8 && position<16)body[(position-8)*8+:8]<=data;
                endcase
            end else begin
                if(good && length_ok)begin
                    if(is_prepare && position==16)prepare_valid<=1;
                    if(is_status && position==9)status_request<=1;
                end
                position<=0;
            end
        end
    end
endmodule
