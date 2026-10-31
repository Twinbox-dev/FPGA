`timescale 1ns/1ps
module tb_media_sensor_capture;
    reg clk = 0;
    always #10 clk = ~clk;
    reg rst = 1;
    tri1 scl, sda;
    reg slave_low = 0;
    assign sda = slave_low ? 1'b0 : 1'bz;
    reg snapshot_request_toggle = 0;
    reg snapshot_release_toggle = 0;
    wire snapshot_done_toggle;
    wire [335:0] snapshot_data;

    media_sensor_capture #(.CLK_HZ(1_000_000), .I2C_DIV(2), .AHT_BUSY_POLLS(40)) dut (
        .clk(clk), .rst(rst), .sensor_scl(scl), .sensor_sda(sda),
        .snapshot_request_toggle(snapshot_request_toggle),
        .snapshot_release_toggle(snapshot_release_toggle),
        .snapshot_done_toggle(snapshot_done_toggle), .snapshot_data(snapshot_data)
    );

    reg [191:0] calibration;
    reg [191:0] bmp_data;
    reg [47:0] aht_data;
    integer aht_status_reads = 0;
    integer bmp_raw_reads = 0;

    task automatic wait_start;
        begin
            @(negedge sda);
            if (scl !== 1'b1) $fatal(1, "START while SCL low");
        end
    endtask

    task automatic wait_stop;
        begin
            @(posedge sda);
            if (scl !== 1'b1) $fatal(1, "STOP while SCL low");
        end
    endtask

    task automatic expect_byte(input [7:0] expected, input bit ack);
        reg [7:0] value;
        integer k;
        begin
            for (k=7; k>=0; k=k-1) begin
                @(posedge scl); value[k] = sda; @(negedge scl);
            end
            if (value !== expected) $fatal(1, "I2C write %02h expected %02h", value, expected);
            slave_low = ack; @(posedge scl); @(negedge scl); slave_low = 0;
        end
    endtask

    task automatic send_byte(input [7:0] value, input bit nack);
        integer k;
        begin
            for (k=7; k>=0; k=k-1) begin
                slave_low = !value[k]; @(posedge scl); @(negedge scl);
            end
            slave_low = 0; @(posedge scl);
            if (sda !== nack) $fatal(1, "I2C read ACK/NACK mismatch");
            @(negedge scl);
        end
    endtask

    task automatic read_bmp(input [7:0] regno, input integer count, input [191:0] bytes);
        integer k;
        begin
            wait_start(); expect_byte(8'hEE, 1); expect_byte(regno, 1);
            wait_start(); expect_byte(8'hEF, 1);
            for (k=0; k<count; k=k+1) send_byte(bytes[k*8 +: 8], k==count-1);
            wait_stop();
            if (regno == 8'hF7) bmp_raw_reads = bmp_raw_reads + 1;
        end
    endtask

    task automatic write_bmp(input [7:0] regno, input [7:0] value);
        begin
            wait_start(); expect_byte(8'hEE, 1); expect_byte(regno, 1);
            expect_byte(value, 1); wait_stop();
        end
    endtask

    task automatic write_aht(input integer count, input [23:0] bytes);
        integer k;
        begin
            wait_start(); expect_byte(8'h70, 1);
            for (k=0; k<count; k=k+1) expect_byte(bytes[k*8 +: 8], 1);
            wait_stop();
        end
    endtask

    task automatic read_aht_status(input [7:0] status_byte);
        begin
            wait_start(); expect_byte(8'h71, 1); send_byte(status_byte, 1); wait_stop();
            aht_status_reads = aht_status_reads + 1;
        end
    endtask

    task automatic read_aht_data(input [47:0] bytes);
        integer k;
        begin
            wait_start(); expect_byte(8'h71, 1);
            for (k=0; k<6; k=k+1) send_byte(bytes[k*8 +: 8], k==5);
            wait_stop();
        end
    endtask

    initial begin
        calibration = 0;
        calibration[191:0] = 192'h17161514131211100F0E0D0C0B0A09080706050403020100;
        bmp_data = 0;
        bmp_data[47:0] = 48'h665544332211;
        aht_data = 48'h554433221118;

        repeat (5) @(negedge clk);
        rst = 0;

        read_bmp(8'hD0, 1, 192'h58);
        read_bmp(8'h88, 24, calibration);
        write_bmp(8'hF4, 8'h27);
        write_aht(1, 24'h0000BA);
        write_aht(3, 24'h0008E1);
        read_bmp(8'hF7, 6, bmp_data);
        write_aht(3, 24'h0033AC);
        read_aht_status(8'h98);
        read_aht_status(8'h18);
        read_aht_data(aht_data);

        wait (dut.sensor_flags[3] == 1'b1);
        @(negedge clk);
        snapshot_request_toggle = ~snapshot_request_toggle;
        wait (snapshot_done_toggle == snapshot_request_toggle);
        #1;

        if (snapshot_data[7:0] !== 8'h77 || snapshot_data[15:8] !== 8'h58)
            $fatal(1, "BMP address/ID mismatch: %h %h", snapshot_data[7:0], snapshot_data[15:8]);
        if (snapshot_data[23:16] !== 8'hF8)
            $fatal(1, "sensor flags mismatch: %h", snapshot_data[23:16]);
        if (snapshot_data[215:24] !== calibration)
            $fatal(1, "BMP calibration snapshot mismatch");
        if (snapshot_data[263:216] !== bmp_data[47:0])
            $fatal(1, "BMP raw snapshot mismatch");
        if (snapshot_data[311:264] !== aht_data)
            $fatal(1, "AHT raw snapshot mismatch");
        if (snapshot_data[335:312] !== 24'd0)
            $fatal(1, "reserved bytes are not zero");
        if (aht_status_reads != 2 || bmp_raw_reads != 1)
            $fatal(1, "unexpected sample counts AHT=%0d BMP=%0d", aht_status_reads, bmp_raw_reads);

        @(negedge clk);
        snapshot_release_toggle = ~snapshot_release_toggle;
        wait(dut.snapshot_locked == 1'b0);

        $display("PASS media sensor capture: BMP280 ID/calibration/config/raw; AHT10 reset/init/busy/raw; coherent 42-byte snapshot");
        $finish;
    end

    initial begin
        #1_000_000_000;
        $fatal(1, "watchdog: sensor state=%0d", dut.state);
    end
endmodule
