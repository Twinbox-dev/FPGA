// Prefetch one row of the target image through the SDRAM application's read
// port. Ownership is held until every response to a 128-word burst arrives.
// A one-cycle yield between bursts lets the existing video/audio reader refill.
module transition_line_read #(
    parameter ADDR_BITS       = 21,
    parameter SAFE_FIFO_WORDS = 256
)(
    input  wire                 mem_clk,
    input  wire                 rst,
    input  wire                 sdr_init_done,
    input  wire                 sdr_busy,
    input  wire                 sdr_refresh,
    input  wire                 line_req_toggle,
    input  wire [9:0]           line_num,
    input  wire [ADDR_BITS-1:0] line_base,
    input  wire [9:0]           row_words,
    output reg                  line_ready_toggle,

    input  wire                 frame_rd_en,
    input  wire [ADDR_BITS-1:0] frame_rd_addr,
    input  wire                 frame_wr_en,
    input  wire                 frame_rd_busy,
    input  wire                 frame_wr_busy,
    input  wire [8:0]           video_fifo_words,
    output wire                 line_hold,
    output wire                 app_rd_en,
    output wire [ADDR_BITS-1:0] app_rd_addr,

    input  wire                 sdr_rd_valid,
    input  wire [31:0]          sdr_rd_data,
    output wire                 frame_rd_valid,
    output wire                 line_wr_en,
    output wire [31:0]          line_wr_data,
    output wire [9:0]           line_wr_addr,
    output reg                  line_wr_bank
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_WAIT  = 3'd1,
                     S_ISSUE = 3'd2,
                     S_DRAIN = 3'd3,
                     S_YIELD = 3'd4,
                     S_RESERVE = 3'd5;
    reg [2:0] state;
    reg req_s1, req_s2, req_s3;
    wire req_pulse = req_s2 ^ req_s3;

    reg [ADDR_BITS-1:0] cmd_addr;
    reg [9:0] total_recv,row_words_latched;
    reg [7:0] burst_sent, burst_recv,burst_target;
    reg [3:0] frame_quiet;
    wire owner = (state == S_ISSUE) || (state == S_DRAIN);
    wire can_grant = (state == S_WAIT) && sdr_init_done &&
                     !sdr_busy && !sdr_refresh &&
                     !frame_rd_busy && !frame_wr_busy &&
                     !frame_rd_en && !frame_wr_en &&
                     (frame_quiet == 4'd10) &&
                     (video_fifo_words >= SAFE_FIFO_WORDS);
    wire line_data_valid = owner && sdr_rd_valid;

    // The reservation is registered. A combinational grant-to-line_hold path
    // would feed back through frame_read_write's App_*_busy arbitration.
    assign line_hold     = owner || (state == S_RESERVE);
    assign app_rd_en     = owner ? (state == S_ISSUE) : frame_rd_en;
    assign app_rd_addr   = owner ? cmd_addr : frame_rd_addr;
    assign frame_rd_valid = sdr_rd_valid && !owner;
    assign line_wr_en    = line_data_valid && (total_recv < row_words_latched);
    assign line_wr_addr  = total_recv;
    assign line_wr_data  = sdr_rd_data;

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            req_s1 <= 1'b0;
            req_s2 <= 1'b0;
            req_s3 <= 1'b0;
        end else begin
            req_s1 <= line_req_toggle;
            req_s2 <= req_s1;
            req_s3 <= req_s2;
        end
    end

    // Guard against a late response from the preceding frame/audio burst.
    always @(posedge mem_clk or posedge rst) begin
        if (rst) frame_quiet <= 4'd0;
        else if (owner || frame_rd_busy || frame_wr_busy ||
                 frame_rd_en || frame_wr_en || sdr_rd_valid ||
                 sdr_busy || sdr_refresh)
            frame_quiet <= 4'd0;
        else if (frame_quiet != 4'd10)
            frame_quiet <= frame_quiet + 4'd1;
    end

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            state             <= S_IDLE;
            cmd_addr          <= {ADDR_BITS{1'b0}};
            total_recv        <= 10'd0;
            row_words_latched <= 10'd640;
            burst_sent        <= 8'd0;
            burst_recv        <= 8'd0;
            burst_target      <= 8'd0;
            line_wr_bank      <= 1'b0;
            line_ready_toggle <= 1'b0;
        end else begin
            if (line_data_valid) begin
                total_recv <= total_recv + 10'd1;
                burst_recv <= burst_recv + 8'd1;
            end
            case (state)
                S_IDLE: if (req_pulse && sdr_init_done) begin
                    // line_num/base remain stable until line_ready_toggle.
                    row_words_latched <= row_words;
                    cmd_addr     <= line_base + line_num * {{(ADDR_BITS-10){1'b0}},row_words};
                    line_wr_bank <= line_num[0];
                    total_recv   <= 10'd0;
                    state        <= S_WAIT;
                end
                S_WAIT: if (can_grant)
                    state <= S_RESERVE;
                S_RESERVE: if (video_fifo_words < 9'd192) begin
                    // A simultaneous frame burst may have drained the reserve.
                    // Release the port so the display FIFO can refill first.
                    state <= S_WAIT;
                end else if (frame_quiet == 4'd10 &&
                             !frame_rd_busy && !frame_wr_busy &&
                             !frame_rd_en && !frame_wr_en &&
                             !sdr_busy && !sdr_refresh) begin
                    burst_sent <= 8'd0;
                    burst_recv <= 8'd0;
                    burst_target <= (row_words_latched-total_recv >= 10'd128) ?
                                    8'd128 : (row_words_latched-total_recv);
                    state      <= S_ISSUE;
                end
                S_ISSUE: begin
                    cmd_addr   <= cmd_addr + {{(ADDR_BITS-1){1'b0}}, 1'b1};
                    burst_sent <= burst_sent + 8'd1;
                    if (burst_sent + 8'd1 == burst_target)
                        state <= S_DRAIN;
                end
                S_DRAIN: if (burst_recv + (line_data_valid ? 8'd1 : 8'd0) == burst_target) begin
                    if (total_recv + (line_data_valid ? 10'd1 : 10'd0) == row_words_latched) begin
                        line_ready_toggle <= ~line_ready_toggle;
                        state <= S_IDLE;
                    end else begin
                        state <= S_YIELD;
                    end
                end
                S_YIELD: state <= S_WAIT;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
