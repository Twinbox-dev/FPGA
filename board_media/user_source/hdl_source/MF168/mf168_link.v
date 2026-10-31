`timescale 1ns/1ps
// MF168 (UETVL004DPB3000) distance frame receiver.
// One instance per sensor line: 8N1 UART -> A5 5A sync -> checksum -> distance.
// Frame: A5 5A ERROR TYPE RANGE_LO RANGE_HI AMP_LO AMP_HI USER_OUTPUT CHECKSUM
// CHECKSUM is the low 8 bits of the sum of ERROR..USER_OUTPUT.
module mf168_link #(
    parameter CLK_FREQ_HZ = 125000000,
    parameter BAUD        = 115200
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,
    output reg  [15:0] distance_mm,
    output reg         has_target,
    output reg  [7:0]  error_code,
    output reg         frame_valid
);
    localparam integer CLKS_PER_BIT = CLK_FREQ_HZ / BAUD;
    localparam integer HALF_BIT     = (CLKS_PER_BIT > 4) ? (CLKS_PER_BIT / 2) : 2;

    reg [2:0] rx_sync;
    always @(posedge clk) if(!rst_n) rx_sync<=3'b111; else rx_sync<={rx_sync[1:0],rx};
    wire rx_bit =rx_sync[2];
    wire rx_fall=rx_sync[2:1]==2'b10;

    // ---- 8N1 receiver: sample every bit at its centre ----
    localparam [1:0] U_IDLE=2'd0,U_START=2'd1,U_DATA=2'd2,U_STOP=2'd3;
    reg [1:0]  ustate;
    reg [15:0] ucnt;
    reg [2:0]  ubit;
    reg [7:0]  ushift;
    reg [7:0]  byte_data;
    reg        byte_valid;

    always @(posedge clk) begin
        byte_valid<=0;
        if(!rst_n) begin ustate<=U_IDLE;ucnt<=0;ubit<=0;ushift<=0;byte_data<=0;end
        else case(ustate)
            U_IDLE: if(rx_fall) begin ustate<=U_START;ucnt<=0;end
            U_START:
                if(ucnt==HALF_BIT-1) begin
                    ucnt<=0;
                    ustate<=rx_bit ? U_IDLE : U_DATA; // glitch on the start bit
                    ubit<=0;
                end else ucnt<=ucnt+1'b1;
            U_DATA:
                if(ucnt==CLKS_PER_BIT-1) begin
                    ucnt<=0;
                    ushift<={rx_bit,ushift[7:1]};
                    if(ubit==3'd7) ustate<=U_STOP; else ubit<=ubit+1'b1;
                end else ucnt<=ucnt+1'b1;
            U_STOP:
                if(ucnt==CLKS_PER_BIT-1) begin
                    ucnt<=0;ustate<=U_IDLE;
                    if(rx_bit) begin byte_data<=ushift;byte_valid<=1;end
                end else ucnt<=ucnt+1'b1;
        endcase
    end

    // ---- Frame parser: A5 5A sync, then 7 payload bytes + checksum ----
    localparam [1:0] P_IDLE=2'd0,P_HEAD=2'd1,P_COLLECT=2'd2;
    reg [1:0] pstate;
    reg [2:0] pidx;
    reg [7:0] pbuf [0:6];   // bytes 2..8 (ERROR..USER_OUTPUT)

    wire [15:0] range_raw={pbuf[3],pbuf[2]};
    wire [7:0]  chk_sum  =pbuf[0]+pbuf[1]+pbuf[2]+pbuf[3]+pbuf[4]+pbuf[5]+pbuf[6];

    always @(posedge clk) begin
        frame_valid<=0;
        if(!rst_n) begin
            pstate<=P_IDLE;pidx<=0;
            distance_mm<=16'hFFFF;has_target<=0;error_code<=0;
        end else if(byte_valid) case(pstate)
            P_IDLE:
                if(byte_data==8'hA5) pstate<=P_HEAD;
            P_HEAD:
                if(byte_data==8'h5A) begin pstate<=P_COLLECT;pidx<=0;end
                else if(byte_data!=8'hA5) pstate<=P_IDLE;
            P_COLLECT:
                if(pidx!=3'd7) begin pbuf[pidx]<=byte_data;pidx<=pidx+1'b1;end
                else begin
                    // pidx==7 is the checksum byte. Drop only this byte on a
                    // mismatch so the next A5 5A header is still within reach.
                    pidx<=0;pstate<=P_IDLE;
                    if(byte_data==chk_sum) begin
                        distance_mm<=range_raw;
                        has_target <=range_raw!=16'hFFFF;
                        error_code <=pbuf[0];
                        frame_valid<=1;
                    end else if(byte_data==8'hA5) pstate<=P_HEAD;
                end
        endcase
    end
endmodule
