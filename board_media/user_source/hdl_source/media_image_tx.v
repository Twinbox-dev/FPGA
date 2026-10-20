// Formal image + paired PCM sender. The same 253-word BRAM packet store and
// 512-word async FIFO are reused sequentially for image and audio.
module media_image_tx #(
    parameter integer CLK_HZ=125000000,
    parameter integer FRAME_WORDS=460800
)(
    input wire clk,rst,
    input wire mounted,source_busy,source_error,
    input wire [5:0] first_bmp,
    input wire [191:0] bmp_next,bmp_prev,
    input wire [7:0] cmd,
    input wire cmd_pending,
    input wire auto_next,
    input wire auto_status,
    input wire local_next,
    input wire local_prev,
    input wire prepared_toggle,done_toggle,
    input wire source_has_wav_async,
    input wire [4:0] source_wav_index_async,
    input wire audio_prepared_toggle,audio_done_toggle,
    input wire [31:0] audio_sample_count_async,
    input wire audio_source_error_async,
    output reg start_toggle,
    output reg [4:0] source_index,
    output reg audio_start_toggle,
    output reg [4:0] audio_file_index,
    input wire fifo_empty,
    input wire [31:0] fifo_data,
    output wire fifo_read,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output wire tx_request,tx_valid,
    output reg [7:0] tx_data,
    output reg [15:0] tx_length,
    input wire tx_ack,
    output wire busy,
    output reg [4:0] committed_index,
    output reg committed_valid,
    output reg committed_wav,
    output reg [7:0] error_code,
    output wire [3:0] state_code
);
    localparam [3:0] WAIT_READY=0,WAIT_HEADER=1,LOAD_IMAGE=2,ISSUE=3,SEND=4,
        WAIT_SOURCE=5,IMAGE_END_GAP=6,WAIT_RESULT=7,WAIT_COMMIT=8,IDLE=9,
        AUDIO_WAIT_HEADER=10,AUDIO_LOAD=11,AUDIO_WAIT_SOURCE=12,
        AUDIO_END_GAP=13,AUDIO_WAIT_RESULT=14;
    localparam [7:0] READY=8'h20,BEGIN_IMAGE=8'h21,IMAGE_DATA=8'h22,END_IMAGE=8'h23;
    localparam [7:0] AUDIO_BEGIN=8'h30,AUDIO_DATA=8'h31,AUDIO_END=8'h32,AUDIO_RESULT=8'h33;
    localparam integer AUDIO_PACKET_SAMPLES=1012;

    reg [3:0] state,return_state;
    assign state_code=state;
    reg [7:0] kind;
    reg [15:0] frame_id,sequence_id;
    reg [8:0] packet_words,loaded,target_words;
    reg [20:0] total_words;
    reg [31:0] sum,audio_sum;
    reg [31:0] words[0:252]; /* fehdl force_ram=1, ram_style="bram" */
    reg [31:0] ram_q,word_hold;
    reg [10:0] byte_index;
    reg read_pending;
    reg prepared_ref,done_ref,cmd_d;
    reg receiver_ready,boot_loaded,previous,image_has_audio,image_auto_status;
    reg [1:0] attempts,audio_attempts;
    reg [27:0] wait_count;

    reg [2:0] prepared_sync,done_sync,audio_prepared_sync,audio_done_sync;
    reg [1:0] has_wav_sync,audio_error_sync;
    reg [4:0] wav_index_sync0,wav_index_sync1;
    reg [31:0] audio_count_sync0,audio_count_sync1;
    reg audio_prepared_ref,audio_done_ref;
    reg [31:0] audio_total_samples,audio_samples_remaining;
    reg [9:0] audio_packet_samples;
    reg [1:0] audio_prep_phase;
    wire [4:0] base_index=committed_valid?committed_index:first_bmp[4:0];
    wire cmd_new=cmd_pending && !cmd_d;
    wire request_new=(cmd_new && (cmd==8'h4e || cmd==8'h50 || cmd==8'h4d)) || auto_next || local_next || local_prev;
    assign busy=state!=IDLE && state!=WAIT_READY;
    assign fifo_read=(state==LOAD_IMAGE || (state==AUDIO_LOAD && audio_prep_phase==2)) &&
                     !fifo_empty && !read_pending && loaded<target_words;
    assign tx_request=state==ISSUE;
    assign tx_valid=state==SEND;
    wire [15:0] payload_length=tx_length-16'd8;
    wire [31:0] end_checksum=kind==END_IMAGE ? sum : audio_sum;
    wire [10:0] data_byte=byte_index-11'd12;
    wire data_packet=(kind==IMAGE_DATA || kind==AUDIO_DATA);
    wire ram_read=state==SEND && data_packet &&
                  (byte_index==10 || (byte_index>=14 && byte_index[1:0]==2 &&
                    data_byte[10:2]+1 < packet_words));
    wire [7:0] ram_addr=byte_index==10 ? 8'd0 : data_byte[9:2]+1'b1;

    function [9:0] audio_packet_limit;
        input [31:0] remain;
        begin audio_packet_limit=remain>32'd1012 ? 10'd1012 : remain[9:0]; end
    endfunction
    function [8:0] audio_words_for;
        input [9:0] samples;
        begin audio_words_for={1'b0,(samples[9:2]+{7'd0,(|samples[1:0])})}; end
    endfunction

    always @(posedge clk) begin
        if(state==LOAD_IMAGE && read_pending) words[loaded[7:0]]<=fifo_data;
        if(state==AUDIO_LOAD && audio_prep_phase==2 && read_pending) words[loaded[7:0]]<=fifo_data;
        if(ram_read) ram_q<=words[ram_addr];
    end

    reg [10:0] rx_pos;
    reg [7:0] rx_type_lo,rx_type_hi,rx_result;
    reg [15:0] rx_frame,rx_length;
    reg rx_good,ready_pulse,result_pulse,audio_result_pulse;
    always @(posedge clk) begin
        if(rst) begin
            rx_pos<=0;rx_type_lo<=0;rx_type_hi<=0;rx_frame<=0;rx_result<=0;
            rx_length<=0;rx_good<=0;ready_pulse<=0;result_pulse<=0;audio_result_pulse<=0;
        end else begin
            ready_pulse<=0;result_pulse<=0;audio_result_pulse<=0;
            if(rx_valid) begin
                rx_pos<=rx_pos+1'b1;
                case(rx_pos)
                    0: rx_good<=rx_data==8'haa;
                    1: rx_good<=rx_good && rx_data==8'hbb;
                    2: rx_good<=rx_good && rx_data==8'hcc;
                    3: rx_good<=rx_good && rx_data==8'hdd;
                    4: rx_type_lo<=rx_data;
                    5: rx_type_hi<=rx_data;
                    6: rx_length[7:0]<=rx_data;
                    7: rx_length[15:8]<=rx_data;
                    8: begin
                        rx_frame[7:0]<=rx_data;
                        if(rx_good && rx_type_lo==READY && rx_type_hi==0 && rx_length==1 && rx_data==1)
                            ready_pulse<=1;
                    end
                    9: rx_frame[15:8]<=rx_data;
                    10: rx_result<=rx_data;
                    default: ;
                endcase
            end else begin
                if(rx_pos==11 && rx_good && rx_type_hi==0 && rx_length==3) begin
                    if(rx_type_lo==8'h24) result_pulse<=1;
                    if(rx_type_lo==AUDIO_RESULT) audio_result_pulse<=1;
                end
                rx_pos<=0;
            end
        end
    end

    always @* begin
        tx_data=0;
        case(byte_index)
            0:tx_data=8'haa;1:tx_data=8'hbb;2:tx_data=8'hcc;3:tx_data=8'hdd;
            4:tx_data=kind;5:tx_data=0;
            6:tx_data=payload_length[7:0];7:tx_data=payload_length[15:8];
            default: begin
                if(kind==BEGIN_IMAGE) begin
                    case(byte_index)
                        8:tx_data=frame_id[7:0];9:tx_data=frame_id[15:8];
                        10:tx_data={3'd0,source_index};
                        11:tx_data={3'd0,image_auto_status,image_has_audio,2'b00,previous};
                        12:tx_data=FRAME_WORDS[7:0];13:tx_data=FRAME_WORDS[15:8];
                        14:tx_data=FRAME_WORDS[23:16];15:tx_data=FRAME_WORDS[31:24];
                        default:;
                    endcase
                end else if(kind==AUDIO_BEGIN) begin
                    case(byte_index)
                        8:tx_data=frame_id[7:0];9:tx_data=frame_id[15:8];
                        10:tx_data=audio_total_samples[7:0];11:tx_data=audio_total_samples[15:8];
                        12:tx_data=audio_total_samples[23:16];13:tx_data=audio_total_samples[31:24];
                        default:;
                    endcase
                end else if(data_packet) begin
                    case(byte_index)
                        8:tx_data=frame_id[7:0];9:tx_data=frame_id[15:8];
                        10:tx_data=sequence_id[7:0];11:tx_data=sequence_id[15:8];
                        default:tx_data=word_hold[8*data_byte[1:0]+:8];
                    endcase
                end else if(kind==END_IMAGE || kind==AUDIO_END) begin
                    case(byte_index)
                        8:tx_data=frame_id[7:0];9:tx_data=frame_id[15:8];
                        10:tx_data=end_checksum[7:0];
                        11:tx_data=end_checksum[15:8];
                        12:tx_data=end_checksum[23:16];
                        13:tx_data=end_checksum[31:24];
                        default:;
                    endcase
                end
            end
        endcase
    end

    always @(posedge clk) begin
        if(rst) begin
            state<=WAIT_READY;return_state<=WAIT_READY;kind<=READY;tx_length<=8;
            frame_id<=0;sequence_id<=0;packet_words<=0;loaded<=0;target_words<=0;
            total_words<=0;sum<=0;audio_sum<=0;byte_index<=0;read_pending<=0;word_hold<=0;
            prepared_ref<=0;done_ref<=0;cmd_d<=0;receiver_ready<=0;boot_loaded<=0;previous<=0;
            image_auto_status<=0;
            attempts<=0;audio_attempts<=0;wait_count<=0;start_toggle<=0;source_index<=0;
            audio_start_toggle<=0;audio_file_index<=0;image_has_audio<=0;
            committed_index<=0;committed_valid<=0;committed_wav<=0;error_code<=0;
            prepared_sync<=0;done_sync<=0;audio_prepared_sync<=0;audio_done_sync<=0;
            has_wav_sync<=0;wav_index_sync0<=0;wav_index_sync1<=0;
            audio_error_sync<=0;audio_count_sync0<=0;audio_count_sync1<=0;
            audio_prepared_ref<=0;audio_done_ref<=0;audio_total_samples<=0;
            audio_samples_remaining<=0;audio_packet_samples<=0;audio_prep_phase<=0;
        end else begin
            cmd_d<=cmd_pending;
            read_pending<=fifo_read;
            prepared_sync<={prepared_sync[1:0],prepared_toggle};
            done_sync<={done_sync[1:0],done_toggle};
            audio_prepared_sync<={audio_prepared_sync[1:0],audio_prepared_toggle};
            audio_done_sync<={audio_done_sync[1:0],audio_done_toggle};
            has_wav_sync<={has_wav_sync[0],source_has_wav_async};
            wav_index_sync0<=source_wav_index_async;wav_index_sync1<=wav_index_sync0;
            audio_error_sync<={audio_error_sync[0],audio_source_error_async};
            audio_count_sync0<=audio_sample_count_async;audio_count_sync1<=audio_count_sync0;
            if(ready_pulse) receiver_ready<=1;

            case(state)
                WAIT_READY: begin
                    if(mounted && receiver_ready && !source_busy && !boot_loaded) begin
                        source_index<=first_bmp[4:0];frame_id<=frame_id+1'b1;previous<=0;
                        image_auto_status<=auto_status;
                        start_toggle<=~start_toggle;prepared_ref<=prepared_sync[2];done_ref<=done_sync[2];
                        attempts<=1;total_words<=0;sum<=0;sequence_id<=0;wait_count<=0;state<=WAIT_HEADER;
                    end else if(!receiver_ready && wait_count>=CLK_HZ/2) begin
                        kind<=READY;tx_length<=8;return_state<=WAIT_READY;state<=ISSUE;wait_count<=0;
                    end else wait_count<=wait_count+1'b1;
                end
                IDLE: if(request_new && receiver_ready && !source_busy) begin
                    if(auto_next || local_next || (cmd_new && cmd==8'h4e)) source_index<=bmp_next[6*base_index+:6];
                    else if(local_prev || (cmd_new && cmd==8'h50)) source_index<=bmp_prev[6*base_index+:6];
                    else source_index<=base_index;
                    previous<=local_prev || (cmd_new && cmd==8'h50);frame_id<=frame_id+1'b1;
                    image_auto_status<=auto_status;
                    start_toggle<=~start_toggle;prepared_ref<=prepared_sync[2];done_ref<=done_sync[2];
                    attempts<=1;total_words<=0;sum<=0;sequence_id<=0;wait_count<=0;error_code<=0;state<=WAIT_HEADER;
                end
                WAIT_HEADER: begin
                    if(prepared_sync[2]!=prepared_ref) begin
                        image_has_audio<=has_wav_sync[1];audio_file_index<=wav_index_sync1;
                        kind<=BEGIN_IMAGE;tx_length<=16;return_state<=LOAD_IMAGE;
                        loaded<=0;target_words<=FRAME_WORDS>253?253:FRAME_WORDS;state<=ISSUE;wait_count<=0;
                    end else if(done_sync[2]!=done_ref && source_error) begin error_code<=1;state<=IDLE;end
                end
                LOAD_IMAGE: if(read_pending) begin
                    sum<=sum+fifo_data;loaded<=loaded+1'b1;total_words<=total_words+1'b1;
                    if(loaded+1'b1==target_words) begin
                        packet_words<=target_words;kind<=IMAGE_DATA;tx_length<=12+{target_words,2'b00};
                        state<=ISSUE;wait_count<=0;
                    end
                end
                ISSUE: if(tx_ack) begin byte_index<=0;state<=SEND;end
                SEND: begin
                    if(kind==AUDIO_DATA && byte_index>=12)
                        audio_sum<=audio_sum+{24'd0,tx_data};
                    if(data_packet && (byte_index==11 || (byte_index>=15 && byte_index[1:0]==3)))
                        word_hold<=ram_q;
                    if(byte_index+1'b1>=tx_length) begin
                        state<=return_state;byte_index<=0;
                        if(kind==IMAGE_DATA) begin
                            sequence_id<=sequence_id+1'b1;loaded<=0;
                            target_words<=FRAME_WORDS-total_words>253 ? 253 : FRAME_WORDS-total_words;
                            if(total_words>=FRAME_WORDS)state<=WAIT_SOURCE;
                            else state<=LOAD_IMAGE;
                        end else if(kind==AUDIO_DATA) begin
                            sequence_id<=sequence_id+1'b1;loaded<=0;
                            if(audio_samples_remaining>audio_packet_samples) begin
                                audio_samples_remaining<=audio_samples_remaining-audio_packet_samples;
                                audio_prep_phase<=0;state<=AUDIO_LOAD;
                            end else begin
                                audio_samples_remaining<=0;state<=AUDIO_WAIT_SOURCE;
                            end
                        end
                    end else byte_index<=byte_index+1'b1;
                end
                WAIT_SOURCE: if(done_sync[2]!=done_ref) begin
                    if(source_error) begin error_code<=2;state<=IDLE;end
                    else begin wait_count<=0;state<=IMAGE_END_GAP;end
                end
                IMAGE_END_GAP: begin
                    if(wait_count>=CLK_HZ/1000-1) begin
                        kind<=END_IMAGE;tx_length<=16;return_state<=WAIT_RESULT;wait_count<=0;state<=ISSUE;
                    end else wait_count<=wait_count+1'b1;
                end
                WAIT_RESULT: begin
                    if(result_pulse && rx_frame==frame_id) begin
                        if(rx_result==2) begin
                            committed_index<=source_index;committed_valid<=1;committed_wav<=image_has_audio;boot_loaded<=1;state<=IDLE;wait_count<=0;
                        end else if(rx_result==0) begin
                            wait_count<=0;
                            audio_attempts<=1;audio_total_samples<=0;audio_samples_remaining<=0;
                            audio_prep_phase<=0;audio_sum<=0;sequence_id<=0;wait_count<=0;
                            if(image_has_audio) begin
                                audio_start_toggle<=~audio_start_toggle;
                                audio_prepared_ref<=audio_prepared_sync[2];audio_done_ref<=audio_done_sync[2];
                                state<=AUDIO_WAIT_HEADER;
                            end else begin
                                audio_packet_samples<=0;kind<=AUDIO_BEGIN;tx_length<=16;
                                return_state<=AUDIO_LOAD;state<=ISSUE;
                            end
                        end else if(rx_result==1) begin
                            if(attempts<3) begin
                                attempts<=attempts+1'b1;start_toggle<=~start_toggle;
                                prepared_ref<=prepared_sync[2];done_ref<=done_sync[2];
                                total_words<=0;sum<=0;sequence_id<=0;wait_count<=0;state<=WAIT_HEADER;
                            end else begin error_code<=3;state<=IDLE;end
                        end
                    end else if(wait_count>=CLK_HZ*2-1) begin error_code<=4;state<=IDLE;end
                    else wait_count<=wait_count+1'b1;
                end
                WAIT_COMMIT: begin
                    if(result_pulse && rx_frame==frame_id && rx_result==2) begin
                        committed_index<=source_index;committed_valid<=1;committed_wav<=image_has_audio;boot_loaded<=1;state<=IDLE;wait_count<=0;
                    end else if(wait_count>=CLK_HZ*2-1) begin error_code<=4;state<=IDLE;end
                    else wait_count<=wait_count+1'b1;
                end
                AUDIO_WAIT_HEADER: begin
                    if(audio_prepared_sync[2]!=audio_prepared_ref) begin
                        audio_prepared_ref<=audio_prepared_sync[2];
                        if(audio_error_sync[1]) begin
                            if(audio_attempts<3) begin
                                audio_attempts<=audio_attempts+1'b1;audio_start_toggle<=~audio_start_toggle;
                                audio_prepared_ref<=audio_prepared_sync[2];audio_done_ref<=audio_done_sync[2];
                                audio_total_samples<=0;audio_samples_remaining<=0;audio_prep_phase<=0;
                                audio_sum<=0;sequence_id<=0;state<=AUDIO_WAIT_HEADER;wait_count<=0;
                            end else begin error_code<=5;state<=IDLE;end
                        end else begin
                            audio_total_samples<=audio_count_sync1;
                            audio_samples_remaining<=audio_count_sync1;
                            audio_sum<=0;sequence_id<=0;loaded<=0;audio_prep_phase<=0;
                            kind<=AUDIO_BEGIN;tx_length<=16;return_state<=AUDIO_LOAD;
                            state<=ISSUE;wait_count<=0;
                        end
                    end else if(wait_count>=CLK_HZ*2-1) begin error_code<=5;state<=IDLE;end
                    else wait_count<=wait_count+1'b1;
                end
                AUDIO_LOAD: begin
                    if(audio_error_sync[1]) begin
                        if(audio_attempts<3) begin
                            audio_attempts<=audio_attempts+1'b1;audio_start_toggle<=~audio_start_toggle;
                            audio_prepared_ref<=audio_prepared_sync[2];audio_done_ref<=audio_done_sync[2];
                            audio_total_samples<=0;audio_samples_remaining<=0;audio_prep_phase<=0;
                            audio_sum<=0;sequence_id<=0;state<=AUDIO_WAIT_HEADER;wait_count<=0;
                        end else begin error_code<=5;state<=IDLE;end
                    end else if(audio_prep_phase==0) begin
                        if(audio_samples_remaining==0) state<=AUDIO_WAIT_SOURCE;
                        else begin
                            audio_packet_samples<=audio_packet_limit(audio_samples_remaining);
                            audio_prep_phase<=1;
                        end
                    end else if(audio_prep_phase==1) begin
                        target_words<=audio_words_for(audio_packet_samples);
                        loaded<=0;audio_prep_phase<=2;
                    end else if(read_pending) begin
                        loaded<=loaded+1'b1;
                        if(loaded+1'b1==target_words) begin
                            packet_words<=target_words;kind<=AUDIO_DATA;
                            tx_length<=12+audio_packet_samples;state<=ISSUE;
                        end
                    end
                end
                AUDIO_WAIT_SOURCE: begin
                    if(audio_error_sync[1]) begin
                        if(audio_attempts<3) begin
                            audio_attempts<=audio_attempts+1'b1;audio_start_toggle<=~audio_start_toggle;
                            audio_prepared_ref<=audio_prepared_sync[2];audio_done_ref<=audio_done_sync[2];
                            audio_total_samples<=0;audio_samples_remaining<=0;audio_prep_phase<=0;
                            audio_sum<=0;sequence_id<=0;state<=AUDIO_WAIT_HEADER;wait_count<=0;
                        end else begin error_code<=5;state<=IDLE;end
                    end else if((!image_has_audio || audio_done_sync[2]!=audio_done_ref) &&
                                audio_samples_remaining==0) begin
                        wait_count<=0;state<=AUDIO_END_GAP;
                    end else if(wait_count>=CLK_HZ*2-1) begin error_code<=5;state<=IDLE;end
                    else wait_count<=wait_count+1'b1;
                end
                AUDIO_END_GAP: begin
                    if(wait_count>=CLK_HZ/1000-1) begin
                        kind<=AUDIO_END;tx_length<=16;return_state<=AUDIO_WAIT_RESULT;wait_count<=0;state<=ISSUE;
                    end else wait_count<=wait_count+1'b1;
                end
                AUDIO_WAIT_RESULT: begin
                    if(audio_result_pulse && rx_frame==frame_id) begin
                        if(rx_result==0) begin state<=WAIT_COMMIT;wait_count<=0;end
                        else if(rx_result==1 && audio_attempts<3) begin
                            audio_attempts<=audio_attempts+1'b1;
                            audio_total_samples<=0;audio_samples_remaining<=0;audio_prep_phase<=0;
                            audio_sum<=0;sequence_id<=0;wait_count<=0;
                            if(image_has_audio) begin
                                audio_start_toggle<=~audio_start_toggle;
                                audio_prepared_ref<=audio_prepared_sync[2];audio_done_ref<=audio_done_sync[2];
                                state<=AUDIO_WAIT_HEADER;
                            end else begin
                                audio_packet_samples<=0;kind<=AUDIO_BEGIN;tx_length<=16;
                                return_state<=AUDIO_LOAD;state<=ISSUE;
                            end
                        end else begin error_code<=6;state<=IDLE;end
                    end else if(wait_count>=CLK_HZ*2-1) begin error_code<=6;state<=IDLE;end
                    else wait_count<=wait_count+1'b1;
                end
                default:state<=WAIT_READY;
            endcase
        end
    end
endmodule

module media_udp_mux (
    input wire clk,rst,stack_ready,stack_ack,
    input wire ctrl_request,ctrl_valid,input wire [7:0] ctrl_data,input wire [15:0] ctrl_length,
    output wire ctrl_ready,ctrl_ack,
    input wire media_request,media_valid,input wire [7:0] media_data,input wire [15:0] media_length,
    output wire media_ack,
    output wire stack_request,stack_valid,output wire [7:0] stack_data,output wire [15:0] stack_length,
    output reg late_ack_seen,output wire packet_active,output wire media_in_flight,output reg media_packet_drained
);
    reg active,owner;
    assign packet_active=active;
    reg [15:0] count,media_length_latched;
    reg [7:0] media_type_lo,media_type_hi;
    // While idle, do not advertise readiness until the previous UDP stack ACK drops.
    // Once control owns a packet, keep ready asserted for its current handshake.
    assign ctrl_ready=stack_ready && (active ? !owner : !stack_ack);
    assign ctrl_ack=active && !owner && stack_ack;
    assign media_ack=active && owner && stack_ack;
    assign stack_request=active && (owner?media_request:ctrl_request);
    assign stack_valid=active && (owner?media_valid:ctrl_valid);
    assign stack_data=owner?media_data:ctrl_data;
    // The stack may still use length after the last application byte.
    // Keep the formal length until the next ready/ownership handshake.
    assign stack_length=owner?media_length_latched:ctrl_length;
    always @(posedge clk) begin
        if(rst) begin active<=0;owner<=0;count<=0;media_length_latched<=0;late_ack_seen<=0;media_packet_drained<=0;media_type_lo<=0;media_type_hi<=0;end
        else if(!active) begin
            if((ctrl_request || media_request) && stack_ack)late_ack_seen<=1;
            if(stack_ready && !stack_ack && (ctrl_request || media_request)) begin
                owner<=!ctrl_request;
                if(!ctrl_request)begin
                    media_length_latched<=media_length;media_packet_drained<=0;media_type_lo<=0;media_type_hi<=0;
                end
                active<=1;count<=0;
            end
        end else if(stack_valid) begin
            if(count+1'b1>=stack_length) begin
                if(owner && media_length_latched==16'd16 && media_type_lo==8'h23 && media_type_hi==0)
                    media_packet_drained<=1;
                active<=0;count<=0;
            end else begin
                if(owner && count==16'd4)media_type_lo<=stack_data;
                if(owner && count==16'd5)media_type_hi<=stack_data;
                count<=count+1'b1;
            end
        end
    end
endmodule
