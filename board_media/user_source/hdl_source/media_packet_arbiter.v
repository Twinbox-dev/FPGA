// Two complete application packet sources; ownership and route survive the
// last payload byte until a new request is actually selected.
module media_packet_arbiter(
    input wire clk,rst,
    input wire a_request,a_valid,a_to_pc,
    input wire [7:0] a_data,
    input wire [15:0] a_length,
    output wire a_ack,
    input wire b_request,b_valid,b_to_pc,
    input wire [7:0] b_data,
    input wire [15:0] b_length,
    output wire b_ack,
    output wire request,valid,
    output wire [7:0] data,
    output reg [15:0] length,
    output reg to_pc,
    input wire ack
);
    reg active,owner;
    reg [15:0] position;
    assign request=active && (owner ? b_request : a_request);
    assign valid=active && (owner ? b_valid : a_valid);
    assign data=owner ? b_data : a_data;
    assign a_ack=active && !owner && ack;
    assign b_ack=active && owner && ack;
    always @(posedge clk)begin
        if(rst)begin active<=0;owner<=0;position<=0;length<=0;to_pc<=0;end
        else if(!active)begin
            if(a_request || b_request)begin
                owner<=b_request;active<=1;position<=0;
                length<=b_request ? b_length : a_length;
                to_pc<=b_request ? b_to_pc : a_to_pc;
            end
        end else if(valid)begin
            if(position+1>=length)begin active<=0;position<=0;end
            else position<=position+1'b1;
        end
    end
endmodule
