// Bounded I2C transaction: optional 1..3 write bytes, repeated START, 1..24
// read bytes. Both pins remain open drain, including timeout recovery.
module sensor_i2c_transfer #(
 parameter CLK_HZ=50000000,I2C_DIV=167,TIMEOUT_CYCLES=CLK_HZ/20
)(
 input wire clk,rst,start,
 input wire [6:0] address,
 input wire [1:0] write_count,
 input wire [23:0] write_data,
 input wire [4:0] read_count,
 output reg busy,done,error,timeout_error,
 output reg [191:0] read_data,
 inout wire scl,sda
);
 localparam IDLE=0,WAIT_BYTE=1,ADDRESS=2,ADDRESS_DONE=3,WRITE_BYTE=4,WRITE_DONE=5,
  READ_BYTE=6,READ_DONE=7,FINISH=8;
 reg [3:0] state,continuation;
 reg [6:0] addr;reg [1:0] wc,wi;reg [4:0] rc,ri;
 reg [23:0] wd;reg reading,command_valid,read_nack,driver_reset;
 reg [1:0] command;reg [7:0] tx;
 wire byte_done,byte_ack;wire [7:0] rx;
 reg [$clog2(TIMEOUT_CYCLES+1)-1:0] timeout;
 sensor_i2c_byte #(.DIV(I2C_DIV)) engine(.clk(clk),.rst(rst||driver_reset),
  .cmd_valid(command_valid),.cmd(command),.tx_data(tx),.read_nack(read_nack),
  .busy(),.done(byte_done),.ack_ok(byte_ack),.rx_data(rx),.scl(scl),.sda(sda));
 task issue(input [1:0] op,input [7:0] data,input nack,input [3:0] next_state);
  begin command<=op;tx<=data;read_nack<=nack;command_valid<=1;continuation<=next_state;state<=WAIT_BYTE;end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;continuation<=IDLE;addr<=0;wc<=0;wi<=0;rc<=0;ri<=0;wd<=0;
   reading<=0;command_valid<=0;read_nack<=0;driver_reset<=0;command<=0;tx<=0;
   busy<=0;done<=0;error<=0;timeout_error<=0;read_data<=0;timeout<=0;
  end else begin
   command_valid<=0;driver_reset<=0;done<=0;
   if(busy)timeout<=timeout+1'b1;else timeout<=0;
   if(busy&&timeout==TIMEOUT_CYCLES-1)begin
    driver_reset<=1;busy<=0;done<=1;error<=1;timeout_error<=1;state<=IDLE;
   end else case(state)
    IDLE:if(start)begin
     busy<=1;error<=0;timeout_error<=0;read_data<=0;addr<=address;wc<=write_count;rc<=read_count;
     wi<=0;ri<=0;wd<=write_data;reading<=write_count==0;timeout<=0;
     issue(0,0,0,ADDRESS);
    end
    WAIT_BYTE:if(byte_done)state<=continuation;
    ADDRESS:issue(2,{addr,reading},0,ADDRESS_DONE);
    ADDRESS_DONE:if(!byte_ack)begin error<=1;issue(1,0,0,FINISH);end
                 else if(reading)state<=READ_BYTE;else state<=WRITE_BYTE;
    WRITE_BYTE:issue(2,wd[wi*8+:8],0,WRITE_DONE);
    WRITE_DONE:if(!byte_ack)begin error<=1;issue(1,0,0,FINISH);end
     else if(wi+1<wc)begin wi<=wi+1'b1;state<=WRITE_BYTE;end
     else if(rc!=0)begin reading<=1;issue(0,0,0,ADDRESS);end
     else issue(1,0,0,FINISH);
    READ_BYTE:if(rc==0)issue(1,0,0,FINISH);else issue(3,0,ri+1==rc,READ_DONE);
    READ_DONE:begin
     read_data[ri*8+:8]<=rx;
     if(ri+1<rc)begin ri<=ri+1'b1;state<=READ_BYTE;end else issue(1,0,0,FINISH);
    end
    FINISH:begin busy<=0;done<=1;state<=IDLE;end
    default:state<=IDLE;
   endcase
  end
 end
endmodule
