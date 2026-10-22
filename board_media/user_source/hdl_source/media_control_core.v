// PC/V1 command bridge for the media board.
// PC command bytes remain [CMD,~CMD]. Media actions stay local; display settings
// use absolute 0x0040 requests and wait for the display board's 0x0041 ACK.
module media_control_core #(
    parameter integer CLK_HZ = 125000000,
    parameter VIEW_ENABLE = 0
)(
    input wire clk, rst,
    input wire [7:0] cmd,
    input wire cmd_pending,
    output reg cmd_ack_t,
    input wire [7:0] uart_cmd,
    input wire uart_cmd_valid,
    input wire [1:0] uart_cmd_source, // 0=Ethernet, 1=USB UART, 2=HC-08
    output wire uart_cmd_ready,
    output wire [1:0] uart_source_lock,
    input wire [7:0] sd_diag_flags, // {init, SDHC, HS support, HS active, debug-active, host state[2:0]}
    input wire [15:0] sd_init_debug_word,
    input wire [31:0] image_read_cycles,
    input wire [31:0] sd_read_cycles,
    input wire [7:0] image_source_status,
    input wire image_source_busy,
    input wire [31:0] sd_last_failure_lba,
    input wire [7:0] sd_last_failure_info,
    input wire [31:0] sd_stream_debug,
    input wire uart_tx_ready,
    input wire bt_tx_ready,
    input wire local_auto_toggle,
    output reg uart_tx_req,
    output reg bt_tx_req,
    output reg [63:0] uart_tx_pkt,
    output reg image_next_pulse,
    output reg image_prev_pulse,
    input wire [7:0] rx_data,
    input wire rx_valid,
    input wire tx_done_tog,
    output reg tx_tog,
    output reg [15:0] tx_type,
    output reg [15:0] tx_payload_len,
    output reg [63:0] tx_pkt,
    input wire [5:0] first_bmp,
    input wire [4:0] committed_index,
    input wire committed_valid,
    input wire paired_wav,
    input wire [7:0] fat_state,
    input wire fat_error,
    // Status byte packs {last media transaction error, current TX FSM state}.
    input wire [7:0] media_state,
    output reg debug_request,
    output reg pc_snapshot_request,
    output reg auto_on,
    output reg [3:0] auto_period_s,
    output reg [3:0] volume,
    output reg [3:0] brightness,
    output reg [3:0] contrast,
    output reg [1:0] effect,
    output reg [2:0] cv_mode,
    output reg [1:0] osd_mode,
    output reg spectrum_on,
    output reg [1:0] spectrum_sensitivity,
    output reg [7:0] last_control_error,
    input wire view_busy,uart_cmd_was_busy,
    output reg layout_request,image_touch_request,
    output reg [1:0] requested_layout
);
    localparam [4:0] IDLE=0, WAIT_REQ_TX=1, WAIT_SET_REPLY=2,
                     WAIT_STATUS_REPLY=3, WAIT_STATUS_TX=4,
                     WAIT_STATUS_ACK_TX=5, WAIT_ACK_TX=6,
                     PREP_ACK=7, PREP_STATUS=8,
                     WAIT_UART_READY=9, WAIT_UART_BUSY=10, WAIT_UART_DONE=11,
                     SUB_BEGIN_WAIT_TX=12, SUB_DATA_PREFETCH=13,
                     SUB_DATA_SEND=14, SUB_DATA_WAIT_TX=15,
                     SUB_END_WAIT_TX=16, SUB_PACKET_GAP=17;
    reg [4:0] state, after_req;
    reg cmd_seen,pending_uart,uart_stage,uart_busy_seen,suppress_cmd_ack;
    reg [1:0] pending_source,subtitle_source;
    reg [7:0] pending_cmd;
    reg [7:0] sequence_id, pending_sequence;
    reg [7:0] pending_op, pending_value;
    reg subtitle_active,subtitle_success,subtitle_swap_ack;
    reg [1:0] subtitle_parse_state;
    reg [7:0] subtitle_remaining,subtitle_length,subtitle_checksum,subtitle_calc_checksum;
    reg [7:0] subtitle_rx_count;
    reg [3:0] subtitle_sum_hi;
    reg [7:0] subtitle_offset;
    reg [7:0] subtitle_read_data;
    reg subtitle_gap_to_end;
    reg [27:0] subtitle_gap_count;
    reg [1:0] subtitle_attempts;
    reg [7:0] subtitle_mem [0:159];
    wire subtitle_consume,subtitle_wr_en,subtitle_commit_toggle,subtitle_ack_pulse,subtitle_ack_ok;
    wire [7:0] subtitle_wr_index,subtitle_wr_char,subtitle_commit_len;
    reg tx_done_ref;
    reg [27:0] timeout_count;
    localparam [31:0] WAIT_LIMIT_FULL = CLK_HZ*2-1;
    localparam [27:0] WAIT_LIMIT = WAIT_LIMIT_FULL[27:0];
    localparam integer SUBTITLE_GAP_CYCLES = CLK_HZ/1000;
    reg [1:0] request_attempts;
    reg [7:0] rx_pos, rx_type_lo, rx_type_hi, rx_len_lo, rx_len_hi;
    reg [63:0] rx_body;
    reg rx_good;
    reg display_ack_pulse, display_status_pulse;
    reg [7:0] display_ack_seq, display_ack_op, display_ack_status, display_ack_value;
    reg [7:0] display_status_seq, display_status_volume, display_status_brightness;
    reg [7:0] display_status_contrast, display_status_effect, display_status_osd;
    reg [7:0] display_status_spectrum, display_status_sensitivity;

    wire eth_event=cmd_pending && !cmd_seen;
    wire serial_source_match=!subtitle_active || (uart_cmd_source==subtitle_source);
    wire serial_event=uart_cmd_valid && serial_source_match;
    wire eth_blocked=eth_event && subtitle_active && (subtitle_source!=2'd0);
    wire event_valid=eth_event || serial_event;
    wire [1:0] event_source=eth_event?2'd0:uart_cmd_source;
    wire event_from_uart=(event_source!=2'd0);
    wire [7:0] event_cmd=eth_event?cmd:uart_cmd;
    wire image_command=event_cmd==8'h4e || event_cmd==8'h50 || event_cmd==8'h6e || event_cmd==8'h70 ||
                       event_cmd==8'h44 || event_cmd==8'h36 || event_cmd==8'h37 || event_cmd==8'h38;
    reg arrival_seen,arrival_busy;
    always @(posedge clk)begin
        if(rst)begin arrival_seen<=0;arrival_busy<=0;end
        else if(!cmd_pending)begin arrival_seen<=0;arrival_busy<=0;end
        else if(!arrival_seen)begin arrival_seen<=1;arrival_busy<=view_busy;end
    end
    wire event_accept=(state==IDLE) && !eth_event && !subtitle_ack_pulse && serial_source_match;
    assign uart_cmd_ready=event_accept;
    assign uart_source_lock=!subtitle_active ? 2'd0 :
                            (subtitle_source==2'd0) ? 2'd3 : subtitle_source;
    wire selected_uart_tx_ready=(pending_source==2'd2)?bt_tx_ready:uart_tx_ready;
    wire [4:0] current_index=committed_valid?committed_index:first_bmp[4:0];
    wire [7:0] ack_flags={1'b0,spectrum_sensitivity,spectrum_on,contrast[2:0],auto_on};
    wire [7:0] ack_picture={osd_mode,effect,brightness};
    wire [7:0] status_flags={1'b0,effect,auto_on,1'b0,fat_error,2'b00};
    wire [63:0] status_payload={
        {7'd0,(paired_wav)},
        {cv_mode,current_index},
        {2'b00,osd_mode,4'b0000},
        status_flags,
        {4'd0,contrast},
        fat_state,
        media_state,
        8'hA5
    };

    subtitle_cmd u_subtitle_cmd (
        .clk(clk),.rst(rst),.cmd(event_cmd),.cmd_val(event_valid),.swap_ack_toggle_raw(subtitle_swap_ack),
        .consume_cmd(subtitle_consume),.wr_en(subtitle_wr_en),.wr_index(subtitle_wr_index),.wr_char(subtitle_wr_char),
        .commit_toggle(subtitle_commit_toggle),.commit_len(subtitle_commit_len),.ack_pulse(subtitle_ack_pulse),.ack_ok(subtitle_ack_ok)
    );
    always @(posedge clk) if(subtitle_wr_en && subtitle_wr_index<160)
        subtitle_mem[subtitle_wr_index]<=subtitle_wr_char;
    // TD infers subtitle_mem as synchronous-read DRAM. Prefetch the selected
    // character one cycle before building its UDP packet so hardware and RTL
    // simulation use the same byte rather than the previous RAM output.
    always @(posedge clk)
        if(!rst && state==SUB_DATA_PREFETCH)
            subtitle_read_data<=subtitle_mem[subtitle_offset];

    task automatic start_app_ack(input [7:0] key, input subtitle_ok);
        reg [63:0] body;
        reg [7:0] ack_wav;
        reg [7:0] ack_volume,ack_period,ack_index,ack_picture_byte;
        begin
            ack_wav=(key==8'h54) ? {3'b101,last_control_error[3:0],paired_wav} : {7'd0,paired_wav};
            ack_volume=(key==8'h54) ? subtitle_checksum : {4'd0,volume};
            ack_period=(key==8'h54) ? subtitle_length : {4'd0,auto_period_s};
            ack_index=(key==8'h54) ? subtitle_rx_count : {cv_mode,current_index};
            ack_picture_byte=(key==8'h54) ? subtitle_calc_checksum : ack_picture;
            body={{subtitle_ok,spectrum_sensitivity,spectrum_on,contrast[2:0],auto_on},ack_picture_byte,
                  ack_wav,ack_index,ack_period,
                  ack_volume,key,8'h5A};
            if(pending_uart) begin
                uart_tx_pkt<=body;uart_stage<=0;uart_busy_seen<=0;state<=WAIT_UART_READY;
            end else begin
                tx_type<=16'h0002;tx_payload_len<=16'd8;tx_pkt<=body;
                tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=WAIT_ACK_TX;
            end
        end
    endtask

    task automatic start_display_set(input [7:0] key,input [7:0] op,input [7:0] value);
        begin
            pending_cmd<=key;pending_op<=op;pending_value<=value;
            pending_sequence<=sequence_id;sequence_id<=sequence_id+1'b1;
            tx_type<=16'h0040;tx_payload_len<=16'd4;
            tx_pkt<={32'd0,8'd0,value,op,sequence_id};
            tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;
            after_req<=WAIT_SET_REPLY;state<=WAIT_REQ_TX;timeout_count<=0;request_attempts<=0;
        end
    endtask

    task automatic start_status_request(input [7:0] key);
        begin
            pending_cmd<=key;pending_sequence<=sequence_id;sequence_id<=sequence_id+1'b1;
            tx_type<=16'h0042;tx_payload_len<=16'd1;
            tx_pkt<={56'd0,sequence_id};
            tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;
            after_req<=WAIT_STATUS_REPLY;state<=WAIT_REQ_TX;timeout_count<=0;request_attempts<=0;
        end
    endtask

    task automatic send_status;
        begin
            if(pending_uart) begin
                uart_tx_pkt<=status_payload;uart_stage<=1;uart_busy_seen<=0;state<=WAIT_UART_READY;
            end else begin
                tx_type<=16'h0002;tx_payload_len<=16'd8;tx_pkt<=status_payload;
                tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=WAIT_STATUS_TX;
            end
        end
    endtask

    task automatic send_sd_diagnostics(input serial_request);
        reg [63:0] diag_body;
        reg [15:0] last_field;
        reg [31:0] middle_field;
        reg [7:0] diag_flags;
        begin
            // A6 | SD flags | image-source cycles (u32 LE) | last CMD17 cycles
            // (u16 LE). A busy image source uses F|source-status|FAT-state in
            // the final field so a stuck source can be diagnosed in place.
            diag_flags=sd_diag_flags;
            middle_field=image_read_cycles;
            if (!sd_diag_flags[7] || sd_diag_flags[3])
                last_field=sd_init_debug_word;
            else if(fat_state==8'd9 && sd_last_failure_info[7:4]!=0) begin
                // D-tag: final SD failure; the 32-bit middle field is the LBA.
                last_field={8'hD0,sd_last_failure_info};
                middle_field=sd_last_failure_lba;
                diag_flags[3]=1'b1;
            end
            else if(image_source_busy) begin
                last_field={4'hF,image_source_status,fat_state[3:0]};
                middle_field=sd_stream_debug;
                diag_flags[3]=1'b1;
            end
            else if(fat_state==8'd2) begin
                // E-tag: FAT is waiting for a sector while the image source
                // is idle; return the adapter's current request/stream cursor.
                last_field={8'hE0,fat_state};
                middle_field=sd_stream_debug;
                diag_flags[3]=1'b1;
            end
            else
                last_field=sd_read_cycles[15:0];
            diag_body={last_field[15:8],last_field[7:0],
                       middle_field[31:24],middle_field[23:16],
                       middle_field[15:8],middle_field[7:0],
                       diag_flags,8'hA6};
            if(serial_request)begin
                uart_tx_pkt<=diag_body;uart_stage<=0;uart_busy_seen<=0;state<=WAIT_UART_READY;
            end else begin
                tx_type<=16'h0047;tx_payload_len<=16'd8;tx_pkt<=diag_body;
                tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=WAIT_ACK_TX;
            end
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rx_pos<=0;rx_type_lo<=0;rx_type_hi<=0;rx_len_lo<=0;rx_len_hi<=0;rx_body<=0;rx_good<=0;
            display_ack_pulse<=0;display_status_pulse<=0;
            display_ack_seq<=0;display_ack_op<=0;display_ack_status<=0;display_ack_value<=0;
            display_status_seq<=0;display_status_volume<=0;display_status_brightness<=0;
            display_status_contrast<=0;display_status_effect<=0;display_status_osd<=0;
            display_status_spectrum<=0;display_status_sensitivity<=0;
        end else begin
            display_ack_pulse<=0;display_status_pulse<=0;
            if(rx_valid) begin
                case(rx_pos)
                    0:rx_good<=rx_data==8'hAA;
                    1:rx_good<=rx_good && rx_data==8'hBB;
                    2:rx_good<=rx_good && rx_data==8'hCC;
                    3:rx_good<=rx_good && rx_data==8'hDD;
                    // Display-control replies use the V1 envelope byte order:
                    // TYPE_HI, TYPE_LO, LEN_HI, LEN_LO.
                    4:rx_type_hi<=rx_data;
                    5:rx_type_lo<=rx_data;
                    6:rx_len_hi<=rx_data;
                    7:rx_len_lo<=rx_data;
                    default:if(rx_pos>=8 && rx_pos<16)rx_body[8*(rx_pos-8)+:8]<=rx_data;
                endcase
                rx_pos<=rx_pos+1'b1;
            end else if(rx_pos!=0) begin
                // V1 control reply type/length fields are high byte first.
                // Thus 0x0041/length 4 arrive as [00,41,00,04].
                if(rx_good && rx_type_lo==8'h41 && rx_type_hi==0 && rx_len_lo==4 && rx_len_hi==0 && rx_pos==12) begin
                    display_ack_seq<=rx_body[7:0];display_ack_op<=rx_body[15:8];
                    display_ack_status<=rx_body[23:16];display_ack_value<=rx_body[31:24];display_ack_pulse<=1;
                end
                // The same low-byte-first ordering applies to 0x0043 STATUS.
                if(rx_good && rx_type_lo==8'h43 && rx_type_hi==0 && rx_len_lo==8 && rx_len_hi==0 && rx_pos==16) begin
                    display_status_seq<=rx_body[7:0];display_status_volume<=rx_body[15:8];
                    display_status_brightness<=rx_body[23:16];display_status_contrast<=rx_body[31:24];
                    display_status_effect<=rx_body[39:32];display_status_osd<=rx_body[47:40];
                    display_status_spectrum<=rx_body[55:48];display_status_sensitivity<=rx_body[63:56];display_status_pulse<=1;
                end
                rx_pos<=0;rx_good<=0;rx_body<=0;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            state<=IDLE;after_req<=WAIT_SET_REPLY;cmd_seen<=0;pending_cmd<=0;pending_uart<=0;
            pending_source<=0;subtitle_source<=0;
            uart_tx_req<=0;bt_tx_req<=0;uart_tx_pkt<=0;uart_stage<=0;uart_busy_seen<=0;
            image_next_pulse<=0;image_prev_pulse<=0;
            layout_request<=0;requested_layout<=0;image_touch_request<=0;
            sequence_id<=0;pending_sequence<=0;pending_op<=0;pending_value<=0;
            subtitle_active<=0;subtitle_success<=0;subtitle_swap_ack<=0;
            subtitle_parse_state<=0;subtitle_remaining<=0;subtitle_sum_hi<=0;subtitle_length<=0;
            subtitle_checksum<=0;subtitle_calc_checksum<=0;subtitle_rx_count<=0;
            subtitle_offset<=0;subtitle_attempts<=0;
            subtitle_gap_to_end<=0;subtitle_gap_count<=0;
            tx_done_ref<=0;timeout_count<=0;request_attempts<=0;
            cmd_ack_t<=0;tx_tog<=0;tx_type<=16'h0002;tx_payload_len<=8;tx_pkt<=0;
            debug_request<=0;pc_snapshot_request<=0;auto_on<=0;auto_period_s<=1;volume<=8;brightness<=4;
            contrast<=2;effect<=0;cv_mode<=0;osd_mode<=1;spectrum_on<=0;spectrum_sensitivity<=1;last_control_error<=0;
        end else begin
            debug_request<=0;pc_snapshot_request<=0;uart_tx_req<=0;bt_tx_req<=0;image_next_pulse<=0;image_prev_pulse<=0;
            layout_request<=0;image_touch_request<=0;
            if(local_auto_toggle)auto_on<=~auto_on;
            if(!cmd_pending)cmd_seen<=0;
            if(state==WAIT_SET_REPLY || state==WAIT_STATUS_REPLY || state==WAIT_REQ_TX) begin
                if(timeout_count<WAIT_LIMIT)timeout_count<=timeout_count+1'b1;
            end
            case(state)
                IDLE: begin
                    if(subtitle_ack_pulse && subtitle_active) begin
                        subtitle_active<=0;pending_cmd<=8'h54;pending_source<=subtitle_source;
                        pending_uart<=(subtitle_source!=0);subtitle_success<=0;
                        if(subtitle_ack_ok && subtitle_commit_len==subtitle_length) begin
                            pending_value<=subtitle_commit_len;pending_op<=8;last_control_error<=6;
                            pending_sequence<=sequence_id;sequence_id<=sequence_id+1'b1;
                            subtitle_attempts<=1;subtitle_length<=subtitle_commit_len;subtitle_offset<=0;
                            tx_type<=16'h0044;tx_payload_len<=3;
                            tx_pkt<={40'd0,subtitle_checksum,subtitle_commit_len,sequence_id};
                            tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=SUB_BEGIN_WAIT_TX;timeout_count<=0;
                        end else begin
                            last_control_error<=subtitle_ack_ok ? 4 : 1;
                            subtitle_swap_ack<=~subtitle_swap_ack;
                            state<=PREP_ACK;
                        end
                    end else if(eth_blocked) begin
                        // A subtitle transaction owns its originating transport.
                        // Consume competing Ethernet bytes as rejected commands
                        // so they cannot be replayed as controls after commit.
                        cmd_seen<=1;cmd_ack_t<=~cmd_ack_t;last_control_error<=5;
                    end else if(event_valid && subtitle_consume) begin
                        if(eth_event)begin cmd_seen<=1;cmd_ack_t<=~cmd_ack_t;end
                        if(event_cmd==8'h54 && !subtitle_active) begin
                            subtitle_active<=1;subtitle_source<=event_source;pending_source<=event_source;subtitle_success<=0;
                            last_control_error<=5;
                            pending_cmd<=8'h54;pending_uart<=event_from_uart;suppress_cmd_ack<=!event_from_uart;
                            subtitle_parse_state<=0;subtitle_remaining<=0;subtitle_length<=0;subtitle_checksum<=0;
                            subtitle_calc_checksum<=0;subtitle_rx_count<=0;
                        end else if(subtitle_active) begin
                            subtitle_rx_count<=subtitle_rx_count+1'b1;
                            case(subtitle_parse_state)
                                0:begin subtitle_length<=event_cmd^8'h80;subtitle_remaining<=event_cmd^8'h80;
                                    subtitle_checksum<=event_cmd^8'h80;subtitle_calc_checksum<=event_cmd^8'h80;
                                    subtitle_parse_state<=((event_cmd^8'h80)==0) ? 2'd2 : 2'd1;end
                                1:begin subtitle_checksum<=subtitle_checksum^{1'b0,event_cmd[6:0]};
                                    subtitle_calc_checksum<=subtitle_calc_checksum^{1'b0,event_cmd[6:0]};
                                    subtitle_remaining<=subtitle_remaining-1'b1;
                                    if(subtitle_remaining==1)subtitle_parse_state<=2'd2;end
                                2:begin subtitle_sum_hi<=event_cmd[3:0];subtitle_parse_state<=2'd3;end
                                3:begin subtitle_checksum<={subtitle_sum_hi,event_cmd[3:0]};subtitle_parse_state<=0;end
                            endcase
                        end
                    end else if(event_valid) begin
                        if(eth_event)cmd_seen<=1;
                        pending_cmd<=event_cmd;pending_uart<=event_from_uart;pending_source<=event_source;
                        suppress_cmd_ack<=0;last_control_error<=0;subtitle_success<=0;
                        if(VIEW_ENABLE && image_command && (view_busy || (eth_event && arrival_busy) ||
                           (!eth_event && uart_cmd_was_busy)))begin
                            last_control_error<=8;state<=PREP_ACK;
                        end else case(event_cmd)
                        8'h2B:start_display_set(event_cmd,1,(volume < 4'd8) ? ({4'd0,volume}+8'd1) : 8'd8);
                        8'h2D:start_display_set(event_cmd,1,(volume > 4'd0) ? ({4'd0,volume}-8'd1) : 8'd0);
                        8'h5D:start_display_set(event_cmd,2,(brightness < 4'd8) ? ({4'd0,brightness}+8'd1) : 8'd8);
                        8'h5B:start_display_set(event_cmd,2,(brightness > 4'd0) ? ({4'd0,brightness}-8'd1) : 8'd0);
                        8'h2E:start_display_set(event_cmd,3,(contrast < 4'd6) ? ({4'd0,contrast}+8'd1) : 8'd6);
                        8'h2C:start_display_set(event_cmd,3,(contrast > 4'd0) ? ({4'd0,contrast}-8'd1) : 8'd0);
                        8'h30:start_display_set(event_cmd,4,0);
                        8'h31:start_display_set(event_cmd,4,1);
                        8'h32:start_display_set(event_cmd,4,2);
                        8'h33:start_display_set(event_cmd,5,0);
                        8'h34:start_display_set(event_cmd,5,1);
                        8'h35:start_display_set(event_cmd,5,2);
                        8'h52:start_display_set(event_cmd,9,0); // R: original pixels
                        8'h47:start_display_set(event_cmd,9,1); // G: grayscale
                        8'h42:start_display_set(event_cmd,9,2); // B: binary threshold
                        8'h45:start_display_set(event_cmd,9,3); // E: Sobel
                        8'h48:start_display_set(event_cmd,9,4); // H: sharpen
                        8'h57:start_display_set(event_cmd,9,5); // W: snow
                        8'h51:start_display_set(event_cmd,6,spectrum_on ? 8'd0 : 8'd1);
                        8'h27:start_display_set(event_cmd,7,(spectrum_sensitivity < 2'd3) ? ({6'd0,spectrum_sensitivity}+8'd1) : 8'd3);
                        8'h3B:start_display_set(event_cmd,7,(spectrum_sensitivity > 2'd0) ? ({6'd0,spectrum_sensitivity}-8'd1) : 8'd0);
                        8'h3E:begin auto_period_s<=(auto_period_s < 4'd10) ? (auto_period_s+4'd1) : 4'd10;state<=PREP_ACK;end
                        8'h3C:begin auto_period_s<=(auto_period_s > 4'd1) ? (auto_period_s-4'd1) : 4'd1;state<=PREP_ACK;end
                        8'h41:begin auto_on<=~auto_on;state<=PREP_ACK;end
                        8'h53:start_status_request(event_cmd);
                        8'h44:begin
                            debug_request<=event_from_uart;
                            if(!event_from_uart)pc_snapshot_request<=1'b1;
                            state<=PREP_ACK;
                        end
                        8'h49:send_sd_diagnostics(event_from_uart);
                        8'h4C:begin if(!event_from_uart)cmd_ack_t<=~cmd_ack_t;state<=IDLE;end // V1 lean diagnostic: no response packet
                        8'h4E,8'h6e:begin image_next_pulse<=1;image_touch_request<=VIEW_ENABLE && event_cmd==8'h6e && !event_from_uart;state<=PREP_ACK;end
                        8'h50,8'h70:begin image_prev_pulse<=1;image_touch_request<=VIEW_ENABLE && event_cmd==8'h70 && !event_from_uart;state<=PREP_ACK;end
                        8'h36,8'h37,8'h38:begin
                            if(VIEW_ENABLE)begin layout_request<=1;requested_layout<=event_cmd[1:0]-2'd2;state<=PREP_ACK;end
                            else begin if(!event_from_uart)cmd_ack_t<=~cmd_ack_t;state<=IDLE;end
                        end
                        default:begin if(!event_from_uart)cmd_ack_t<=~cmd_ack_t;state<=IDLE;end
                        endcase
                    end
                end
                WAIT_REQ_TX: if(tx_done_tog!=tx_done_ref) begin
                    timeout_count<=0;state<=after_req;
                end else if(timeout_count>=WAIT_LIMIT) begin
                    last_control_error<=1;start_app_ack(pending_cmd,0);
                end
                WAIT_SET_REPLY: begin
                    if(display_ack_pulse && display_ack_seq==pending_sequence && display_ack_op==pending_op) begin
                        if(pending_op==8) begin
                            if(display_ack_status==0 && display_ack_value==subtitle_length) begin
                                subtitle_success<=1;last_control_error<=0;subtitle_swap_ack<=~subtitle_swap_ack;state<=PREP_ACK;
                            end else if(subtitle_attempts<3) begin
                                subtitle_attempts<=subtitle_attempts+1'b1;subtitle_offset<=0;
                                tx_type<=16'h0044;tx_payload_len<=3;
                                tx_pkt<={40'd0,subtitle_checksum,subtitle_length,pending_sequence};
                                tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=SUB_BEGIN_WAIT_TX;
                            end else begin
                                last_control_error<=2;subtitle_success<=0;subtitle_swap_ack<=~subtitle_swap_ack;state<=PREP_ACK;
                            end
                        end else begin
                            if(display_ack_status==0) begin
                                case(pending_op)
                                    1:volume<=display_ack_value[3:0];
                                    2:brightness<=display_ack_value[3:0];
                                    3:contrast<=display_ack_value[3:0];
                                    4:effect<=display_ack_value[1:0];
                                    5:osd_mode<=display_ack_value[1:0];
                                    6:spectrum_on<=display_ack_value[0];
                                    7:spectrum_sensitivity<=display_ack_value[1:0];
                                    9:cv_mode<=display_ack_value[2:0];
                                endcase
                            end else last_control_error<=2;
                            state<=PREP_ACK;
                        end
                    end else if(timeout_count>=WAIT_LIMIT) begin
                        if(pending_op==8 && subtitle_attempts<3) begin
                            subtitle_attempts<=subtitle_attempts+1'b1;subtitle_offset<=0;
                            tx_type<=16'h0044;tx_payload_len<=3;
                            tx_pkt<={40'd0,subtitle_checksum,subtitle_length,pending_sequence};
                            tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=SUB_BEGIN_WAIT_TX;
                        end else begin
                            last_control_error<=3;subtitle_success<=0;
                            subtitle_swap_ack<=~subtitle_swap_ack;state<=PREP_ACK;
                        end
                    end
                end
                WAIT_STATUS_REPLY: begin
                    if(display_status_pulse && display_status_seq==pending_sequence) begin
                        volume<=display_status_volume[3:0];brightness<=display_status_brightness[3:0];
                        contrast<=display_status_contrast[3:0];effect<=display_status_effect[1:0];
                        osd_mode<=display_status_osd[1:0];spectrum_on<=display_status_spectrum[0];
                        spectrum_sensitivity<=display_status_sensitivity[1:0];
                        cv_mode<=display_status_volume[6:4];
                        state<=PREP_STATUS;
                    end else if(timeout_count>=WAIT_LIMIT) begin last_control_error<=4;state<=PREP_STATUS;end
                end
                SUB_BEGIN_WAIT_TX:if(tx_done_tog!=tx_done_ref)begin
                    subtitle_offset<=0;
                    subtitle_gap_to_end<=(subtitle_length==0);subtitle_gap_count<=0;state<=SUB_PACKET_GAP;
                end
                SUB_PACKET_GAP:begin
                    if(SUBTITLE_GAP_CYCLES<=1 || subtitle_gap_count>=SUBTITLE_GAP_CYCLES-1)begin
                        subtitle_gap_count<=0;
                        if(subtitle_gap_to_end)begin
                        tx_type<=16'h0046;tx_payload_len<=3;tx_pkt<={40'd0,subtitle_checksum,subtitle_length,pending_sequence};
                        tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=SUB_END_WAIT_TX;
                        end else state<=SUB_DATA_PREFETCH;
                    end else subtitle_gap_count<=subtitle_gap_count+1'b1;
                end
                SUB_DATA_PREFETCH:state<=SUB_DATA_SEND;
                SUB_DATA_SEND:begin
                    // One indexed sample per UDP packet keeps the title RAM single-read-port.
                    tx_type<=16'h0045;tx_payload_len<=16'd3;
                    tx_pkt<={40'd0,subtitle_read_data,subtitle_offset,pending_sequence};
                    tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=SUB_DATA_WAIT_TX;
                end
                SUB_DATA_WAIT_TX:if(tx_done_tog!=tx_done_ref)begin
                    if(subtitle_offset+1'b1>=subtitle_length)begin
                        subtitle_gap_to_end<=1'b1;subtitle_gap_count<=0;state<=SUB_PACKET_GAP;
                    end else begin
                        subtitle_offset<=subtitle_offset+1'b1;subtitle_gap_to_end<=1'b0;
                        subtitle_gap_count<=0;state<=SUB_PACKET_GAP;
                    end
                end
                SUB_END_WAIT_TX:if(tx_done_tog!=tx_done_ref)begin timeout_count<=0;state<=WAIT_SET_REPLY;end
                PREP_ACK:start_app_ack(pending_cmd,subtitle_success);
                PREP_STATUS:send_status();
                WAIT_STATUS_TX:if(tx_done_tog!=tx_done_ref)begin
                    tx_type<=16'h0002;tx_payload_len<=8;
                    tx_pkt<={ack_flags,ack_picture,{7'd0,paired_wav},{cv_mode,current_index},
                             {4'd0,auto_period_s},{4'd0,volume},8'h53,8'h5A};
                    tx_done_ref<=tx_done_tog;tx_tog<=~tx_tog;state<=WAIT_STATUS_ACK_TX;
                end
                WAIT_STATUS_ACK_TX,WAIT_ACK_TX:if(tx_done_tog!=tx_done_ref)begin
                    if(!pending_uart && !suppress_cmd_ack)cmd_ack_t<=~cmd_ack_t;
                    suppress_cmd_ack<=0;state<=IDLE;
                end
                WAIT_UART_READY:if(selected_uart_tx_ready)begin
                    if(pending_source==2'd2)bt_tx_req<=1;else uart_tx_req<=1;
                    uart_busy_seen<=0;state<=WAIT_UART_BUSY;
                end
                WAIT_UART_BUSY:if(!selected_uart_tx_ready)begin uart_busy_seen<=1;state<=WAIT_UART_DONE;end
                WAIT_UART_DONE:if(uart_busy_seen && selected_uart_tx_ready)begin
                    if(uart_stage)begin uart_stage<=0;start_app_ack(pending_cmd,0);end
                    else state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
