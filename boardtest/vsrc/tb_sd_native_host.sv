`timescale 1ns/1ps

module tb_sd_native_host #(parameter integer FORCE_25MHZ=0);
    reg sd_clk100=0;
    reg app_clk50=0;
    always #5 sd_clk100=~sd_clk100;
    always #10 app_clk50=~app_clk50;
    reg rst=1;
    reg pll_locked=0;
    tri1 sd_cmd;
    tri1 [3:0] sd_dat;
    reg [31:0] request_lba=0;
    reg request=0;
    wire sd_clk;
    wire sd_init_done,ready;
    wire [7:0] sd_diag_flags;
    wire [15:0] init_debug_word;
    wire [31:0] last_read_cycles;
    wire [31:0] last_failure_lba;
    wire [7:0] last_failure_info;
    wire [7:0] data;
    wire data_valid,data_done,data_error;
    wire [15:0] cmd_count,cmd_crc_errors,read_count;
    reg [7:0] expected [0:511];
    reg [8*260-1:0] image_path;
    integer image_fd,image_value,expected_i,hs_expected,hc_expected,v1_expected;
    integer read_count_before,read_response_injection,bad_crc_injection,fail_cmd55;

    sd_native_adapter #(.DATA_TIMEOUT_CYCLES(1024),.FORCE_25MHZ(FORCE_25MHZ)) dut (
        .clk(app_clk50),.sd_clk_100m(sd_clk100),.pll_locked(pll_locked),.rst(rst),
        .sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat),.sd_init_done(sd_init_done),
        .sd_diag_flags(sd_diag_flags),.init_debug_word(init_debug_word),.last_read_cycles(last_read_cycles),
        .last_failure_lba(last_failure_lba),.last_failure_info(last_failure_info),
        .stream_debug(),
        .o_lba(request_lba),.o_req(request),.i_ready(ready),.i_data(data),
        .i_dval(data_valid),.i_done(data_done),.i_err(data_error)
    );

    sd_native_card_model card (
        .sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat),.cmd_count(cmd_count),
        .cmd_crc_errors(cmd_crc_errors),.read_count(read_count)
    );

    task automatic request_read(input [31:0] lba,input use_image);
        integer j,wait_cycles;
        reg [7:0] expected_byte;
        begin
            wait(ready);
            @(negedge app_clk50);request_lba=lba;request=1;
            @(negedge app_clk50);request=0;
            j=0;wait_cycles=0;
            while(j<512 && wait_cycles<200000) begin
                @(posedge app_clk50);#1;wait_cycles=wait_cycles+1;
                if(data_error) $fatal(1,"SD adapter returned error for LBA %0d",lba);
                if(data_valid) begin
                    if(use_image) expected_byte=expected[j];
                    else expected_byte=lba[7:0]^j[7:0]^(j[8]?8'hA5:8'h00);
                    if(data!==expected_byte)
                        $fatal(1,"LBA %0d byte %0d got %02x expected %02x",lba,j,data,expected_byte);
                    if(j==511 && !data_done) $fatal(1,"last byte was not marked done");
                    j=j+1;
                end else if(data_done) $fatal(1,"sector ended after %0d of 512 bytes",j);
            end
            if(j!=512) $fatal(1,"LBA %0d timeout bytes=%0d host=%0d data_count=%0d bus4=%0b card=%0d/%0d crc=%h recv=%h",
                lba,j,dut.u_host.state,dut.u_host.data_count,dut.u_host.data_bus_4bit,
                card.data_phase,card.data_position,dut.u_host.lane_crc0,dut.u_host.lane_recv0);
            $display("PASS: LBA %0d adapter stream and CRC",lba);
        end
    endtask

    task automatic expect_read_error(input [31:0] lba);
        integer j,wait_cycles;
        begin
            wait(ready);
            @(negedge app_clk50);request_lba=lba;request=1;
            @(negedge app_clk50);request=0;
            j=0;wait_cycles=0;
            while(!data_error && wait_cycles<200000) begin
                @(posedge app_clk50);#1;wait_cycles=wait_cycles+1;
                if(data_valid) j=j+1;
            end
            if(!data_error) $fatal(1,"persistent CRC error did not return i_err");
            if(j!=0) $fatal(1,"adapter exposed %0d bytes from a bad sector",j);
            if(last_failure_lba!==lba || last_failure_info[7:4]!==4'd3 ||
               last_failure_info[3:2]!==2'd2)
                $fatal(1,"failed read diagnostics LBA=%0d code=%0d retries=%0d",
                    last_failure_lba,last_failure_info[7:4],last_failure_info[3:2]);
            $display("PASS: bad LBA %0d withheld and reported",lba);
        end
    endtask

    task automatic wait_for_card_init;
        integer t;
        begin
            t=0;
            while(!sd_init_done && t<2000000) begin @(posedge app_clk50);t=t+1;end
            if(!sd_init_done) begin
                $display("init diagnostics state=%0d cmd=%0d err=%0b resp=%h card_cmds=%0d card_crc=%0d",
                    dut.u_host.state,dut.u_host.cmd_index,dut.u_host.cmd_error,
                    dut.u_host.cmd_response,cmd_count,cmd_crc_errors);
                $fatal(1,"SD initialization timeout; host state=%0d",dut.u_host.state);
            end
        end
    endtask

    initial begin
        $display("FORCE_25MHZ=%0d",FORCE_25MHZ);
        image_path="../img/card_user_real.img";
        if($value$plusargs("CARD=%s",image_path)) begin end
        image_fd=$fopen(image_path,"rb");
        if(image_fd==0) $fatal(1,"cannot open real card image: %0s",image_path);
        for(expected_i=0;expected_i<512;expected_i=expected_i+1) begin
            image_value=$fgetc(image_fd);
            if(image_value<0) $fatal(1,"card image ended before LBA0 byte %0d",expected_i);
            expected[expected_i]=image_value[7:0];
        end
        $fclose(image_fd);

        hs_expected=1;
        if($value$plusargs("HS=%d",hs_expected)) begin end
        hc_expected=1;
        if($value$plusargs("HC=%d",hc_expected)) begin end
        v1_expected=0;
        if($value$plusargs("V1=%d",v1_expected)) begin end
        if(v1_expected)begin hs_expected=0;hc_expected=0;end
        fail_cmd55=0;
        if($value$plusargs("DROP_CMD55=%d",fail_cmd55)) begin end
        read_response_injection=0;bad_crc_injection=0;
        if($value$plusargs("DROP_READ_RESPONSE=%d",read_response_injection)) begin end
        if($value$plusargs("BAD_CRC_ONCE=%d",bad_crc_injection)) begin end

        repeat(8) @(posedge sd_clk100);
        rst=0;pll_locked=1;
        if(fail_cmd55) begin
            read_count_before=0;
            while(dut.u_host.state!=6'd36 && read_count_before<300000) begin
                @(posedge sd_clk100);read_count_before=read_count_before+1;
            end
            repeat(4) @(posedge app_clk50);
            if(dut.u_host.state!=6'd36 || sd_init_done)
                $fatal(1,"missing CMD55 response did not produce init failure");
            if(init_debug_word[15:10]!=6'd63 || init_debug_word[9:8]!=2'b00 ||
               init_debug_word[7:0]!=8'hFF)
                $fatal(1,"CMD diagnostic word=%04x expected no TX mismatch and an all-high CMD response",init_debug_word);
            $display("PASS: CMD55 timeout diagnostics mismatch_pos=%0d response_samples=%02x",
                init_debug_word[15:10],init_debug_word[7:0]);
            $finish;
        end
        wait_for_card_init();
        if(cmd_crc_errors!=0) $fatal(1,"card model saw %0d bad command CRCs",cmd_crc_errors);
        if(dut.u_host.high_capacity!==(hc_expected!=0))
            $fatal(1,"card OCR CCS mismatch: got %0b expected %0d",dut.u_host.high_capacity,hc_expected);
        if(dut.u_host.high_speed_supported!==(hs_expected!=0) ||
           dut.u_host.high_speed_active!==(hs_expected!=0))
            $fatal(1,"High Speed negotiation mismatch: support=%0b active=%0b expected=%0d",
                dut.u_host.high_speed_supported,dut.u_host.high_speed_active,hs_expected);
        $display("PASS: native init, bus4=%0b HC=%0b High Speed active=%0b",
            dut.u_host.data_bus_4bit,dut.u_host.high_capacity,dut.u_host.high_speed_active);

        // Drop the first CMD17 response, delay the second response, and corrupt
        // one data CRC.  The third attempt must match the real image's LBA0.
        request_read(32'd0,1'b1);
        if(read_count<(1+read_response_injection+bad_crc_injection))
            $fatal(1,"expected injected response/CRC retries; read_count=%0d",read_count);
        request_read(32'h00001234,1'b0);

        // No data token once: the host must retry without exposing a partial block.
        card.drop_data_token_once=1;
        read_count_before=read_count;
        request_read(32'h00002345,1'b0);
        if(read_count-read_count_before<2) $fatal(1,"data-token timeout did not retry");

        // Persistent CRC corruption must stop after exactly three CMD17 tries
        // and must never send unverified bytes to FAT32.
        card.bad_crc_always=1;
        read_count_before=read_count;
        expect_read_error(32'h00003456);
        if(read_count-read_count_before!=3)
            $fatal(1,"CRC retry bound expected 3 reads, observed %0d",read_count-read_count_before);
        card.bad_crc_always=0;

        // Reset while the card withholds a data token; the following CMD0 and
        // fresh initialization must restore usable 4-bit card operation.
        card.drop_data_token_once=1;
        wait(ready);
        @(negedge app_clk50);request_lba=32'h00004567;request=1;
        @(negedge app_clk50);request=0;
        wait(dut.u_host.state==6'd32);
        repeat(3) @(posedge sd_clk100);
        rst=1;pll_locked=0;
        repeat(8) @(posedge sd_clk100);
        rst=0;pll_locked=1;
        wait_for_card_init();
        if(cmd_crc_errors!=0) $fatal(1,"command CRC error after transaction reset");
        request_read(32'd0,1'b1);
        $display("PASS: transaction reset and reinitialization");
        $display("SD_NATIVE_HOST_PASS commands=%0d reads=%0d last_read_100m_cycles=%0d",
            cmd_count,read_count,dut.u_host.last_read_cycles);
        $finish;
    end

    initial begin
        #500_000_000;
        $fatal(1,"testbench watchdog timeout; host state=%0d",dut.u_host.state);
    end
endmodule
