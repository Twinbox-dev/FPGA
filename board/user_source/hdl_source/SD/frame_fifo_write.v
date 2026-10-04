`timescale 1ns/1ps
module frame_fifo_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      // 1: write image rows upside-down to cancel BMP bottom-up storage
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)               
(
	input                            rst,                  
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	input							 App_rd_busy,
    output							 O_wr_busy,
	
	output 							 App_wr_en,
	output  [ADDR_BITS - 1:0]	 	App_wr_addr,
	/*
    output reg                       wr_burst_req,               // to external memory controller,send out a burst write request  
	output reg[BURST_BITS - 1:0]     wr_burst_len,               // to external memory controller,data length of the burst write request, not bytes 
	output reg[ADDR_BITS - 1:0]      wr_burst_addr,              // to external memory controller,base address of the burst write request 
	input                            wr_burst_data_req,          // from external memory controller,write data request ,before data 1 clock 
	input                            wr_burst_finish,            // from external memory controller,burst write finish
	*/
	input                            write_req,                  // data write module write request,keep '1' until read_req_ack = '1'
	output reg                       write_req_ack,              // data write module write request response
	output                           write_finish,               // data write module write request finish
	input[ADDR_BITS - 1:0]           write_addr_0,               // data write module write request base address 0, used when write_addr_index = 0
	input[ADDR_BITS - 1:0]           write_addr_1,               // data write module write request base address 1, used when write_addr_index = 1
	input[ADDR_BITS - 1:0]           write_addr_2,               // data write module write request base address 1, used when write_addr_index = 2
	input[ADDR_BITS - 1:0]           write_addr_3,               // data write module write request base address 1, used when write_addr_index = 3
	input[1:0]                       write_addr_index,           // select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
	input[ADDR_BITS - 1:0]           write_len,                  // data write module write request data length
	input signed[19:0]               vrow_off,                   // 2026-10-03 多分辨率信箱适配：
	                                                             // vflip 首行行号修正量（字） =
	                                                             // y0 + img_h - FRAME_HEIGHT（≤0）。
	                                                             // 仅 vflip_en 通道参与寻址；0 = 原行为。
	output reg                       fifo_aclr,                  // to fifo asynchronous clear
	input[9:0]                      rdusedw                     // from fifo read used words
);
localparam ONE                       = 256'd1;                   //256 bit '1'   you can use ONE[n-1:0] for n bit '1'
localparam ZERO                      = 256'd0;                   //256 bit '0'

// Vertical flip address mapping for 640x480 frame buffer.
// Input stream order remains unchanged; only SDRAM write addresses are remapped:
// stream row 0 -> memory row FRAME_HEIGHT-1, stream row 1 -> memory row FRAME_HEIGHT-2, ...
localparam [ADDR_BITS - 1:0] VFLIP_FIRST_ADDR_OFFSET = (FRAME_HEIGHT - 1) * FRAME_WIDTH;
localparam [ADDR_BITS - 1:0] VFLIP_LINE_JUMP         = (FRAME_WIDTH * 2) - 1;
localparam [15:0]            VFLIP_LINE_LAST_X       = FRAME_WIDTH - 1;

// 垂直翻转只对图像写通道（index 0/1）生效；音频（index 2/3）必须顺序写。
// 曾对全部通道翻转：音频字被打散进 640 字行块倒排地址，播放顺序读 =
// 读到没写过的区域 = 噪声（TST 静音仍静音/正弦变噪声/切图爆音），且
// 仿真（C++ 写模型无地址概念）不可见。2026-09-27 板级实锤后修复。
wire vflip_en = WRITE_V_FLIP && (write_addr_index_d1[1] == 1'b0);

//write state machine code
localparam S_IDLE                    = 0;                        //idle state,waiting for write
localparam S_ACK                     = 1;                        //written request response
localparam S_CHECK_FIFO              = 2;                        //check the FIFO status, ensure that there is enough space to burst write
localparam S_WRITE_BURST             = 3;                        //begin a burst write
localparam S_WRITE_BURST_END         = 4;                        //a burst write complete
localparam S_END                     = 5;                        //a frame of data is written to complete


reg                                 write_req_d0;                //asynchronous write request, synchronize to 'mem_clk' clock domain,first beat
reg                                 write_req_d1;                //the second
reg                                 write_req_d2;                //third,Why do you need 3 ? Here's the design habit
reg[ADDR_BITS - 1:0]                write_len_d0;                //asynchronous write_len(write data length), synchronize to 'mem_clk' clock domain first
reg[ADDR_BITS - 1:0]                write_len_d1;                //second
reg[ADDR_BITS - 1:0]                write_len_latch;             //lock write data length
reg[ADDR_BITS - 1:0]                write_cnt /*verilator public_flat_rd*/;  //write data counter
reg[ADDR_BITS - 1:0]                rem_words /*verilator public_flat_rd*/;   // 未弹出字数（len−pops，收尾清空判据用）
reg[1:0]                            write_addr_index_d0;
reg[1:0]                            write_addr_index_d1;
reg[3:0]                            state;                       //state machine
reg [ADDR_BITS - 1:0]	 App_wr_addr_r;
reg [15:0]                            wr_x;                       // current x position in one input row

reg [BURST_BITS - 1:0]				burst_cnt /*verilator public_flat_rd*/;
wire								wr_burst_finish;

reg App_wr_en_r;
reg App_wr_en_d0;

wire into_burst;
// 尾部清空判据：rem_words <= rdusedw+1。窗口形式拆解：高 11 位为零（NOR，快）
// + 低 10 位比较——避免 21 位加法器+比较器级联进组合路径（时序违例 -7.5/-7.9 根因，
// 4a8362f 时代本路径即 -6.7ns 接受违例，多分辨率挂死疑与其边际误触发相关）
assign into_burst = ((rem_words[ADDR_BITS-1:10] == 0
                      && rem_words[9:0] <= (rdusedw + 1'b1))
                     || (rdusedw > BURST_SIZE)) && (~App_rd_busy);//当rd在突发时不会进入burst

assign App_wr_addr = {App_wr_addr_r[ADDR_BITS - 1:0]};
//assign O_wr_busy = (state != S_IDLE || (S_IDLE && write_req_d2));
assign O_wr_busy = (state == S_WRITE_BURST || (state == S_CHECK_FIFO && into_burst));//在突发，或者将要突发，则显示busy
assign wr_burst_finish = (burst_cnt >= BURST_SIZE) || (write_cnt >= write_len_latch);
assign write_finish = (state == S_END) ? 1'b1 : 1'b0;            //write finish at state 'S_END'
assign App_wr_en = App_wr_en_d0;


always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		write_req_d0    <=  1'b0;
		write_req_d1    <=  1'b0;
		write_req_d2    <=  1'b0;
		write_len_d0    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d0 <= 0;
		write_len_d1    <=  ZERO[ADDR_BITS - 1:0];              //equivalent to write_len_d1 <= 0;
		write_addr_index_d0    <=  2'b00;
		write_addr_index_d1    <=  2'b00;
	end
	else
	begin
		write_req_d0    <=  write_req;
		write_req_d1    <=  write_req_d0;
		write_req_d2    <=  write_req_d1;
		write_len_d0    <=  write_len;
		write_len_d1    <=  write_len_d0;
		write_addr_index_d0 <= write_addr_index;
		write_addr_index_d1 <= write_addr_index_d0;
	end 
end
always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_wr_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_wr_en_d0 <= 1'b0;
		wr_x <= 16'd0;
	end
	else begin
	
		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_wr_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				wr_x <= 16'd0;
				// 多分辨率信箱：部分高度会话的首行不再钉在 FRAME_HEIGHT-1，
				// 而是落在 y0+h-1 行（居中）。vrow_off = y0+h-FRAME_HEIGHT（≤0），
				// 以二补码字偏移加进首地址；全帧会话 vrow_off=0 行为不变。
				if(write_addr_index_d1 == 2'd0)
					App_wr_addr_r <= vflip_en ? (write_addr_0 + VFLIP_FIRST_ADDR_OFFSET + {{(ADDR_BITS-20){vrow_off[19]}}, vrow_off}) : write_addr_0;
				else if(write_addr_index_d1 == 2'd1)
					App_wr_addr_r <= vflip_en ? (write_addr_1 + VFLIP_FIRST_ADDR_OFFSET + {{(ADDR_BITS-20){vrow_off[19]}}, vrow_off}) : write_addr_1;
				else if(write_addr_index_d1 == 2'd2)
					App_wr_addr_r <= vflip_en ? (write_addr_2 + VFLIP_FIRST_ADDR_OFFSET + {{(ADDR_BITS-20){vrow_off[19]}}, vrow_off}) : write_addr_2;
				else if(write_addr_index_d1 == 2'd3)
					App_wr_addr_r <= vflip_en ? (write_addr_3 + VFLIP_FIRST_ADDR_OFFSET + {{(ADDR_BITS-20){vrow_off[19]}}, vrow_off}) : write_addr_3;
			end
		else if(App_wr_en)
			begin
				if(vflip_en)
				begin
					if(wr_x == VFLIP_LINE_LAST_X)
					begin
						wr_x <= 16'd0;
						App_wr_addr_r <= App_wr_addr_r - VFLIP_LINE_JUMP;
					end
					else
					begin
						wr_x <= wr_x + 1'b1;
						App_wr_addr_r <= App_wr_addr_r + 1'b1;
					end
				end
				else
					App_wr_addr_r <= App_wr_addr_r + 1'b1;
			end
		else
			App_wr_addr_r <= App_wr_addr_r;
		//
		if(App_wr_en_r && burst_cnt < BURST_SIZE && (write_cnt < write_len_latch))begin
            App_wr_en_d0 <= 1'b1;
        end
		else
			App_wr_en_d0 <= 1'b0;
	
	end		
end
always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		write_len_latch <= ZERO[ADDR_BITS - 1:0];
		rem_words <= ZERO[ADDR_BITS - 1:0];
		
		//wr_burst_addr <= ZERO[ADDR_BITS - 1:0];
		//wr_burst_req <= 1'b0;
		App_wr_en_r <= 1'b0;
		
		write_cnt <= ZERO[ADDR_BITS - 1:0];
		rem_words <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		write_req_ack <= 1'b0;
		//wr_burst_len <= ZERO[BURST_BITS - 1:0];
		
		
	end
	else 
		begin
		// write_cnt 逐字精确计数（2026-10-04 尾部收尾修复）：尾部不满一个 burst
		// 的弹出也入账，收尾清空条件 (write_len_latch <= rdusedw + write_cnt)
		// 才能在最后一个字到达时成立（原按 burst 结算永远差一个字的账）
		write_cnt <= write_cnt + App_wr_en;
		rem_words <= rem_words - App_wr_en;
		case(state)
			//idle state,waiting for write write_req_d2 == '1' goto the 'S_ACK'
			S_IDLE:
			begin
				if(write_req_d2 == 1'b1 && Sdr_init_done)
				begin
					state <= S_ACK;
				end
				write_req_ack <= 1'b0;
			end
			//'S_ACK' state completes the write request response, the FIFO reset, the address latch, and the data length latch
			S_ACK:
			begin
				//after write request revocation(write_req_d2 == '0'),goto 'S_CHECK_FIFO',write_req_ack goto '0'
				if(write_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					write_req_ack <= 1'b0;
				end
				else
				begin
					//write request response
					write_req_ack <= 1'b1;
					//FIFO reset
					fifo_aclr <= 1'b1;
					//select valid base address from write_addr_0 write_addr_1 write_addr_2 write_addr_3
					/*
					if(write_addr_index_d1 == 2'd0)
						wr_burst_addr <= write_addr_0;
					else if(write_addr_index_d1 == 2'd1)
						wr_burst_addr <= write_addr_1;
					else if(write_addr_index_d1 == 2'd2)
						wr_burst_addr <= write_addr_2;
					else if(write_addr_index_d1 == 2'd3)
						wr_burst_addr <= write_addr_3;
					*/
					//latch data length
					write_len_latch <= write_len_d1;                    
					rem_words <= write_len_d1;                    // 剩余字数登记
				end
				//write data counter reset, write_cnt <= 0;
				write_cnt <= ZERO[ADDR_BITS - 1:0];
			end
			S_CHECK_FIFO:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the FIFO space is a burst write request, goto burst write state
				else if(into_burst)
				begin
					state <= S_WRITE_BURST;
					//wr_burst_len <= BURST_SIZE[BURST_BITS - 1:0];
					//wr_burst_req <= 1'b1;
					App_wr_en_r <= 1'b1;
				end
			end 
			
			S_WRITE_BURST:
			begin
				//burst finish
				if(wr_burst_finish == 1'b1)
				begin
					App_wr_en_r <= 1'b0;
					state <= S_WRITE_BURST_END;
					//write_cnt 逐字计数（见 FSM 头部），不再按 burst 结算
					//the next burst write address is generated
					//wr_burst_addr <= wr_burst_addr + BURST_SIZE[ADDR_BITS - 1:0];
				end     
			end
			S_WRITE_BURST_END:
			begin
				//if there is a write request at this time, enter the 'S_ACK' state
				if(write_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				//if the write counter value is less than the frame length, continue writing,
				//otherwise the writing is complete
				else if(write_cnt < write_len_latch)
				begin
					state <= S_CHECK_FIFO;
				end
				else
				begin
					state <= S_END;
				end
			end
			S_END:
			begin
				state <= S_IDLE;
			end
			default:
				state <= S_IDLE;
		endcase
		end
end
endmodule
