// One I2C command at a time. Both pins are open drain; the board needs pull-ups.
// A bit takes three DIV clock periods (setup, SCL high, sample/fall).
module gt911_i2c_byte #(
    parameter [15:0] DIV = 16'd1333 // 100 MHz / (3 * 1333) ~= 25 kHz
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       cmd_valid,
    input  wire [1:0] cmd,       // 0 START, 1 STOP, 2 WRITE, 3 READ
    input  wire [7:0] tx_data,
    input  wire       read_nack, // release SDA on ninth clock when reading
    output reg        busy,
    output reg        done,
    output reg        ack_ok,
    output reg  [7:0] rx_data,
    inout  wire       scl,
    inout  wire       sda
);
    localparam [3:0] IDLE = 0, START_RELEASE = 1, START_HIGH = 2,
        START_FALL = 3, START_LOW = 4, STOP_LOW = 5, STOP_HIGH = 6,
        STOP_RELEASE = 7, BIT_SETUP = 8, BIT_RISE = 9, BIT_SAMPLE = 10,
        ACK_SETUP = 11, ACK_RISE = 12, ACK_SAMPLE = 13;
    reg [3:0] state;
    reg [15:0] divider;
    reg [2:0] bit_index;
    reg [7:0] shift_out, shift_in;
    reg reading, nack_after_read;
    reg scl_low, sda_low;
    reg scl_s0, scl_s1, sda_s0, sda_s1;
    wire tick = (divider == DIV - 16'd1);

    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            divider <= 16'd0;
            bit_index <= 3'd0;
            shift_out <= 8'd0;
            shift_in <= 8'd0;
            reading <= 1'b0;
            nack_after_read <= 1'b0;
            scl_low <= 1'b0;
            sda_low <= 1'b0;
            scl_s0 <= 1'b1;
            scl_s1 <= 1'b1;
            sda_s0 <= 1'b1;
            sda_s1 <= 1'b1;
            busy <= 1'b0;
            done <= 1'b0;
            ack_ok <= 1'b1;
            rx_data <= 8'd0;
        end else begin
            scl_s0 <= scl;
            scl_s1 <= scl_s0;
            sda_s0 <= sda;
            sda_s1 <= sda_s0;
            done <= 1'b0;
            if (!busy) begin
                divider <= 16'd0;
                if (cmd_valid) begin
                    busy <= 1'b1;
                    shift_out <= tx_data;
                    shift_in <= 8'd0;
                    bit_index <= 3'd7;
                    reading <= (cmd == 2'd3);
                    nack_after_read <= read_nack;
                    ack_ok <= 1'b1;
                    case (cmd)
                        2'd0: state <= START_RELEASE;
                        2'd1: state <= STOP_LOW;
                        default: state <= BIT_SETUP;
                    endcase
                end
            end else if (tick) begin
                divider <= 16'd0;
                case (state)
                    START_RELEASE: begin
                        sda_low <= 1'b0;
                        state <= START_HIGH;
                    end
                    START_HIGH: begin
                        scl_low <= 1'b0;
                        state <= START_FALL;
                    end
                    START_FALL: if (scl_s1) begin
                        sda_low <= 1'b1;
                        state <= START_LOW;
                    end
                    START_LOW: begin
                        scl_low <= 1'b1;
                        state <= IDLE;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    STOP_LOW: begin
                        scl_low <= 1'b1;
                        sda_low <= 1'b1;
                        state <= STOP_HIGH;
                    end
                    STOP_HIGH: begin
                        scl_low <= 1'b0;
                        state <= STOP_RELEASE;
                    end
                    STOP_RELEASE: if (scl_s1) begin
                        sda_low <= 1'b0;
                        state <= IDLE;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    BIT_SETUP: begin
                        scl_low <= 1'b1;
                        sda_low <= reading ? 1'b0 : !shift_out[7];
                        state <= BIT_RISE;
                    end
                    BIT_RISE: begin
                        scl_low <= 1'b0;
                        state <= BIT_SAMPLE;
                    end
                    BIT_SAMPLE: if (scl_s1) begin
                        if (reading) shift_in <= {shift_in[6:0], sda_s1};
                        else shift_out <= {shift_out[6:0], 1'b0};
                        scl_low <= 1'b1;
                        if (bit_index == 3'd0) state <= ACK_SETUP;
                        else begin
                            bit_index <= bit_index - 3'd1;
                            state <= BIT_SETUP;
                        end
                    end
                    ACK_SETUP: begin
                        sda_low <= reading && !nack_after_read;
                        state <= ACK_RISE;
                    end
                    ACK_RISE: begin
                        scl_low <= 1'b0;
                        state <= ACK_SAMPLE;
                    end
                    ACK_SAMPLE: if (scl_s1) begin
                        if (reading) rx_data <= shift_in;
                        else ack_ok <= !sda_s1;
                        scl_low <= 1'b1;
                        sda_low <= 1'b0;
                        state <= IDLE;
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                    default: state <= IDLE;
                endcase
            end else divider <= divider + 16'd1;
        end
    end
endmodule
