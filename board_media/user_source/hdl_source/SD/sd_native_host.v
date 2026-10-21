`timescale 1ns/1ps

// Read-only native SD host for 3.3 V cards.  Command/response and CMD6 status
// bit positions follow SD Physical Layer Simplified Specification v9.10,
// sections 4.2, 4.3, and 4.3.10.  The command path runs in the
// dedicated 100 MHz domain; SDCLK is 200 kHz during identification, 25 MHz
// while negotiating High Speed, and 50 MHz after CMD6 confirms function 1.
// Data is kept in a dual-clock sector RAM until its CRC has passed.
module sd_native_host #(
    parameter integer DATA_TIMEOUT_CYCLES = 10000000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         pll_locked,
    output wire         sd_clk,
    inout  wire         sd_cmd,
    input  wire [3:0]   sd_dat,

    input  wire         req_toggle_async,
    input  wire [31:0]  req_lba_async,
    output reg          result_toggle,
    output reg          result_error,
    output reg          initialized,
    output reg          high_speed_supported,
    output reg          high_speed_active,
    output reg          high_capacity,
    output reg          high_capacity_support_req,
    output wire [5:0]   state_code,
    output reg  [15:0]  init_debug_word,
    output reg  [31:0]  last_read_cycles,

    input  wire         ram_rd_clk,
    input  wire         ram_rd_en,
    input  wire [8:0]   ram_rd_addr,
    output reg  [7:0]   ram_rd_data
);
    localparam [5:0]
        ST_WAIT_PLL=0, ST_PRECLOCK=1,
        ST_CMD0=2, ST_CMD0_WAIT=3, ST_CMD8=4, ST_CMD8_WAIT=5,
        ST_CMD55_OCR=6, ST_CMD55_OCR_WAIT=7, ST_ACMD41=8, ST_ACMD41_WAIT=9,
        ST_CMD2=10, ST_CMD2_WAIT=11, ST_CMD3=12, ST_CMD3_WAIT=13,
        ST_CMD7=14, ST_CMD7_WAIT=15, ST_BUSY=16,
        ST_CMD16=17, ST_CMD16_WAIT=18,
        ST_CMD6_CHECK=19, ST_CMD6_CHECK_WAIT=20,
        ST_CMD6_CHECK_DATA=21, ST_CMD6_SWITCH=22, ST_CMD6_SWITCH_WAIT=23,
        ST_CMD6_SWITCH_DATA=24, ST_CMD55_WIDTH=25, ST_CMD55_WIDTH_WAIT=26,
        ST_ACMD6=27, ST_ACMD6_WAIT=28, ST_READY=29,
        ST_READ_CMD=30, ST_READ_CMD_WAIT=31, ST_READ_TOKEN=32,
        ST_DATA_RX=33, ST_DATA_CRC=34, ST_DATA_END=35,
        ST_INIT_FAIL=36;
    // CMD6 64-byte status block is shifted MSB first. Support [415:400]
    // function 1 is bit 401 -> stream index 511-401=110. Current group-1
    // selection [379:376] arrives at stream indices 132..135.
    localparam [10:0] HS_SUPPORT_STREAM_INDEX=11'd110;
    localparam [10:0] HS_SELECT_FIRST_STREAM_INDEX=11'd132;
    localparam [10:0] HS_SELECT_LAST_STREAM_INDEX=11'd135;

    reg [5:0] state;
    reg [5:0] fail_state;
    assign state_code=(state==ST_INIT_FAIL)?fail_state:state;
    reg [7:0] sd_half_period;
    reg [7:0] sd_div_count;
    reg       sd_clk_reg;
    reg [7:0] preclock_count;
    wire sd_clk_rise = pll_locked && !rst && !sd_clk_reg &&
                       (sd_div_count == sd_half_period-1'b1);
    wire sd_clk_fall = pll_locked && !rst && sd_clk_reg &&
                       (sd_div_count == sd_half_period-1'b1);
    assign sd_clk=sd_clk_reg;

    reg         cmd_start;
    reg [5:0]   cmd_index;
    reg [31:0]  cmd_argument;
    reg [1:0]   cmd_response_kind;
    reg         cmd_open_drain;
    wire        cmd_done, cmd_error;
    wire [2:0]  cmd_error_code;
    wire [15:0] cmd_response_wait_trace;
    wire [5:0] cmd_tx_mismatch_position;
    wire cmd_tx_mismatch_expected,cmd_tx_mismatch_sampled;
    wire [2:0] cmd_debug_state;
    wire [135:0] cmd_response;
    wire        cmd_out, cmd_oe;
    wire        cmd_in = sd_cmd;
    assign sd_cmd = cmd_oe ? cmd_out : 1'bz;

    sd_native_cmd u_cmd (
        .clk(clk), .rst(rst), .sd_clk_rise(sd_clk_rise),
        .sd_clk_fall(sd_clk_fall), .cmd_in(cmd_in),
        .cmd_out(cmd_out), .cmd_oe(cmd_oe), .start(cmd_start),
        .command_index(cmd_index), .command_argument(cmd_argument),
        .response_kind(cmd_response_kind), .open_drain(cmd_open_drain),
        .busy(), .done(cmd_done), .error(cmd_error),.error_code(cmd_error_code),
        .response_wait_trace(cmd_response_wait_trace),
        .last_tx_mismatch_position(cmd_tx_mismatch_position),
        .last_tx_mismatch_expected(cmd_tx_mismatch_expected),
        .last_tx_mismatch_sampled(cmd_tx_mismatch_sampled),.response(cmd_response),
        .debug_state(cmd_debug_state)
    );

    reg [10:0] acmd41_retry;
    reg [1:0] read_retry;
    reg [31:0] read_lba;
    reg [31:0] read_cycle_counter;
    reg [2:0] req_sync;
    reg req_seen;
    reg [15:0] rca;

    reg hs_support_status;
    reg [3:0] hs_selected_function;
    reg data_is_sector;
    reg data_is_switch;
    reg data_bus_4bit;
    reg [11:0] data_count;
    reg [3:0] crc_count;
    reg [3:0] data_high_nibble;
    reg [7:0] serial_shift_byte;
    reg [8:0] sector_byte_index;
    reg [23:0] data_timeout;
    reg [7:0] sector_buffer [0:511];

    function [15:0] crc16_bit;
        input [15:0] crc;
        input data_bit;
        reg feedback;
        begin
            feedback = crc[15] ^ data_bit;
            crc16_bit = {crc[14:0],1'b0};
            if (feedback) crc16_bit = crc16_bit ^ 16'h1021;
        end
    endfunction

    // Full-width CRC accumulators are kept separately for each DAT lane.
    reg [15:0] lane_crc0, lane_crc1, lane_crc2, lane_crc3;
    reg [15:0] lane_recv0, lane_recv1, lane_recv2, lane_recv3;
    wire [15:0] lane_recv0_next = {lane_recv0[14:0],sd_dat[0]};
    wire [15:0] lane_recv1_next = {lane_recv1[14:0],sd_dat[1]};
    wire [15:0] lane_recv2_next = {lane_recv2[14:0],sd_dat[2]};
    wire [15:0] lane_recv3_next = {lane_recv3[14:0],sd_dat[3]};

    // True dual-clock byte RAM: the host writes a completed block in the SD
    // domain; the sector adapter reads it in the existing 50 MHz file domain.
    always @(posedge ram_rd_clk)
        if (ram_rd_en) ram_rd_data <= sector_buffer[ram_rd_addr];

    task start_command;
        input [5:0] index;
        input [31:0] argument;
        input [1:0] response_kind;
        input open_drain;
        begin
            cmd_index <= index;
            cmd_argument <= argument;
            cmd_response_kind <= response_kind;
            cmd_open_drain <= open_drain;
            cmd_start <= 1'b1;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_clk_reg<=0; sd_div_count<=0; sd_half_period<=8'd250;
            state<=ST_WAIT_PLL;fail_state<=ST_WAIT_PLL;preclock_count<=0;cmd_start<=0;
            cmd_index<=0; cmd_argument<=0; cmd_response_kind<=0; cmd_open_drain<=1;
            acmd41_retry<=0; read_retry<=0; read_lba<=0;
            read_cycle_counter<=0; req_sync<=0; req_seen<=0; rca<=0;high_capacity_support_req<=0;
            init_debug_word<=0;
            initialized<=0; high_speed_supported<=0; high_speed_active<=0;
            high_capacity<=0; result_toggle<=0; result_error<=0; last_read_cycles<=0;
            hs_support_status<=0;hs_selected_function<=0;
            data_is_sector<=0; data_is_switch<=0; data_bus_4bit<=0;
            data_count<=0; crc_count<=0; data_high_nibble<=0;serial_shift_byte<=0;sector_byte_index<=0;
            data_timeout<=0;
            lane_crc0<=0; lane_crc1<=0; lane_crc2<=0; lane_crc3<=0;
            lane_recv0<=0; lane_recv1<=0; lane_recv2<=0; lane_recv3<=0;
        end else begin
            cmd_start<=0;
            // During host activity, expose the full state, CMD shifter state,
            // error code, and response tail through the existing diagnostic.
            if (state!=ST_READY && state!=ST_INIT_FAIL)
                init_debug_word<={state[5:3],cmd_debug_state,cmd_error_code,
                                 cmd_response_wait_trace[6:0]};
            if(state!=ST_INIT_FAIL)fail_state<=state;
            req_sync<={req_sync[1:0],req_toggle_async};
            if (state!=ST_READY && initialized && read_cycle_counter!=32'hFFFFFFFF)
                read_cycle_counter<=read_cycle_counter+1'b1;
            if (!pll_locked) begin
                sd_clk_reg<=0; sd_div_count<=0; state<=ST_WAIT_PLL;
                initialized<=0;
            end else begin
                if (sd_div_count == sd_half_period-1'b1) begin
                    sd_div_count<=0;
                    sd_clk_reg<=~sd_clk_reg;
                end else sd_div_count<=sd_div_count+1'b1;

                case (state)
                    ST_WAIT_PLL: begin
                        if (pll_locked) begin
                            // Start below the 400 kHz identification ceiling. This
                            // leaves extra response setup time for the board/card
                            // path; the host still raises the clock after negotiation.
                            sd_half_period<=8'd250; sd_div_count<=0;
                            preclock_count<=0; state<=ST_PRECLOCK;
                        end
                    end
                    ST_PRECLOCK: if (sd_clk_rise) begin
                        if (preclock_count==8'd79) state<=ST_CMD0;
                        else preclock_count<=preclock_count+1'b1;
                    end
                    ST_CMD0: begin start_command(6'd0,32'd0,2'd0,1'b1); state<=ST_CMD0_WAIT; end
                    ST_CMD0_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_CMD0; else state<=ST_CMD8;
                    end
                    ST_CMD8: begin start_command(6'd8,32'h000001AA,2'd1,1'b1); state<=ST_CMD8_WAIT; end
                    ST_CMD8_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL;
                        else if(cmd_response[30]) begin
                            // SD v1.x may reject CMD8 as ILLEGAL_COMMAND; then
                            // start ACMD41 without HCS and use byte addressing.
                            high_capacity_support_req<=0;acmd41_retry<=0;state<=ST_CMD55_OCR;
                        end else if(cmd_response[19:8]==12'h1AA) begin
                            high_capacity_support_req<=1;acmd41_retry<=0;state<=ST_CMD55_OCR;
                        end else state<=ST_INIT_FAIL;
                    end
                    ST_CMD55_OCR: begin start_command(6'd55,32'd0,2'd1,1'b1); state<=ST_CMD55_OCR_WAIT; end
                    ST_CMD55_OCR_WAIT: if (cmd_done) begin
                        if (cmd_error || !cmd_response[13]) begin
                            fail_state<=cmd_error?{3'd0,cmd_error_code}:6'd6;state<=ST_INIT_FAIL;
                            if(cmd_error) init_debug_word<={cmd_tx_mismatch_position,
                                cmd_tx_mismatch_expected,cmd_tx_mismatch_sampled,
                                cmd_response_wait_trace[7:0]};
                        end
                        else state<=ST_ACMD41;
                    end
                    ST_ACMD41: begin
                        start_command(6'd41,high_capacity_support_req?32'h40FF8000:32'h00FF8000,2'd3,1'b1);
                        state<=ST_ACMD41_WAIT;
                    end
                    ST_ACMD41_WAIT: if (cmd_done) begin
                        if (cmd_error || acmd41_retry==11'd2047) state<=ST_INIT_FAIL;
                        else if (!cmd_response[39]) begin acmd41_retry<=acmd41_retry+1'b1; state<=ST_CMD55_OCR; end
                        else begin high_capacity<=cmd_response[38]; state<=ST_CMD2; end
                    end
                    ST_CMD2: begin start_command(6'd2,32'd0,2'd2,1'b1); state<=ST_CMD2_WAIT; end
                    ST_CMD2_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL; else state<=ST_CMD3;
                    end
                    ST_CMD3: begin start_command(6'd3,32'd0,2'd1,1'b1); state<=ST_CMD3_WAIT; end
                    ST_CMD3_WAIT: if (cmd_done) begin
                        if (cmd_error || cmd_response[39:8]==0) state<=ST_INIT_FAIL;
                        else begin rca<=cmd_response[39:24]; state<=ST_CMD7; end
                    end
                    ST_CMD7: begin start_command(6'd7,{rca,16'd0},2'd1,1'b0); state<=ST_CMD7_WAIT; end
                    ST_CMD7_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL; else begin data_timeout<=0; state<=ST_BUSY; end
                    end
                    ST_BUSY: begin
                        if (sd_clk_rise && sd_dat[0]) begin
                            data_timeout<=0;
                            if (high_capacity) state<=ST_CMD6_CHECK;
                            else state<=ST_CMD16;
                        end else if (data_timeout==DATA_TIMEOUT_CYCLES-1) state<=ST_INIT_FAIL;
                        else data_timeout<=data_timeout+1'b1;
                    end
                    ST_CMD16: begin start_command(6'd16,32'd512,2'd1,1'b0); state<=ST_CMD16_WAIT; end
                    ST_CMD16_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL; else state<=ST_CMD6_CHECK;
                    end
                    ST_CMD6_CHECK: begin start_command(6'd6,32'h00FFFFF1,2'd1,1'b0); state<=ST_CMD6_CHECK_WAIT; end
                    ST_CMD6_CHECK_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL;
                        else if(cmd_response[30]) begin
                            // Cards predating CMD6 stay at native 25 MHz.
                            high_speed_supported<=0;high_speed_active<=0;
                            sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;
                        end
                        else begin data_is_sector<=0;data_is_switch<=0;data_bus_4bit<=0;data_timeout<=0;state<=ST_CMD6_CHECK_DATA; end
                    end
                    ST_CMD6_SWITCH: begin start_command(6'd6,32'h80FFFFF1,2'd1,1'b0); state<=ST_CMD6_SWITCH_WAIT; end
                    ST_CMD6_SWITCH_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL;
                        else if(cmd_response[30]) begin
                            high_speed_active<=0;sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;
                        end
                        else begin data_is_sector<=0;data_is_switch<=1;data_bus_4bit<=0;data_timeout<=0;state<=ST_CMD6_SWITCH_DATA; end
                    end
                    ST_CMD6_CHECK_DATA,ST_CMD6_SWITCH_DATA,ST_READ_TOKEN: begin
                        if (data_timeout==DATA_TIMEOUT_CYCLES-1) begin
                            if (data_is_sector && read_retry<2) begin read_retry<=read_retry+1'b1; state<=ST_READ_CMD; end
                            else if (data_is_sector) begin result_error<=1;result_toggle<=~result_toggle;state<=ST_READY; end
                            else state<=ST_INIT_FAIL;
                        end else begin
                            data_timeout<=data_timeout+1'b1;
                            if (sd_clk_rise && ((data_bus_4bit && sd_dat==4'b0000) || (!data_bus_4bit && !sd_dat[0]))) begin
                                data_count<=0;crc_count<=0;sector_byte_index<=0;serial_shift_byte<=0;
                                lane_crc0<=0;lane_crc1<=0;lane_crc2<=0;lane_crc3<=0;
                                lane_recv0<=0;lane_recv1<=0;lane_recv2<=0;lane_recv3<=0;
                                hs_support_status<=0;hs_selected_function<=0;state<=ST_DATA_RX;
                            end
                        end
                    end
                    ST_DATA_RX: if (sd_clk_rise) begin
                        data_timeout<=0;
                        if (data_is_sector) begin
                            if (data_bus_4bit) begin
                                lane_crc0<=crc16_bit(lane_crc0,sd_dat[0]);
                                lane_crc1<=crc16_bit(lane_crc1,sd_dat[1]);
                                lane_crc2<=crc16_bit(lane_crc2,sd_dat[2]);
                                lane_crc3<=crc16_bit(lane_crc3,sd_dat[3]);
                                if (!data_count[0]) data_high_nibble<=sd_dat;
                                else begin
                                    sector_buffer[sector_byte_index]<={data_high_nibble,sd_dat};
                                    sector_byte_index<=sector_byte_index+1'b1;
                                end
                                if (data_count==11'd1023) begin crc_count<=0;state<=ST_DATA_CRC; end
                            end else begin
                                lane_crc0<=crc16_bit(lane_crc0,sd_dat[0]);
                                serial_shift_byte<={serial_shift_byte[6:0],sd_dat[0]};
                                if(data_count[2:0]==3'd7)begin
                                    sector_buffer[sector_byte_index]<={serial_shift_byte[6:0],sd_dat[0]};
                                    sector_byte_index<=sector_byte_index+1'b1;
                                end
                                if(data_count==12'd4095)begin crc_count<=0;state<=ST_DATA_CRC;end
                            end
                            data_count<=data_count+1'b1;
                        end else begin
                            lane_crc0<=crc16_bit(lane_crc0,sd_dat[0]);
                            if (data_count==HS_SUPPORT_STREAM_INDEX) hs_support_status<=sd_dat[0];
                            if (data_count>=HS_SELECT_FIRST_STREAM_INDEX && data_count<=HS_SELECT_LAST_STREAM_INDEX)
                                hs_selected_function<={hs_selected_function[2:0],sd_dat[0]};
                            if (data_count==11'd511) begin crc_count<=0;state<=ST_DATA_CRC; end
                            data_count<=data_count+1'b1;
                        end
                    end
                    ST_DATA_CRC: if (sd_clk_rise) begin
                        lane_recv0<=lane_recv0_next;
                        if (data_bus_4bit) begin
                            lane_recv1<=lane_recv1_next;lane_recv2<=lane_recv2_next;lane_recv3<=lane_recv3_next;
                        end
                        if (crc_count==4'd15) state<=ST_DATA_END;
                        else crc_count<=crc_count+1'b1;
                    end
                    ST_DATA_END: if (sd_clk_rise) begin
                        if (data_bus_4bit) begin
                            if (sd_dat!=4'hF || lane_recv0!=lane_crc0 || lane_recv1!=lane_crc1 ||
                                lane_recv2!=lane_crc2 || lane_recv3!=lane_crc3) begin
                                if (data_is_sector && read_retry<2) begin read_retry<=read_retry+1'b1;state<=ST_READ_CMD; end
                                else if (data_is_sector) begin result_error<=1;result_toggle<=~result_toggle;state<=ST_READY; end
                                else state<=ST_INIT_FAIL;
                            end else if (data_is_sector) begin
                                result_error<=0;result_toggle<=~result_toggle;
                                last_read_cycles<=read_cycle_counter;
                                state<=ST_READY;
                            end else if (!data_is_switch) begin
                                high_speed_supported<=hs_support_status;
                                if (hs_support_status) state<=ST_CMD6_SWITCH;
                                else begin high_speed_active<=0;sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;end
                            end else begin
                                if (hs_support_status && hs_selected_function==4'd1) begin
                                    high_speed_supported<=1;high_speed_active<=1;
                                    state<=ST_CMD55_WIDTH;
                                end else begin
                                    high_speed_active<=0;sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;
                                end
                            end
                        end else begin
                            if (sd_dat[0]!=1'b1 || lane_recv0!=lane_crc0) begin
                                if(data_is_sector && read_retry<2)begin
                                    read_retry<=read_retry+1'b1;state<=ST_READ_CMD;
                                end else if(data_is_sector)begin
                                    result_error<=1;result_toggle<=~result_toggle;state<=ST_READY;
                                end else state<=ST_INIT_FAIL;
                            end
                            else if (data_is_sector) begin
                                result_error<=0;result_toggle<=~result_toggle;
                                last_read_cycles<=read_cycle_counter;state<=ST_READY;
                            end else if (data_is_switch) begin
                                if (hs_support_status && hs_selected_function==4'd1) begin
                                    high_speed_supported<=1;high_speed_active<=1;
                                    state<=ST_CMD55_WIDTH;
                                end else begin
                                    high_speed_active<=0;sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;
                                end
                            end else begin
                                high_speed_supported<=hs_support_status;
                                if (hs_support_status) state<=ST_CMD6_SWITCH;
                                else begin high_speed_active<=0;sd_half_period<=8'd2;state<=ST_CMD55_WIDTH;end
                            end
                        end
                    end
                    ST_CMD55_WIDTH: begin start_command(6'd55,{rca,16'd0},2'd1,1'b0);state<=ST_CMD55_WIDTH_WAIT;end
                    ST_CMD55_WIDTH_WAIT: if (cmd_done) begin
                        if (cmd_error || !cmd_response[13]) state<=ST_INIT_FAIL; else state<=ST_ACMD6;
                    end
                    ST_ACMD6: begin start_command(6'd6,32'd2,2'd1,1'b0);state<=ST_ACMD6_WAIT;end
                    ST_ACMD6_WAIT: if (cmd_done) begin
                        if (cmd_error) state<=ST_INIT_FAIL;
                        else begin
                            data_bus_4bit<=!cmd_response[30];
                            if (high_speed_active) sd_half_period<=8'd1;
                            else sd_half_period<=8'd2;
                            initialized<=1;state<=ST_READY;
                        end
                    end
                    ST_READY: begin
                        if (req_sync[2]!=req_seen && initialized) begin
                            req_seen<=req_sync[2];read_lba<=req_lba_async;read_retry<=0;
                            read_cycle_counter<=0;state<=ST_READ_CMD;
                        end
                    end
                    ST_READ_CMD: begin
                        start_command(6'd17,high_capacity?read_lba:(read_lba<<9),2'd1,1'b0);
                        state<=ST_READ_CMD_WAIT;
                    end
                    ST_READ_CMD_WAIT: if (cmd_done) begin
                        if (cmd_error || |cmd_response[39:24]) begin
                            if (read_retry<2) begin read_retry<=read_retry+1'b1;state<=ST_READ_CMD; end
                            else begin result_error<=1;result_toggle<=~result_toggle;state<=ST_READY;end
                        end else begin data_is_sector<=1;data_timeout<=0;state<=ST_READ_TOKEN;end
                    end
                    ST_INIT_FAIL: begin initialized<=0;high_speed_active<=0;end
                    default: state<=ST_INIT_FAIL;
                endcase
            end
        end
    end
endmodule
