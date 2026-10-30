`timescale 1ns/1ps
// Minimal BMP280 + AHT10 acquisition for the media board.
// All sensor values remain raw. A host request snapshots the most recent
// sample and calibration bytes for a separate Ethernet query path.
module media_sensor_capture #(
    parameter integer CLK_HZ = 50000000,
    parameter [15:0] I2C_DIV = 16'd167,
    parameter integer AHT_BUSY_POLLS = 300
)(
    input  wire         clk,
    input  wire         rst,
    inout  wire         sensor_scl,
    inout  wire         sensor_sda,
    input  wire         snapshot_request_toggle,
    input  wire         snapshot_release_toggle,
    output reg          snapshot_done_toggle,
    output wire [335:0] snapshot_data
);
    localparam [4:0]
        S_BOOT             = 5'd0,
        S_DELAY            = 5'd1,
        S_BMP_ID_START     = 5'd2,
        S_BMP_ID_DONE      = 5'd3,
        S_BMP_CAL_START    = 5'd4,
        S_BMP_CAL_DONE     = 5'd5,
        S_BMP_CONFIG_START = 5'd6,
        S_BMP_CONFIG_DONE  = 5'd7,
        S_AHT_RESET_START  = 5'd8,
        S_AHT_RESET_DONE   = 5'd9,
        S_AHT_INIT_START   = 5'd10,
        S_AHT_INIT_DONE    = 5'd11,
        S_SAMPLE_BEGIN     = 5'd12,
        S_BMP_READ_START   = 5'd13,
        S_BMP_READ_DONE    = 5'd14,
        S_AHT_TRIG_START   = 5'd15,
        S_AHT_TRIG_DONE    = 5'd16,
        S_AHT_TRIG_WAIT    = 5'd17,
        S_AHT_STATUS_START = 5'd18,
        S_AHT_STATUS_DONE  = 5'd19,
        S_AHT_DATA_START   = 5'd20,
        S_AHT_DATA_DONE    = 5'd21,
        S_IO_WAIT          = 5'd23,
        S_QUERY_HOLD       = 5'd24;

    reg [4:0] state, after_io, after_delay;
    reg [31:0] delay_count;
    reg [8:0] busy_polls;
    reg [6:0] bmp_address;
    reg [7:0] bmp_id;
    reg [191:0] bmp_calibration;
    reg [47:0] bmp_raw, aht_raw;
    reg [7:0] sensor_flags;

    reg io_start;
    reg [6:0] io_address;
    reg [1:0] io_write_count;
    reg [23:0] io_write_data;
    reg [4:0] io_read_count;
    wire io_done, io_error, io_timeout;
    wire [191:0] io_read_data;

    // 50 MHz / (3 * 167) ~= 100 kHz. The standalone probe and this product
    // block use the same open-drain byte engine and bounded transfer wrapper.
    sensor_i2c_transfer #(
        .CLK_HZ(CLK_HZ), .I2C_DIV(I2C_DIV)
    ) u_i2c (
        .clk(clk), .rst(rst), .start(io_start), .address(io_address),
        .write_count(io_write_count), .write_data(io_write_data),
        .read_count(io_read_count), .busy(), .done(io_done), .error(io_error),
        .timeout_error(io_timeout), .read_data(io_read_data),
        .scl(sensor_scl), .sda(sensor_sda)
    );

    task start_transfer;
        input [6:0] address;
        input [1:0] write_count;
        input [23:0] write_data;
        input [4:0] read_count;
        input [4:0] next_state;
        begin
            io_address <= address;
            io_write_count <= write_count;
            io_write_data <= write_data;
            io_read_count <= read_count;
            io_start <= 1'b1;
            after_io <= next_state;
            state <= S_IO_WAIT;
        end
    endtask

    task wait_cycles;
        input [31:0] cycles;
        input [4:0] next_state;
        begin
            delay_count <= cycles;
            after_delay <= next_state;
            state <= S_DELAY;
        end
    endtask

    reg [1:0] request_sync, release_sync;
    reg request_seen, release_seen, snapshot_pending, snapshot_locked;
    reg [4:0] resume_state;
    wire [335:0] current_snapshot = {
        24'd0,
        aht_raw,
        bmp_raw,
        bmp_calibration,
        sensor_flags,
        bmp_id,
        {1'b0, bmp_address}
    };
    assign snapshot_data = current_snapshot;
    wire state_finishes_io = state==S_BMP_ID_DONE || state==S_BMP_CAL_DONE ||
                             state==S_BMP_CONFIG_DONE || state==S_AHT_RESET_DONE ||
                             state==S_AHT_INIT_DONE || state==S_BMP_READ_DONE ||
                             state==S_AHT_TRIG_DONE || state==S_AHT_STATUS_DONE ||
                             state==S_AHT_DATA_DONE;
    wire snapshot_pause_safe = (state!=S_IO_WAIT) && !state_finishes_io;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_BOOT;
            after_io <= S_BOOT;
            after_delay <= S_BOOT;
            delay_count <= 0;
            busy_polls <= 0;
            bmp_address <= 7'h77;
            bmp_id <= 0;
            bmp_calibration <= 0;
            bmp_raw <= 0;
            aht_raw <= 0;
            sensor_flags <= 0;
            io_start <= 0;
            io_address <= 0;
            io_write_count <= 0;
            io_write_data <= 0;
            io_read_count <= 0;
            request_sync <= 0;
            release_sync <= 0;
            request_seen <= 0;
            release_seen <= 0;
            snapshot_pending <= 0;
            snapshot_locked <= 0;
            resume_state <= S_BOOT;
            snapshot_done_toggle <= 0;
        end else begin
            io_start <= 0;
            request_sync <= {request_sync[0], snapshot_request_toggle};
            release_sync <= {release_sync[0], snapshot_release_toggle};

            if (request_sync[1] != request_seen) begin
                request_seen <= request_sync[1];
                snapshot_pending <= 1'b1;
            end

            // Freeze the sensor FSM at a transaction-safe boundary while PC
            // reads all seven packets. The sample/calibration registers are the
            // snapshot store, avoiding another 336-bit shadow register bank.
            if (snapshot_locked) begin
                if (release_sync[1] != release_seen) begin
                    release_seen <= release_sync[1];
                    snapshot_locked <= 1'b0;
                    snapshot_pending <= 1'b0;
                    state <= resume_state;
                end else state <= S_QUERY_HOLD;
            end else if (release_sync[1] != release_seen) begin
                // Consume an abort that reaches this clock domain before the
                // corresponding request has been locked.
                release_seen <= release_sync[1];
                snapshot_pending <= 1'b0;
            end else if (snapshot_pending && snapshot_pause_safe) begin
                snapshot_done_toggle <= ~snapshot_done_toggle;
                snapshot_locked <= 1'b1;
                resume_state <= state;
                state <= S_QUERY_HOLD;
            end else case (state)
                S_BOOT: wait_cycles(CLK_HZ/10, S_BMP_ID_START);
                S_DELAY: begin
                    if (delay_count != 0)
                        delay_count <= delay_count - 1'b1;
                    else state <= after_delay;
                end
                S_IO_WAIT: if (io_done) state <= after_io;

                S_BMP_ID_START:
                    start_transfer(bmp_address, 1, 24'h0000D0, 1, S_BMP_ID_DONE);
                S_BMP_ID_DONE: begin
                    if (io_error || io_read_data[7:0] != 8'h58) begin
                        if (bmp_address == 7'h77) begin
                            bmp_address <= 7'h76;
                            state <= S_BMP_ID_START;
                        end else begin
                            bmp_id <= io_read_data[7:0];
                            sensor_flags[0] <= 1'b1; // BMP280 probe/init failed
                            state <= S_AHT_RESET_START;
                        end
                    end else begin
                        bmp_id <= io_read_data[7:0];
                        sensor_flags[6] <= 1'b1; // BMP280 present
                        state <= S_BMP_CAL_START;
                    end
                end
                S_BMP_CAL_START:
                    start_transfer(bmp_address, 1, 24'h000088, 24, S_BMP_CAL_DONE);
                S_BMP_CAL_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end else bmp_calibration <= io_read_data;
                    state <= S_BMP_CONFIG_START;
                end
                S_BMP_CONFIG_START:
                    start_transfer(bmp_address, 2, 24'h0027F4, 0, S_BMP_CONFIG_DONE);
                S_BMP_CONFIG_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end
                    // Match the reference PC flow: let the BMP280 complete
                    // its first forced conversion before initializing AHT10.
                    wait_cycles(CLK_HZ/10, S_AHT_RESET_START);
                end

                S_AHT_RESET_START:
                    start_transfer(7'h38, 1, 24'h0000BA, 0, S_AHT_RESET_DONE);
                S_AHT_RESET_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end
                    wait_cycles(CLK_HZ/50, S_AHT_INIT_START);
                end
                S_AHT_INIT_START:
                    start_transfer(7'h38, 3, 24'h0008E1, 0, S_AHT_INIT_DONE);
                S_AHT_INIT_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end else sensor_flags[4] <= 1'b1; // AHT10 initialized
                    sensor_flags[7] <= 1'b1; // initial configuration complete
                    wait_cycles(CLK_HZ/2, S_SAMPLE_BEGIN);
                end

                S_SAMPLE_BEGIN: begin
                    sensor_flags[5] <= 1'b0;
                    sensor_flags[3] <= 1'b0;
                    bmp_raw <= 0;
                    aht_raw <= 0;
                    busy_polls <= 0;
                    if (sensor_flags[6]) state <= S_BMP_READ_START;
                    else state <= S_AHT_TRIG_START;
                end
                S_BMP_READ_START:
                    start_transfer(bmp_address, 1, 24'h0000F7, 6, S_BMP_READ_DONE);
                S_BMP_READ_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end else begin
                        bmp_raw <= io_read_data[47:0];
                        sensor_flags[5] <= 1'b1;
                    end
                    state <= S_AHT_TRIG_START;
                end
                S_AHT_TRIG_START:
                    start_transfer(7'h38, 3, 24'h0033AC, 0, S_AHT_TRIG_DONE);
                S_AHT_TRIG_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                        wait_cycles(CLK_HZ, S_SAMPLE_BEGIN);
                    end else wait_cycles(CLK_HZ/10, S_AHT_TRIG_WAIT);
                end
                S_AHT_TRIG_WAIT: begin
                    busy_polls <= 0;
                    state <= S_AHT_STATUS_START;
                end
                S_AHT_STATUS_START:
                    start_transfer(7'h38, 0, 0, 1, S_AHT_STATUS_DONE);
                S_AHT_STATUS_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                        wait_cycles(CLK_HZ, S_SAMPLE_BEGIN);
                    end else if (io_read_data[7]) begin
                        if (busy_polls >= AHT_BUSY_POLLS-1) begin
                            sensor_flags[2] <= 1'b1; // bounded AHT busy timeout
                            sensor_flags[0] <= 1'b1;
                            wait_cycles(CLK_HZ, S_SAMPLE_BEGIN);
                        end else begin
                            busy_polls <= busy_polls + 1'b1;
                            wait_cycles(CLK_HZ/100, S_AHT_STATUS_START);
                        end
                    end else begin
                        // The AHT10 status calibration bit is the device-side
                        // confirmation that initialization is active, even if
                        // the optional command ACK was not sampled cleanly.
                        if (io_read_data[3]) sensor_flags[4] <= 1'b1;
                        state <= S_AHT_DATA_START;
                    end
                end
                S_AHT_DATA_START:
                    start_transfer(7'h38, 0, 0, 6, S_AHT_DATA_DONE);
                S_AHT_DATA_DONE: begin
                    if (io_error) begin
                        sensor_flags[0] <= 1'b1;
                        if (io_timeout) sensor_flags[1] <= 1'b1;
                    end else begin
                        aht_raw <= io_read_data[47:0];
                        sensor_flags[3] <= 1'b1;
                    end
                    wait_cycles(CLK_HZ, S_SAMPLE_BEGIN);
                end
                default: state <= S_BOOT;
            endcase
        end
    end

    wire _unused = &{1'b0, AHT_BUSY_POLLS[8:0]};
endmodule
