// GT911 polling and one-finger relative pointer. INT/RST are intentionally
// unused: the module probes the only two GT911 addresses after power-up.
module gt911_trackpad #(
    parameter [15:0] I2C_DIV = 16'd1333,
    parameter [23:0] BOOT_CYCLES = 24'd10000000, // 100 ms at 100 MHz
    parameter [23:0] POLL_CYCLES = 24'd2000000,  // 20 ms at 100 MHz
    parameter [23:0] RETRY_CYCLES = 24'd5000000
)(
    input  wire        clk,
    input  wire        rst,
    inout  wire        scl,
    inout  wire        sda,
    input  wire        cursor_ack_toggle, // synchronized back from video domain
    output reg         cursor_req_toggle,
    output reg  [10:0] cursor_mailbox_x,
    output reg  [9:0]  cursor_mailbox_y,
    output reg         online,
    output reg         touch_report,      // one clock on a fresh point report
    output reg         touch_down,
    output reg         swipe_next,        // one pulse on leftward release
    output reg         swipe_prev,        // one pulse on rightward release
    output reg  [10:0] cursor_x,
    output reg  [9:0]  cursor_y
);
    localparam [1:0] PROBE = 0, STATUS = 1, POINT = 2, CLEAR = 3;
    localparam [2:0] WAIT_DELAY = 0, LAUNCH = 1, ISSUE = 2,
        WAIT_BYTE = 3, COMPLETE = 4;
    reg [2:0] state;
    reg [1:0] job;
    reg [6:0] address;
    reg [3:0] step;
    reg [23:0] delay_count;
    reg [39:0] payload;
    reg txn_error;

    wire [15:0] reg_addr = (job == PROBE) ? 16'h8140 :
                           (job == POINT) ? 16'h814f : 16'h814e;
    wire [2:0] read_len = (job == PROBE) ? 3'd4 :
                          (job == STATUS) ? 3'd1 : 3'd5;
    wire [3:0] last_step = (job == CLEAR) ? 4'd5 :
                           (4'd6 + {1'b0, read_len});
    reg [1:0] byte_cmd;
    reg [7:0] byte_tx;
    reg byte_nack;
    reg byte_valid;
    wire byte_busy, byte_done, byte_ack;
    wire [7:0] byte_rx;

    always @* begin
        byte_cmd = 2'd2; // WRITE
        byte_tx = 8'd0;
        byte_nack = 1'b0;
        if (step == 4'd0 || ((job != CLEAR) && step == 4'd4))
            byte_cmd = 2'd0; // START / repeated START
        else if (step == last_step)
            byte_cmd = 2'd1; // STOP
        else if ((job != CLEAR) && step >= 4'd6) begin
            byte_cmd = 2'd3; // READ
            byte_nack = (step == last_step - 4'd1);
        end else begin
            case (step)
                4'd1: byte_tx = {address, 1'b0};
                4'd2: byte_tx = reg_addr[15:8];
                4'd3: byte_tx = reg_addr[7:0];
                4'd5: byte_tx = {address, 1'b1};
                default: byte_tx = 8'd0; // CLEAR writes zero at step 4
            endcase
        end
    end

    gt911_i2c_byte #(.DIV(I2C_DIV)) u_i2c (
        .clk(clk), .rst(rst), .cmd_valid(byte_valid), .cmd(byte_cmd),
        .tx_data(byte_tx), .read_nack(byte_nack), .busy(byte_busy),
        .done(byte_done), .ack_ok(byte_ack), .rx_data(byte_rx),
        .scl(scl), .sda(sda)
    );

    // The first byte of a point record is its tracking ID, followed by X/Y.
    wire [7:0] point_id = payload[39:32];
    wire [15:0] point_x = {payload[23:16], payload[31:24]};
    wire [15:0] point_y = {payload[7:0], payload[15:8]};
    reg finger_active;
    reg [7:0] prev_id;
    reg [9:0] prev_x, prev_y;
    reg gesture_valid;
    reg [4:0] gesture_samples;
    reg [9:0] gesture_start_x, gesture_start_y;
    reg [9:0] gesture_last_x, gesture_last_y;
    wire signed [10:0] gesture_dx =
        $signed({1'b0, gesture_last_x}) - $signed({1'b0, gesture_start_x});
    wire signed [10:0] gesture_dy =
        $signed({1'b0, gesture_last_y}) - $signed({1'b0, gesture_start_y});
    wire [10:0] gesture_abs_y = gesture_dy[10] ?
                                  (~gesture_dy + 11'd1) : gesture_dy;
    wire signed [10:0] dx = $signed({1'b0, point_x[9:0]}) -
                             $signed({1'b0, prev_x});
    wire signed [10:0] dy = $signed({1'b0, point_y[9:0]}) -
                             $signed({1'b0, prev_y});
    wire signed [12:0] next_x = $signed({2'b00, cursor_x}) +
                                 ({{2{dx[10]}}, dx} <<< 1);
    wire signed [12:0] next_y = $signed({3'b000, cursor_y}) +
                                 ({{2{dy[10]}}, dy} <<< 1);

    // The mailbox remains unchanged until video has acknowledged its toggle.
    // This keeps the multi-bit X/Y bus stable while it crosses the clock domain.
    reg ack_s0, ack_s1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= WAIT_DELAY;
            job <= PROBE;
            address <= 7'h5d;
            step <= 4'd0;
            delay_count <= BOOT_CYCLES;
            payload <= 40'd0;
            txn_error <= 1'b0;
            byte_valid <= 1'b0;
            online <= 1'b0;
            touch_report <= 1'b0;
            touch_down <= 1'b0;
            swipe_next <= 1'b0;
            swipe_prev <= 1'b0;
            finger_active <= 1'b0;
            prev_id <= 8'd0;
            prev_x <= 10'd0;
            prev_y <= 10'd0;
            gesture_valid <= 1'b0;
            gesture_samples <= 5'd0;
            gesture_start_x <= 10'd0;
            gesture_start_y <= 10'd0;
            gesture_last_x <= 10'd0;
            gesture_last_y <= 10'd0;
            cursor_x <= 11'd640;
            cursor_y <= 10'd360;
            cursor_mailbox_x <= 11'd640;
            cursor_mailbox_y <= 10'd360;
            cursor_req_toggle <= 1'b0;
            ack_s0 <= 1'b0;
            ack_s1 <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            touch_report <= 1'b0;
            swipe_next <= 1'b0;
            swipe_prev <= 1'b0;
            ack_s0 <= cursor_ack_toggle;
            ack_s1 <= ack_s0;
            if (ack_s1 == cursor_req_toggle &&
                (cursor_x != cursor_mailbox_x || cursor_y != cursor_mailbox_y)) begin
                cursor_mailbox_x <= cursor_x;
                cursor_mailbox_y <= cursor_y;
                cursor_req_toggle <= ~cursor_req_toggle;
            end
            case (state)
                WAIT_DELAY: if (delay_count == 24'd0) state <= LAUNCH;
                            else delay_count <= delay_count - 24'd1;
                LAUNCH: begin
                    step <= 4'd0;
                    payload <= 40'd0;
                    txn_error <= 1'b0;
                    state <= ISSUE;
                end
                ISSUE: if (!byte_busy) begin
                    byte_valid <= 1'b1;
                    state <= WAIT_BYTE;
                end
                WAIT_BYTE: if (byte_done) begin
                    if (byte_cmd == 2'd2 && !byte_ack) begin
                        txn_error <= 1'b1;
                        step <= last_step;
                        state <= ISSUE;
                    end else begin
                        if (byte_cmd == 2'd3)
                            payload <= {payload[31:0], byte_rx};
                        if (step == last_step) state <= COMPLETE;
                        else begin
                            step <= step + 4'd1;
                            state <= ISSUE;
                        end
                    end
                end
                COMPLETE: begin
                    if (txn_error || (job == PROBE &&
                                      payload[31:8] != 24'h393131)) begin
                        online <= 1'b0;
                        touch_down <= 1'b0;
                        finger_active <= 1'b0;
                        gesture_valid <= 1'b0;
                        job <= PROBE;
                        if (address == 7'h5d) begin
                            address <= 7'h14;
                            state <= LAUNCH;
                        end else begin
                            address <= 7'h5d;
                            delay_count <= RETRY_CYCLES;
                            state <= WAIT_DELAY;
                        end
                    end else begin
                        case (job)
                            PROBE: begin
                                online <= 1'b1;
                                job <= STATUS;
                                state <= LAUNCH;
                            end
                            STATUS: begin
                                if (!payload[7]) begin
                                    delay_count <= POLL_CYCLES;
                                    state <= WAIT_DELAY;
                                end else if (payload[3:0] == 4'd1) begin
                                    job <= POINT;
                                    state <= LAUNCH;
                                end else begin
                                    // Commit a quick horizontal swipe once,
                                    // only when the card reports zero contacts.
                                    if (payload[3:0] == 4'd0 &&
                                        gesture_valid && finger_active &&
                                        gesture_samples >= 5'd2 &&
                                        gesture_samples <= 5'd24 &&
                                        gesture_abs_y <= 11'd80) begin
                                        if (gesture_dx <= -11'sd160)
                                            swipe_next <= 1'b1;
                                        else if (gesture_dx >= 11'sd160)
                                            swipe_prev <= 1'b1;
                                    end
                                    touch_down <= 1'b0;
                                    finger_active <= 1'b0;
                                    gesture_valid <= 1'b0;
                                    job <= CLEAR;
                                    state <= LAUNCH;
                                end
                            end
                            POINT: begin
                                if (point_x < 16'd1024 && point_y < 16'd1024) begin
                                    touch_report <= 1'b1;
                                    touch_down <= 1'b1;
                                    if (!finger_active) begin
                                        gesture_valid <= 1'b1;
                                        gesture_samples <= 5'd0;
                                        gesture_start_x <= point_x[9:0];
                                        gesture_start_y <= point_y[9:0];
                                        gesture_last_x <= point_x[9:0];
                                        gesture_last_y <= point_y[9:0];
                                    end else if (point_id != prev_id ||
                                                 dx > 11'sd96 || dx < -11'sd96 ||
                                                 dy > 11'sd96 || dy < -11'sd96) begin
                                        gesture_valid <= 1'b0;
                                    end else if (gesture_valid) begin
                                        gesture_last_x <= point_x[9:0];
                                        gesture_last_y <= point_y[9:0];
                                        if (gesture_samples != 5'd31)
                                            gesture_samples <= gesture_samples + 5'd1;
                                    end
                                    if (!finger_active || point_id != prev_id ||
                                        dx > 11'sd96 || dx < -11'sd96 ||
                                        dy > 11'sd96 || dy < -11'sd96) begin
                                        // New contact or implausible jump: anchor only.
                                        prev_x <= point_x[9:0];
                                        prev_y <= point_y[9:0];
                                        prev_id <= point_id;
                                        finger_active <= 1'b1;
                                    end else begin
                                        if (dx >= 11'sd2 || dx <= -11'sd2) begin
                                            prev_x <= point_x[9:0];
                                            cursor_x <= (next_x < 13'sd0) ? 11'd0 :
                                                        (next_x > 13'sd1279) ? 11'd1279 :
                                                        next_x[10:0];
                                        end
                                        if (dy >= 11'sd2 || dy <= -11'sd2) begin
                                            prev_y <= point_y[9:0];
                                            cursor_y <= (next_y < 13'sd0) ? 10'd0 :
                                                        (next_y > 13'sd719) ? 10'd719 :
                                                        next_y[9:0];
                                        end
                                    end
                                end else begin
                                    touch_down <= 1'b0;
                                    finger_active <= 1'b0;
                                    gesture_valid <= 1'b0;
                                end
                                job <= CLEAR;
                                state <= LAUNCH;
                            end
                            default: begin // CLEAR
                                job <= STATUS;
                                delay_count <= POLL_CYCLES;
                                state <= WAIT_DELAY;
                            end
                        endcase
                    end
                end
                default: state <= WAIT_DELAY;
            endcase
        end
    end
endmodule
