`timescale 1ns/1ps

// Pin-level, read-only native SD memory card model for the media-board host.
// CMD6 group-1 support/current-function fields use stream positions derived
// from the SD Association Physical Layer Simplified Specification.
// It speaks CMD/R1/R2/R3, CMD6 status blocks, 4-bit CMD17 data and per-lane
// CRC16.  The first sector is read from CARD=... (binary); other LBAs use a
// deterministic pattern so address conversion can be checked independently.
module sd_native_card_model (
    input  wire       sd_clk,
    inout  wire       sd_cmd,
    inout  wire [3:0] sd_dat,
    output reg [15:0] cmd_count,
    output reg [15:0] cmd_crc_errors,
    output reg [15:0] read_count
);
    reg cmd_drive, cmd_value;
    reg dat_drive;
    reg [3:0] dat_value;
    assign sd_cmd = cmd_drive ? cmd_value : 1'bz;
    assign sd_dat = dat_drive ? dat_value : 4'hF;

    reg [47:0] cmd_shift;
    integer cmd_bits;
    reg cmd_collect;
    reg [135:0] response_frame;
    integer response_length;
    integer response_position;
    reg response_pending, response_active;
    integer response_delay_count;
    reg response_after_data;
    reg [31:0] data_lba;
    reg data_is_switch_status, data_switch_mode;
    reg app_cmd_pending;
    reg card_bus_4bit, card_high_speed, card_high_capacity;
    reg sd_v1;
    reg high_speed_supported;
    reg drop_read_response_once, bad_crc_once, bad_crc_always;
    reg drop_data_token_once;
    reg drop_cmd55_response;
    integer read_response_delay;
    reg [7:0] card_file [0:511];
    integer card_fd, card_byte, card_i, card_file_i;
    reg trace_enabled;

    localparam [2:0] DATA_IDLE=0,DATA_TOKEN=1,DATA_PAYLOAD=2,DATA_CRC=3,DATA_END=4;
    reg [2:0] data_phase;
    integer data_position;
    integer crc_position;
    reg [15:0] card_crc0,card_crc1,card_crc2,card_crc3;
    reg corrupt_this_block;
    reg [31:0] card_clock_count,last_command_end_clock;
    reg last_command_end_valid;

    function [6:0] crc7_40;
        input [39:0] bits_in;
        integer n;
        reg [6:0] crc;
        reg feedback;
        begin
            crc=0;
            for(n=39;n>=0;n=n-1) begin
                feedback=bits_in[n]^crc[6];
                crc={crc[5:0],1'b0};
                if(feedback)crc=crc^7'h09;
            end
            crc7_40=crc;
        end
    endfunction

    function [6:0] crc7_120;
        input [119:0] bits_in;
        integer n;
        reg [6:0] crc;
        reg feedback;
        begin
            crc=0;
            for(n=119;n>=0;n=n-1) begin
                feedback=bits_in[n]^crc[6];
                crc={crc[5:0],1'b0};
                if(feedback)crc=crc^7'h09;
            end
            crc7_120=crc;
        end
    endfunction

    function [15:0] crc16_bit;
        input [15:0] crc;
        input bit_in;
        reg feedback;
        begin
            feedback=crc[15]^bit_in;
            crc16_bit={crc[14:0],1'b0};
            if(feedback)crc16_bit=crc16_bit^16'h1021;
        end
    endfunction

    function [47:0] r1_frame;
        input [5:0] index;
        input [31:0] status;
        reg [39:0] body;
        begin
            body={2'b00,index,status};
            r1_frame={body,crc7_40(body),1'b1};
        end
    endfunction

    function [47:0] r3_frame;
        input [31:0] ocr;
        begin
            r3_frame={2'b00,6'b111111,ocr,7'h7F,1'b1};
        end
    endfunction

    function [135:0] r2_frame;
        input [119:0] register_value;
        begin
            r2_frame={2'b00,6'b111111,register_value,
                      crc7_120(register_value),1'b1};
        end
    endfunction

    function [7:0] sector_byte;
        input [31:0] lba;
        input integer byte_index;
        begin
            if(lba==0) sector_byte=card_file[byte_index];
            else sector_byte=lba[7:0]^byte_index[7:0]^(byte_index[8]?8'hA5:8'h00);
        end
    endfunction

    function status_stream_bit;
        input integer bit_position;
        input switch_mode;
        integer bit_number;
        begin
            bit_number=511-bit_position;
            status_stream_bit=0;
            if(high_speed_supported && bit_number==401) status_stream_bit=1'b1;
            if(switch_mode && high_speed_supported && bit_number==376) status_stream_bit=1'b1;
        end
    endfunction

    function [3:0] sector_nibble;
        input [31:0] lba;
        input integer byte_index;
        input low_nibble;
        reg [7:0] byte_value;
        begin
            byte_value=sector_byte(lba,byte_index);
            sector_nibble=low_nibble?byte_value[3:0]:byte_value[7:4];
        end
    endfunction

    initial begin
        card_i=0;trace_enabled=$test$plusargs("TRACE");
        high_speed_supported=1;
        if($value$plusargs("HS=%d",card_i)) high_speed_supported=(card_i!=0);
        card_high_capacity=1;card_i=1;
        if($value$plusargs("HC=%d",card_i)) card_high_capacity=(card_i!=0);
        sd_v1=0;card_i=0;
        if($value$plusargs("V1=%d",card_i)) sd_v1=(card_i!=0);
        if(sd_v1)begin card_high_capacity=0;high_speed_supported=0;end
        card_i=0;
        if($value$plusargs("DROP_CMD55=%d",card_i)) drop_cmd55_response=(card_i!=0);
        else drop_cmd55_response=0;
        card_i=0;
        if($value$plusargs("DROP_READ_RESPONSE=%d",card_i)) drop_read_response_once=(card_i!=0);
        else drop_read_response_once=0;
        card_i=0;
        if($value$plusargs("BAD_CRC_ONCE=%d",card_i)) bad_crc_once=(card_i!=0);
        else bad_crc_once=0;
        card_i=0;
        if($value$plusargs("BAD_CRC_ALWAYS=%d",card_i)) bad_crc_always=(card_i!=0);
        else bad_crc_always=0;
        card_i=0;
        if($value$plusargs("DROP_DATA_TOKEN=%d",card_i)) drop_data_token_once=(card_i!=0);
        else drop_data_token_once=0;
        read_response_delay=0;
        card_i=0;
        if($value$plusargs("READ_RESPONSE_DELAY=%d",card_i)) read_response_delay=card_i;

    end

    reg [8*260-1:0] image_path;
    initial begin
        image_path="../img/card_user_real.img";
        if($value$plusargs("CARD=%s",image_path)) begin end
        for(card_file_i=0;card_file_i<512;card_file_i=card_file_i+1) card_file[card_file_i]=0;
        card_fd=$fopen(image_path,"rb");
        if(card_fd!=0) begin
            for(card_file_i=0;card_file_i<512;card_file_i=card_file_i+1) begin
                card_byte=$fgetc(card_fd);
                if(card_byte>=0) card_file[card_file_i]=card_byte[7:0];
            end
            $fclose(card_fd);
        end else $display("SD_MODEL: image file not found; sector 0 is zero-filled (%0s)",image_path);
    end

    always @(posedge sd_clk) begin : card_sample
        reg [47:0] frame_next;
        reg [31:0] status_word;
        reg [119:0] register_value;
        reg [5:0] index_value;
        reg [31:0] argument_value;
        reg [3:0] nibble_tmp;
        card_clock_count<=card_clock_count+1'b1;
        if(response_pending && response_delay_count>0)
            response_delay_count<=response_delay_count-1;
        else if(response_pending && !response_active) begin
            response_pending<=0;response_active<=1;response_position<=0;
        end

        if(response_active) begin
            if(response_position==response_length-1) begin
                response_active<=0;response_position<=0;
                last_command_end_clock<=card_clock_count;last_command_end_valid<=1;
                if(response_after_data) begin
                    data_phase<=DATA_TOKEN;data_position<=0;crc_position<=0;
                    card_crc0<=0;card_crc1<=0;card_crc2<=0;card_crc3<=0;
                    corrupt_this_block<=data_is_switch_status ? 0 : (bad_crc_always || bad_crc_once);
                    if(!data_is_switch_status && bad_crc_once) bad_crc_once<=0;
                end
                response_after_data<=0;
            end else response_position<=response_position+1;
        end else if(data_phase!=DATA_IDLE) begin
            case(data_phase)
                DATA_TOKEN: begin data_phase<=DATA_PAYLOAD;data_position<=0;end
                DATA_PAYLOAD: begin
                    if(data_is_switch_status) begin
                        card_crc0<=crc16_bit(card_crc0,status_stream_bit(data_position,data_switch_mode));
                        if(data_position==511) begin data_phase<=DATA_CRC;crc_position<=0;end
                        else data_position<=data_position+1;
                    end else begin
                        if(card_bus_4bit)begin
                            nibble_tmp=sector_nibble(data_lba,data_position>>1,data_position[0]);
                            card_crc0<=crc16_bit(card_crc0,nibble_tmp[0]);
                            card_crc1<=crc16_bit(card_crc1,nibble_tmp[1]);
                            card_crc2<=crc16_bit(card_crc2,nibble_tmp[2]);
                            card_crc3<=crc16_bit(card_crc3,nibble_tmp[3]);
                            if(data_position==1023) begin data_phase<=DATA_CRC;crc_position<=0;end
                            else data_position<=data_position+1;
                        end else begin
                            card_crc0<=crc16_bit(card_crc0,
                                (sector_byte(data_lba,data_position>>3)>>(7-data_position[2:0]))&1'b1);
                            if(data_position==4095) begin data_phase<=DATA_CRC;crc_position<=0;end
                            else data_position<=data_position+1;
                        end
                    end
                end
                DATA_CRC: if(crc_position==15) begin data_phase<=DATA_END;end
                          else crc_position<=crc_position+1;
                DATA_END: begin
                    if(trace_enabled) $display("SD_MODEL DATA END switch=%b crc=%h/%h/%h/%h at %0t",
                        data_is_switch_status,card_crc3,card_crc2,card_crc1,card_crc0,$time);
                    data_phase<=DATA_IDLE;
                end
                default: data_phase<=DATA_IDLE;
            endcase
        end else if(!response_pending) begin
            if(!cmd_collect) begin
                if(sd_cmd===1'b0) begin
                    if(last_command_end_valid && (card_clock_count-last_command_end_clock)<8)
                        $fatal(1,"host started next command before 8 idle SD clocks (%0d)",
                            card_clock_count-last_command_end_clock);
                    cmd_collect<=1;cmd_bits<=1;cmd_shift<=48'd0;
                end
            end else if(cmd_bits==1) begin
                if(sd_cmd===1'b1) begin cmd_shift<={47'd0,1'b0,1'b1};cmd_bits<=2;end
                else begin cmd_collect<=0;cmd_bits<=0;end
            end else begin
                frame_next={cmd_shift[46:0],sd_cmd};
                cmd_shift<=frame_next;
                if(cmd_bits==47) begin
                    cmd_collect<=0;cmd_bits<=0;
                    last_command_end_clock<=card_clock_count;last_command_end_valid<=1;
                    index_value=frame_next[45:40];argument_value=frame_next[39:8];
                    cmd_count<=cmd_count+1'b1;
                    if(trace_enabled) $display("SD_MODEL CMD%0d arg=%08x crc_ok=%0b at %0t",index_value,argument_value,
                        frame_next[7:1]==crc7_40(frame_next[47:8]),$time);
                    if(frame_next[47:46]!=2'b01 || frame_next[0]!=1'b1 ||
                       frame_next[7:1]!=crc7_40(frame_next[47:8])) cmd_crc_errors<=cmd_crc_errors+1'b1;
                    if(index_value==0) begin
                        app_cmd_pending<=0;card_bus_4bit<=0;card_high_speed<=0;
                        response_pending<=0;response_active<=0;data_phase<=DATA_IDLE;
                    end else if(index_value==8) begin
                        response_frame[47:0]<=sd_v1 ? r1_frame(index_value,32'h00400000) :
                                                        r1_frame(index_value,32'h000001AA);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==55) begin
                        if(drop_cmd55_response)begin
                            response_pending<=0;response_active<=0;response_after_data<=0;
                        end else begin
                            app_cmd_pending<=1;
                            status_word=32'h00000020;
                            response_frame[47:0]<=r1_frame(index_value,status_word);
                            response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                        end
                    end else if(index_value==41 && app_cmd_pending) begin
                        app_cmd_pending<=0;
                        response_frame[47:0]<=r3_frame(card_high_capacity?32'hC0FF8000:32'h80FF8000);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==2) begin
                        register_value=120'h123456789ABCDEF0123456789ABCDE;
                        response_frame<=r2_frame(register_value);
                        response_length<=136;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==3) begin
                        status_word=32'h12340000;
                        response_frame[47:0]<=r1_frame(index_value,status_word);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==7 || index_value==16) begin
                        status_word=0;
                        response_frame[47:0]<=r1_frame(index_value,status_word);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==6 && app_cmd_pending) begin
                        app_cmd_pending<=0;
                        card_bus_4bit<=!sd_v1 && (argument_value==2);
                        status_word=sd_v1?32'h00400000:32'd0;
                        response_frame[47:0]<=r1_frame(index_value,status_word);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end else if(index_value==6) begin
                        if(sd_v1)begin
                            response_frame[47:0]<=r1_frame(index_value,32'h00400000);
                            response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                        end else begin
                            data_is_switch_status<=1;data_switch_mode=argument_value[31];
                            if(data_switch_mode && high_speed_supported) card_high_speed<=1;
                            response_frame[47:0]<=r1_frame(index_value,32'd0);
                            response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=1;
                        end
                    end else if(index_value==17) begin
                        read_count<=read_count+1'b1;
                        data_lba<=card_high_capacity?argument_value:(argument_value>>9);
                        data_is_switch_status<=0;
                        if(drop_read_response_once) begin
                            drop_read_response_once<=0;response_pending<=0;response_after_data<=0;
                        end else begin
                            response_frame[47:0]<=r1_frame(index_value,32'd0);
                            response_length<=48;response_delay_count<=read_response_delay;response_pending<=1;
                            response_after_data<=!drop_data_token_once;
                            if(drop_data_token_once) drop_data_token_once<=0;
                        end
                    end else begin
                        app_cmd_pending<=0;
                        response_frame[47:0]<=r1_frame(index_value,32'd0);
                        response_length<=48;response_delay_count<=0;response_pending<=1;response_after_data<=0;
                    end
                end else cmd_bits<=cmd_bits+1;
            end
        end
    end

    always @(negedge sd_clk) begin
        cmd_drive<=0;dat_drive<=0;cmd_value<=1;dat_value<=4'hF;
        if(response_active) begin
            cmd_drive<=1;cmd_value<=response_frame[response_length-1-response_position];
        end
        case(data_phase)
            DATA_TOKEN: begin dat_drive<=1;dat_value<=card_bus_4bit?4'h0:4'b1110;end
            DATA_PAYLOAD: begin
                dat_drive<=1;
                if(data_is_switch_status) begin
                    dat_value<=card_bus_4bit?4'hF:{3'b111,status_stream_bit(data_position,data_switch_mode)};
                end else begin
                    if(card_bus_4bit)
                        dat_value<=sector_nibble(data_lba,data_position>>1,data_position[0]);
                    else dat_value<={3'b111,
                        (sector_byte(data_lba,data_position>>3)>>(7-data_position[2:0]))&1'b1};
                end
            end
            DATA_CRC: begin
                dat_drive<=1;
                if(trace_enabled) $display("SD_MODEL CRC pos=%0d tx=%b crc0=%h at %0t",crc_position,
                    card_crc0[15-crc_position],card_crc0,$time);
                if(corrupt_this_block && crc_position==0) begin
                    dat_value<=card_bus_4bit ?
                        {card_crc3[15-crc_position],card_crc2[15-crc_position],
                         card_crc1[15-crc_position],~card_crc0[15-crc_position]} :
                        {3'b111,~card_crc0[15-crc_position]};
                end else dat_value<=card_bus_4bit ?
                    {card_crc3[15-crc_position],card_crc2[15-crc_position],
                     card_crc1[15-crc_position],card_crc0[15-crc_position]} :
                    {3'b111,card_crc0[15-crc_position]};
            end
            DATA_END: begin dat_drive<=1;dat_value<=4'hF;end
            default: begin end
        endcase
    end

    initial begin
        cmd_drive=0;cmd_value=1;dat_drive=0;dat_value=4'hF;
        card_clock_count=0;last_command_end_clock=0;last_command_end_valid=0;
        cmd_shift=0;cmd_bits=0;cmd_collect=0;response_frame=0;response_length=0;
        response_position=0;response_pending=0;response_active=0;response_delay_count=0;
        response_after_data=0;data_lba=0;data_is_switch_status=0;data_switch_mode=0;
        app_cmd_pending=0;card_bus_4bit=0;card_high_speed=0;
        data_phase=DATA_IDLE;data_position=0;crc_position=0;
        card_crc0=0;card_crc1=0;card_crc2=0;card_crc3=0;corrupt_this_block=0;
        cmd_count=0;cmd_crc_errors=0;read_count=0;
    end
endmodule
