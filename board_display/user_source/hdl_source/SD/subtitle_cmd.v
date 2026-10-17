// Subtitle upload over the existing verified command-byte stream.
// Transport framing remains [byte, ~byte] on both UART and Ethernet.
// Transaction: 'T', length^0x80, (ASCII|0x80)*length, checksum hi/lo nibbles
// as 0x80|nibble. XOR is over the decoded length and ASCII bytes. Encoded
// payload never equals a normal control command if a UDP packet is lost.
module subtitle_cmd #(
    parameter MAX_CHARS = 160,
    parameter TIMEOUT_CYCLES = 10_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] cmd,
    input  wire       cmd_val,
    input  wire       swap_ack_toggle_raw,
    output wire       consume_cmd,
    output reg        wr_en,
    output reg  [7:0] wr_index,
    output reg  [7:0] wr_char,
    output reg        commit_toggle,
    output reg  [7:0] commit_len,
    output reg        ack_pulse,
    output reg        ack_ok
);
    localparam [2:0] IDLE = 3'd0, GET_LEN = 3'd1,
                     GET_DATA = 3'd2, GET_SUM_H = 3'd3,
                     GET_SUM_L = 3'd4;
    reg [2:0] state;
    reg [7:0] text_len, next_index, checksum;
    reg [3:0] sum_hi;
    reg [23:0] idle_cycles;
    reg swap_pending;
    reg ack_s0, ack_s1, ack_s2;
    wire swap_ack_pulse = ack_s1 ^ ack_s2;

    assign consume_cmd = (state != IDLE) || (cmd_val && cmd == 8'h54);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            text_len <= 8'd0;
            next_index <= 8'd0;
            checksum <= 8'd0;
            sum_hi <= 4'd0;
            idle_cycles <= 24'd0;
            swap_pending <= 1'b0;
            ack_s0 <= 1'b0; ack_s1 <= 1'b0; ack_s2 <= 1'b0;
            wr_en <= 1'b0; wr_index <= 8'd0; wr_char <= 8'd0;
            commit_toggle <= 1'b0; commit_len <= 8'd0;
            ack_pulse <= 1'b0; ack_ok <= 1'b0;
        end else begin
            ack_s0 <= swap_ack_toggle_raw;
            ack_s1 <= ack_s0;
            ack_s2 <= ack_s1;
            if (swap_ack_pulse) swap_pending <= 1'b0;
            wr_en <= 1'b0;
            ack_pulse <= 1'b0;

            if (state == IDLE || cmd_val)
                idle_cycles <= 24'd0;
            else if (idle_cycles >= TIMEOUT_CYCLES - 1) begin
                state <= IDLE;
                idle_cycles <= 24'd0;
                ack_pulse <= 1'b1;
                ack_ok <= 1'b0;
            end else
                idle_cycles <= idle_cycles + 24'd1;

            if (cmd_val) begin
                case (state)
                    IDLE: if (cmd == 8'h54) begin
                        if (swap_pending && !swap_ack_pulse) begin
                            ack_pulse <= 1'b1;
                            ack_ok <= 1'b0;
                        end else begin
                            state <= GET_LEN;
                            next_index <= 8'd0;
                            checksum <= 8'd0;
                        end
                    end
                    GET_LEN: if ((cmd ^ 8'h80) <= MAX_CHARS) begin
                        text_len <= cmd ^ 8'h80;
                        checksum <= cmd ^ 8'h80;
                        state <= ((cmd ^ 8'h80) == 8'd0) ? GET_SUM_H : GET_DATA;
                    end else begin
                        state <= IDLE;
                        ack_pulse <= 1'b1;
                        ack_ok <= 1'b0;
                    end
                    GET_DATA: if (cmd[7]) begin
                        wr_en <= 1'b1;
                        wr_index <= next_index;
                        wr_char <= (cmd[6:0] >= 7'h20 && cmd[6:0] <= 7'h7e) ?
                                   {1'b0, cmd[6:0]} : 8'h20;
                        checksum <= checksum ^ {1'b0, cmd[6:0]};
                        next_index <= next_index + 8'd1;
                        if (next_index + 8'd1 == text_len)
                            state <= GET_SUM_H;
                    end else begin
                        state <= IDLE;
                        ack_pulse <= 1'b1;
                        ack_ok <= 1'b0;
                    end
                    GET_SUM_H: if (cmd[7:4] == 4'h8) begin
                        sum_hi <= cmd[3:0];
                        state <= GET_SUM_L;
                    end else begin
                        state <= IDLE;
                        ack_pulse <= 1'b1;
                        ack_ok <= 1'b0;
                    end
                    GET_SUM_L: begin
                        state <= IDLE;
                        ack_pulse <= 1'b1;
                        ack_ok <= (cmd[7:4] == 4'h8 && {sum_hi, cmd[3:0]} == checksum);
                        if (cmd[7:4] == 4'h8 && {sum_hi, cmd[3:0]} == checksum) begin
                            commit_len <= text_len;
                            commit_toggle <= ~commit_toggle;
                            swap_pending <= 1'b1;
                        end
                    end
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
