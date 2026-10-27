module direct_video_feedback_tx #(
    parameter integer STATUS_ENABLED=0,
    parameter integer READY_ENABLED=0,parameter HEALTH_FLAGS_ENABLED=0,
    parameter integer OUTPUT_STATUS_ENABLED=0,
    parameter integer MEMORY_STATUS_ENABLED=0,
    parameter integer HYBRID_STATUS_ENABLED=0,
    parameter integer AUDIO_STATUS_ENABLED=0,
    parameter integer REASON_STATUS_ENABLED=0,
    parameter integer CREDIT_STEP=1,
    parameter integer NACK_ENABLED=1,
    parameter integer STATUS_INTERVAL_CYCLES=12500000
)(
    input              clk,
    input              rst,
    input [6:0] health_flags,
    input              ready_event,
    input [15:0] ready_sequence,ready_frame,
    input              nack_event,
    input      [15:0]  nack_sequence,
    input              credit_event,
    input      [15:0]  credit_next_sequence,
    input      [7:0]   free_row_credits,
    input      [31:0]  parser_accepted,parser_rejected,
    input      [31:0]  store_accepted,store_rejected,duplicate_rows,
    input      [31:0]  underflow_gray_async,
    input      [95:0]  reject_reason_stats,
    input              diagnostic_mode,
    input [95:0] video_output_stats,
    input [95:0] memory_stats,
    input [95:0] hybrid_stats,readback_stats,audio_stats,
    input [1:0] memory_kind,
    input memory_mode,
    input [2:0] output_color_mode,
    output wire        digest_req,
    output wire        digest_valid,
    output wire [7:0]  digest_data,
    output wire [15:0] digest_length,
    input              digest_ack
);
    localparam [1:0] IDLE=2'd0, REQUEST=2'd1, SEND=2'd2;
    reg [1:0] state;
    reg pending_ready;reg [15:0] pending_ready_sequence,pending_ready_frame,tx_ready_frame;
    reg pending_nack;
    reg [15:0] pending_nack_sequence;
    reg pending_credit;
    reg [15:0] last_advertised_sequence;
    wire [15:0] credit_delta=credit_next_sequence-last_advertised_sequence;
    // Absolute credits remain safe to coalesce. NACK and STATUS bypass this
    // filter; wrap/session jumps qualify via unsigned modular distance.
    wire qualified_credit_event=credit_event && ((CREDIT_STEP<=1) || credit_delta>=CREDIT_STEP);
    reg [7:0] pending_credit_count;
    reg [4:0] tx_index;
    reg [7:0] tx_opcode;
    reg [15:0] tx_sequence;
    reg [7:0] tx_credits;
    localparam integer STATUS_TIMER_BITS=$clog2(STATUS_INTERVAL_CYCLES+1);
    reg [STATUS_TIMER_BITS-1:0] status_timer;
    reg pending_status;
    reg reason_turn;
    reg [2:0] output_turn;
    wire audio_packet=AUDIO_STATUS_ENABLED && output_turn==4;
    wire reason_packet=REASON_STATUS_ENABLED && (OUTPUT_STATUS_ENABLED?(output_turn==1):reason_turn);
    wire output_packet=OUTPUT_STATUS_ENABLED && output_turn==(HYBRID_STATUS_ENABLED?1:2);
    wire hybrid_packet=HYBRID_STATUS_ENABLED && output_turn==2;
    wire readback_packet=HYBRID_STATUS_ENABLED && output_turn==3;
    wire memory_packet=MEMORY_STATUS_ENABLED && !HYBRID_STATUS_ENABLED && output_turn==3;
    reg [95:0] status_shift;
    reg [31:0] underflow_meta,underflow_sync;
    function [31:0] gray_to_binary(input [31:0] value);
        integer i;
        begin
            gray_to_binary[31]=value[31];
            for(i=30;i>=0;i=i-1)gray_to_binary[i]=gray_to_binary[i+1]^value[i];
        end
    endfunction
    wire [31:0] underflow_binary=gray_to_binary(underflow_sync);

    assign digest_req = (state == REQUEST);
    assign digest_valid = (state == SEND);
    assign digest_length = (((tx_opcode>=8'd3 && tx_opcode<=8'd8)||tx_opcode==8'd10)) ? 16'd32 : 16'd8;

    reg [7:0] selected_byte;
    always @* begin
        case (tx_index)
            4'd0: selected_byte=8'h56;
            4'd1: selected_byte=8'h41;
            4'd2: selected_byte=8'h01;
            4'd3: selected_byte=tx_opcode;
            4'd4: selected_byte=tx_sequence[7:0];
            4'd5: selected_byte=tx_sequence[15:8];
            4'd6: selected_byte=tx_opcode==9?tx_ready_frame[7:0]:tx_credits;
            4'd7: if(tx_opcode==9)selected_byte=tx_ready_frame[15:8];else selected_byte=((((tx_opcode>=3&&tx_opcode<=8)||tx_opcode==10))?(8'd16|{diagnostic_mode,7'd0}):((tx_opcode==1)?{(HEALTH_FLAGS_ENABLED?health_flags:7'd0),diagnostic_mode}:8'd0));
            default: selected_byte=((((tx_opcode>=8'd3 && tx_opcode<=8'd8)||tx_opcode==8'd10)) && tx_index==7)?(8'd16 | {diagnostic_mode,7'd0}):
                ((tx_opcode==1 && tx_index==7)?{(HEALTH_FLAGS_ENABLED?health_flags:7'd0),diagnostic_mode}:
                (((((tx_opcode>=8'd3 && tx_opcode<=8'd8)||tx_opcode==8'd10)) && tx_index>=8 && !tx_index[1])?status_shift[7:0]:8'h00));
        endcase
    end
    assign digest_data = selected_byte;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            pending_ready<=0;pending_ready_sequence<=0;pending_ready_frame<=0;tx_ready_frame<=0;
            pending_nack <= 1'b0;
            pending_nack_sequence <= 16'd0;
            pending_credit <= 1'b0;
            last_advertised_sequence<=0;
            pending_credit_count <= 8'd0;
            tx_index <= 4'd0;
            tx_opcode <= 8'd0;
            tx_sequence <= 16'd0;
            tx_credits <= 8'd0;
            status_timer<=0;pending_status<=0;status_shift<=0;reason_turn<=0;output_turn<=0;
            underflow_meta<=0;underflow_sync<=0;
        end else begin
            if(STATUS_ENABLED)begin
                underflow_meta<=underflow_gray_async;underflow_sync<=underflow_meta;
                if(status_timer==STATUS_INTERVAL_CYCLES-1)begin
                    status_timer<=0;pending_status<=1;
                end else status_timer<=status_timer+1'b1;
            end
            if(READY_ENABLED&&ready_event)begin
                pending_ready<=1;pending_ready_sequence<=ready_sequence;pending_ready_frame<=ready_frame;
                pending_credit<=0;pending_nack<=0;last_advertised_sequence<=ready_sequence;
            end
            if (NACK_ENABLED && nack_event && !(READY_ENABLED&&ready_event)) begin
                pending_nack <= 1'b1;
                pending_nack_sequence <= nack_sequence;
            end
            if (qualified_credit_event && !(READY_ENABLED&&ready_event)) begin
                last_advertised_sequence<=credit_next_sequence;
                pending_credit <= 1'b1;
                pending_credit_count <= free_row_credits;
            end

            case (state)
                IDLE: begin
                    if(READY_ENABLED&&(pending_ready||ready_event))begin
                        tx_opcode<=9;tx_sequence<=ready_event?ready_sequence:pending_ready_sequence;
                        tx_ready_frame<=ready_event?ready_frame:pending_ready_frame;tx_credits<=0;tx_index<=0;
                        pending_ready<=0;pending_credit<=0;pending_nack<=0;state<=REQUEST;
                    end else if (NACK_ENABLED && (pending_nack || nack_event)) begin
                        tx_opcode <= 8'h02;
                        tx_sequence <= nack_event ? nack_sequence : pending_nack_sequence;
                        tx_credits <= free_row_credits;
                        tx_index <= 4'd0;
                        pending_nack <= 1'b0;
                        state <= REQUEST;
                    end else if (pending_credit || qualified_credit_event) begin
                        tx_opcode <= 8'h01;
                        tx_sequence <= credit_next_sequence;
                        tx_credits <= qualified_credit_event ? free_row_credits : pending_credit_count;
                        tx_index <= 4'd0;
                        pending_credit <= 1'b0;
                        state <= REQUEST;
                    end else if(STATUS_ENABLED && pending_status)begin
                        tx_opcode<=audio_packet?8'd10:(readback_packet?8'd8:(hybrid_packet?8'd7:(memory_packet?8'd6:(output_packet?8'd5:(reason_packet?8'd4:8'd3)))));
                        if(OUTPUT_STATUS_ENABLED||HYBRID_STATUS_ENABLED||MEMORY_STATUS_ENABLED||AUDIO_STATUS_ENABLED)output_turn<=(output_turn==(AUDIO_STATUS_ENABLED?4:((MEMORY_STATUS_ENABLED||HYBRID_STATUS_ENABLED)?3:2)))?0:output_turn+1'b1;
                        if(REASON_STATUS_ENABLED)reason_turn<=~reason_turn;
                        tx_sequence<=credit_next_sequence;
                        tx_credits<=memory_packet?{5'd0,memory_mode,memory_kind}:(output_packet?{5'd0,output_color_mode}:free_row_credits);tx_index<=0;pending_status<=0;
                        // Six u32 wire fields contain low u16 counters. Header
                        // byte 7 advertises 16 bits; the PC unwraps at 10 Hz.
                        status_shift<=audio_packet?audio_stats:readback_packet?readback_stats:(hybrid_packet?hybrid_stats:(memory_packet?memory_stats:(output_packet?video_output_stats:(reason_packet?reject_reason_stats:
                                    {underflow_binary[15:0],duplicate_rows[15:0],
                                      store_rejected[15:0],store_accepted[15:0],parser_rejected[15:0],parser_accepted[15:0]}))));
                        state<=REQUEST;
                    end
                end
                REQUEST: begin
                    if (digest_ack) begin
                        tx_index <= 4'd0;
                        state <= SEND;
                    end
                end
                SEND: begin
                    if((((tx_opcode>=8'd3 && tx_opcode<=8'd8)||tx_opcode==8'd10)) && tx_index>=8 && !tx_index[1])status_shift<=status_shift>>8;
                    if (tx_index == ((((tx_opcode>=8'd3 && tx_opcode<=8'd8)||tx_opcode==8'd10)) ? 5'd31 : 5'd7)) begin
                        state <= IDLE;
                        tx_index <= 4'd0;
                    end else
                        tx_index <= tx_index + 4'd1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule



