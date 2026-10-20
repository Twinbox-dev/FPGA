`timescale 1ns/1ps
module frame_fifo_read
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter FIFO_DEPTH             = 512,
	parameter BURST_SIZE             = 128
)
(
	input                            rst,
	input                            mem_clk,                    // external memory controller user interface clock
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
    input							 Sdr_rd_en,
	input							 App_wr_busy,
    output							 O_rd_busy,
	output 							 App_rd_en,
	output  [ADDR_BITS - 1:0]		 App_rd_addr,

    // ---- 视频读通道（read_clk 域请求，原始例程接口不变）----
	input                            read_req,                   // data read module read request,keep '1' until read_req_ack = '1'
	output                           read_req_ack,               // data read module read request response（电平：请求保持期间恒高）
	output                           read_finish,                // 电平：一路读完后保持，至本通道新请求上升沿清零
	input[ADDR_BITS - 1:0]           read_addr_0,                // 通道基址 0/1 归视频（read_addr_index 选择）
	input[ADDR_BITS - 1:0]           read_addr_1,
	input[ADDR_BITS - 1:0]           read_addr_2,                // 通道基址 2/3 归音频（aud_read_addr_index 选择）
	input[ADDR_BITS - 1:0]           read_addr_3,
	input[1:0]                       read_addr_index,
	input[ADDR_BITS - 1:0]           read_len,
	output reg                       fifo_aclr,                  // 视频 FIFO 异步清（S_ACK 一拍）
	input[9:0]                       wrusedw,                    // 视频 FIFO 写侧已用字

    // ---- 音频读通道（S4 新增：与视频共享读引擎。视频优先，音频在视频 FIFO
    //      有足够余量时（≥384 字）插入突发，不饿死视频；读数据按 cur_ch 路由到
    //      对应 FIFO。整段音频流式读入 512 字 FIFO，消费速率=播放速率）----
	input                            aud_read_req,               // 电平请求，保持到 ack
	output                           aud_read_req_ack,           // 电平响应
	output                           aud_read_finish,            // 电平：整段读完保持，至音频新请求上升沿清零
	input[1:0]                       aud_read_addr_index,        // 2=BUF2 / 3=BUF3
	input[ADDR_BITS-1:0]             aud_read_len,               // 字数（256 整数倍）
	output reg                       aud_fifo_aclr,              // 音频 FIFO 异步清（S_ACK 一拍）
	input[9:0]                       aud_wrusedw,                // 音频 FIFO 写侧已用字
	output                           aud_ch_active               // 当前读数据归属：1=音频 FIFO（写路由用）
);
localparam ONE                       = 256'd1;
localparam ZERO                      = 256'd0;
localparam S_IDLE                    = 0;
localparam S_ACK                     = 1;
localparam S_CHECK_FIFO              = 2;
localparam S_READ_BURST              = 3;
localparam S_READ_BURST_END          = 4;
localparam S_END                     = 5;

// 请求同步（各 3 拍，同例程习惯）
reg                                  read_req_d0;
reg                                  read_req_d1;
reg                                  read_req_d2;
reg                                  aud_req_d0;
reg                                  aud_req_d1;
reg                                  aud_req_d2;
reg[ADDR_BITS - 1:0]                 read_len_d0;
reg[ADDR_BITS - 1:0]                 read_len_d1;
reg[ADDR_BITS - 1:0]                 aud_len_d0;
reg[ADDR_BITS - 1:0]                 aud_len_d1;
reg[1:0]                             read_addr_index_d0;
reg[1:0]                             read_addr_index_d1;
reg[1:0]                             aud_addr_index_d0;
reg[1:0]                             aud_addr_index_d1;
reg[ADDR_BITS - 1:0]                 read_len_latch;
reg[ADDR_BITS - 1:0]                 read_cnt;
reg[3:0]                             state;
reg                                  cur_ch;                     // 0=视频 1=音频
reg                                  vfin_r, afin_r;             // 电平 finish（新请求上升沿清零）
			// ---- 音频会话保持：整段读被 512 字 FIFO 节流拉长到秒级，期间视频按帧抢占。
			// 曾被抢占即死（请求已撤、地址/计数/长度被视频会话覆写）→ 每段只出
			// ~30ms 声音后永久静音。现快照上下文，视频帧读完自动续读（FIFO 不清，
			// 消费侧无感知）。2026-09-27。
			reg                                  aud_sess_active;
			reg [ADDR_BITS - 1:0]                aud_addr_hold;
			reg [ADDR_BITS - 1:0]                aud_cnt_hold;
			reg [ADDR_BITS - 1:0]                aud_len_hold;
			wire                                 aud_resume = (state == S_END) && (cur_ch == 1'b0)
			                                                && aud_sess_active && (aud_req_d2 == 1'b0);
reg[ADDR_BITS - 1:0]	             App_rd_addr_r;

reg [BURST_BITS - 1:0]			     burst_cnt;
wire							     rd_burst_finish;
reg                                  App_rd_en_r;
reg                                  App_rd_en_d0;

wire rd_vld;
reg [3:0] rd_delay;

wire cur_req_d2   = cur_ch ? aud_req_d2   : read_req_d2;
wire [9:0] cur_wrusedw = cur_ch ? aud_wrusedw : wrusedw;
wire vid_req_rise = read_req_d2 & ~read_req_d1;   // mem_clk 域请求上升沿
wire aud_req_rise = aud_req_d2  & ~aud_req_d1;

assign App_rd_addr = {App_rd_addr_r[ADDR_BITS - 1:0]};
assign rd_vld = (state == S_READ_BURST && burst_cnt >= BURST_SIZE);
assign O_rd_busy = (state == S_READ_BURST);
assign rd_burst_finish = (rd_vld && rd_delay == 4'd10);
assign read_finish      = vfin_r;
assign aud_read_finish  = afin_r;
assign read_req_ack     = (state == S_ACK) && (cur_ch == 1'b0) && read_req_d2;
assign aud_read_req_ack = (state == S_ACK) && (cur_ch == 1'b1) && aud_req_d2;
assign aud_ch_active    = cur_ch;
assign App_rd_en = App_rd_en_d0;

always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		read_req_d0    <=  1'b0;
		read_req_d1    <=  1'b0;
		read_req_d2    <=  1'b0;
		aud_req_d0     <=  1'b0;
		aud_req_d1     <=  1'b0;
		aud_req_d2     <=  1'b0;
		read_len_d0    <=  ZERO[ADDR_BITS - 1:0];
		read_len_d1    <=  ZERO[ADDR_BITS - 1:0];
		aud_len_d0     <=  ZERO[ADDR_BITS - 1:0];
		aud_len_d1     <=  ZERO[ADDR_BITS - 1:0];
		read_addr_index_d0 <= 2'b00;
		read_addr_index_d1 <= 2'b00;
		aud_addr_index_d0  <= 2'b00;
		aud_addr_index_d1  <= 2'b00;
	end
	else
	begin
		read_req_d0    <=  read_req;
		read_req_d1    <=  read_req_d0;
		read_req_d2    <=  read_req_d1;
		aud_req_d0     <=  aud_read_req;
		aud_req_d1     <=  aud_req_d0;
		aud_req_d2     <=  aud_req_d1;
		read_len_d0    <=  read_len;
		read_len_d1    <=  read_len_d0;
		aud_len_d0     <=  aud_read_len;
		aud_len_d1     <=  aud_len_d0;
		read_addr_index_d0 <= read_addr_index;
		read_addr_index_d1 <= read_addr_index_d0;
		aud_addr_index_d0  <= aud_read_addr_index;
		aud_addr_index_d1  <= aud_addr_index_d0;
	end
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst || App_rd_en)begin
        rd_delay <= 4'd0;
    end
    else if(rd_delay < 4'd10)begin
    	rd_delay <= rd_delay + 1'b1;
    end
end

always @(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		burst_cnt <= ZERO[BURST_BITS - 1:0];
		App_rd_addr_r <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_d0 <= 1'b0;
	end
	else begin

		if(state == S_CHECK_FIFO)
			burst_cnt <= ZERO[BURST_BITS - 1:0];
		else if(App_rd_en)
			burst_cnt <= burst_cnt + 1'b1;
		else
			burst_cnt <= burst_cnt;
		//
		if(state == S_ACK)
			begin
				if(cur_ch == 1'b0)
				begin
					if(read_addr_index_d1 == 2'd0)
						App_rd_addr_r <= read_addr_0;
					else if(read_addr_index_d1 == 2'd1)
						App_rd_addr_r <= read_addr_1;
					else if(read_addr_index_d1 == 2'd2)
						App_rd_addr_r <= read_addr_2;
					else
						App_rd_addr_r <= read_addr_3;
				end
				else
					App_rd_addr_r <= (aud_addr_index_d1 == 2'd3) ? read_addr_3 : read_addr_2;
			end
		else if(aud_resume)
		    App_rd_addr_r <= aud_addr_hold;
		else if(App_rd_en)
			App_rd_addr_r <= App_rd_addr_r + 1'b1;
		else
			App_rd_addr_r <= App_rd_addr_r;
		//
		if(App_rd_en_r && burst_cnt + App_rd_en < BURST_SIZE)
			App_rd_en_d0 <= 1'b1;
		else
			App_rd_en_d0 <= 1'b0;

	end
end

always@(posedge mem_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		read_len_latch <= ZERO[ADDR_BITS - 1:0];
		App_rd_en_r <= 1'b0;
		read_cnt <= ZERO[ADDR_BITS - 1:0];
		fifo_aclr <= 1'b0;
		aud_fifo_aclr <= 1'b0;
		cur_ch <= 1'b0;
		vfin_r <= 1'b0;
		afin_r <= 1'b0;
		aud_sess_active <= 1'b0;
		aud_addr_hold <= ZERO[ADDR_BITS - 1:0];
		aud_cnt_hold  <= ZERO[ADDR_BITS - 1:0];
		aud_len_hold  <= ZERO[ADDR_BITS - 1:0];
	end
	else
	begin
		// 电平 finish：本通道新请求上升沿清零
		if (vid_req_rise) vfin_r <= 1'b0;
		if (aud_req_rise) afin_r <= 1'b0;

		case(state)
			S_IDLE:
			begin
				if(read_req_d2 == 1'b1 && Sdr_init_done)
				begin
					cur_ch <= 1'b0;
					state <= S_ACK;
				end
				else if(aud_req_d2 == 1'b1 && Sdr_init_done)
				begin
					cur_ch <= 1'b1;
					state <= S_ACK;
				end
			end

			S_ACK:
			begin
				if(cur_req_d2 == 1'b0)
				begin
					state <= S_CHECK_FIFO;
					fifo_aclr <= 1'b0;
					aud_fifo_aclr <= 1'b0;
				end
				else
				begin
					// 响应当前通道 + 清其 FIFO + 锁存基址/长度
					if (cur_ch == 1'b0) fifo_aclr <= 1'b1;
					else begin
					    aud_fifo_aclr   <= 1'b1;
					    aud_sess_active <= 1'b1;
					end
					read_len_latch <= cur_ch ? aud_len_d1 : read_len_d1;
				end
				read_cnt <= ZERO[ADDR_BITS - 1:0];
			end

			S_CHECK_FIFO:
			begin
				// 视频优先：服务音频期间视频来请求则切换（burst 边界安全点，
				// 此时上一突发数据已全部返回，cur_ch 翻转不会错路由）
				if(cur_ch == 1'b1 && read_req_d2 == 1'b1)
				begin
					cur_ch <= 1'b0;
					// 抢占快照：App_rd_addr_r/read_cnt/read_len_latch 将被视频会话覆写
					aud_addr_hold <= App_rd_addr_r;
					aud_cnt_hold  <= read_cnt;
					aud_len_hold  <= read_len_latch;
					state <= S_ACK;
				end
				// 本通道有新请求（下一帧/下一段）：重新应答
				else if(cur_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				// The SDRAM controller may be servicing a refresh even when the
				// application FIFO has room. Starting a burst then can return the
				// previous four data words repeatedly for the whole 256-word burst.
				else if(cur_wrusedw < (FIFO_DEPTH - BURST_SIZE) &&
				        ~App_wr_busy && ~Sdr_busy && ~Sdr_init_ref_vld)
				begin
					state <= S_READ_BURST;
					App_rd_en_r <= 1'b1;
				end
			end

			S_READ_BURST:
			begin
				if(rd_burst_finish == 1'b1)
				begin
					App_rd_en_r <= 1'b0;
					state <= S_READ_BURST_END;
					read_cnt <= read_cnt + BURST_SIZE[ADDR_BITS - 1:0];
				end
			end

			S_READ_BURST_END:
			begin
				if(cur_ch == 1'b1 && read_req_d2 == 1'b1)
				begin
					cur_ch <= 1'b0;
					// 抢占快照：App_rd_addr_r/read_cnt/read_len_latch 将被视频会话覆写
					aud_addr_hold <= App_rd_addr_r;
					aud_cnt_hold  <= read_cnt;
					aud_len_hold  <= read_len_latch;
					state <= S_ACK;
				end
				else if(cur_req_d2 == 1'b1)
				begin
					state <= S_ACK;
				end
				else if(read_cnt < read_len_latch)
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
				if (cur_ch == 1'b0)
				begin
				    vfin_r <= 1'b1;
				    // 被抢占的音频会话且 PL 无新请求 → 恢复续读（上下文已快照；
				    // 有新请求说明 PL 已放弃旧会话，走 S_IDLE 全新应答）
				    if (aud_resume)
				    begin
				        cur_ch         <= 1'b1;
				        read_cnt       <= aud_cnt_hold;
				        read_len_latch <= aud_len_hold;
				        state          <= S_CHECK_FIFO;
				    end
				    else
				        state <= S_IDLE;
				end
				else
				begin
				    afin_r <= 1'b1;
				    aud_sess_active <= 1'b0;
				    state <= S_IDLE;
				end
			end

			default:
				state <= S_IDLE;
		endcase
	end
end
endmodule
