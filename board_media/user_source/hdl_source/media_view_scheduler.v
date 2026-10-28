`timescale 1ns/1ps
// Schedules source reads only after the display grants a locked window. No
// image/layout/snapshot command is queued while busy. Settings use the existing
// independent control core and share the outer UDP arbiter at packet boundaries.
module media_view_scheduler #(
    parameter integer CLK_HZ=125000000
)(
    input wire clk,rst,link_ready,
    input wire next_request,prev_request,snapshot_request,layout_request,touch_request,
    input wire [1:0] requested_layout,
    input wire [5:0] first_bmp,
    input wire [191:0] bmp_next,bmp_prev,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg job_start,job_snapshot,job_previous,
    output reg [4:0] job_index,
    output reg [1:0] job_layout,job_window,
    output reg [15:0] job_generation,
    input wire job_done,
    input wire [7:0] job_result,
    output wire busy,
    output wire [4:0] current_index,
    output wire current_valid,
    output reg [1:0] active_layout,
    output reg [3:0] active_mask,
    output reg [15:0] active_generation,
    output reg view_status_valid,
    output reg [127:0] view_status_body,
    output wire tx_request,tx_valid,tx_to_pc,
    output wire [7:0] tx_data,
    output reg [15:0] tx_length,
    input wire tx_ack
);
    localparam WAIT_LINK=0,SYNC_VIEW=1,IDLE=2,WAIT_PREP=3,LAUNCH=4,WAIT_JOB=5,WAIT_STATUS=6,RELEASE=7;
    reg [2:0] state;
    reg loaded,view_busy,page_build,failed;
    reg [7:0] sequence_id;
    reg [7:0] action_held;
    reg [1:0] layout_held;
    reg [7:0] preferred_held;
    reg [28:0] timer;
    reg [1:0] attempts;
    reg send_prepare,send_query;
    reg [63:0] prepare_body;
    reg [127:0] last_view;
    reg [8:0] rx_position;
    reg [15:0] rx_kind,rx_length;
    reg rx_good,prepare_event,view_event;
    reg [127:0] rx_body,view_received;
    reg [63:0] prepare_received;
    assign busy=state!=IDLE || view_busy;
    assign current_index=last_view[(7+last_view[41:40])*8+:5];
    assign current_valid=active_mask!=0;
    // The control packet stream has a bounded latest-status slot and one
    // prepare slot. A snapshot can never inherit the route of a queued query.
    reg prepare_pending,query_pending,forward_pending;
    reg [63:0] prepare_pending_body;
    reg [127:0] forward_body;
    reg [7:0] packet[0:23];
    reg [1:0] tx_state;
    reg [4:0] tx_position;
    reg packet_to_pc;
    integer i;
    assign tx_request=tx_state==1;
    assign tx_valid=tx_state==2;
    assign tx_data=packet[tx_position];
    assign tx_to_pc=packet_to_pc;
    task automatic header(input [15:0] kind,input [15:0] length_value);
        begin
            packet[0]<=8'haa;packet[1]<=8'hbb;packet[2]<=8'hcc;packet[3]<=8'hdd;
            packet[4]<=kind[15:8];packet[5]<=kind[7:0];
            packet[6]<=length_value[15:8];packet[7]<=length_value[7:0];
            tx_length<=length_value+8;tx_position<=0;tx_state<=1;
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin tx_state<=0;tx_position<=0;tx_length<=0;packet_to_pc<=0;
            prepare_pending<=0;query_pending<=0;forward_pending<=0;prepare_pending_body<=0;forward_body<=0;end
        else begin
            case(tx_state)
                0:if(prepare_pending)begin
                    header(16'h0049,8);packet_to_pc<=0;prepare_pending<=0;
                    for(i=0;i<8;i=i+1)packet[8+i]<=prepare_pending_body[8*i+:8];
                end else if(query_pending)begin
                    header(16'h0048,1);packet_to_pc<=0;query_pending<=0;packet[8]<=sequence_id;
                end else if(forward_pending)begin
                    header(16'h0003,16);packet_to_pc<=1;forward_pending<=0;
                    for(i=0;i<16;i=i+1)packet[8+i]<=forward_body[8*i+:8];
                end
                1:if(tx_ack)begin tx_state<=2;tx_position<=0;end
                2:if(tx_position+1>=tx_length)begin tx_state<=0;tx_position<=0;end
                  else tx_position<=tx_position+1'b1;
                default:tx_state<=0;
            endcase
            if(send_prepare)begin prepare_pending<=1;prepare_pending_body<=prepare_body;end
            if(send_query)query_pending<=1;
            if(view_event)begin forward_pending<=1;forward_body<=view_received;end
        end
    end
    always @(posedge clk)begin
        if(rst)begin rx_position<=0;rx_kind<=0;rx_length<=0;rx_good<=0;
            rx_body<=0;prepare_event<=0;view_event<=0;view_received<=0;prepare_received<=0;end
        else begin
            prepare_event<=0;view_event<=0;
            if(rx_valid)begin
                if(rx_position!=511)rx_position<=rx_position+1'b1;else rx_good<=0;
                case(rx_position)
                    0:rx_good<=rx_data==8'haa;
                    1:rx_good<=rx_good && rx_data==8'hbb;
                    2:rx_good<=rx_good && rx_data==8'hcc;
                    3:rx_good<=rx_good && rx_data==8'hdd;
                    4:rx_kind[15:8]<=rx_data;5:rx_kind[7:0]<=rx_data;
                    6:rx_length[15:8]<=rx_data;7:rx_length[7:0]<=rx_data;
                    default:if(rx_position>=8 && rx_position<24)rx_body[8*(rx_position-8)+:8]<=rx_data;
                endcase
            end else begin
                if(rx_good && rx_position==rx_length+8)begin
                    if(rx_kind==16'h004a && rx_length==8)begin prepare_received<=rx_body[63:0];prepare_event<=1;end
                    if(rx_kind==16'h0048 && rx_length==16)begin view_received<=rx_body;view_event<=1;end
                end
                rx_position<=0;
            end
        end
    end
    task automatic request_target(input [7:0] action_value,input [1:0] mode,input [7:0] win);
        begin
            prepare_body<={16'd0,active_generation,win,6'd0,mode,action_value,sequence_id};
            sequence_id<=sequence_id+1'b1;send_prepare<=1;timer<=0;attempts<=1;
        end
    endtask
    always @(posedge clk)begin
        if(rst)begin
            state<=WAIT_LINK;loaded<=0;view_busy<=0;page_build<=0;failed<=0;
            sequence_id<=1;action_held<=0;layout_held<=0;preferred_held<=255;
            timer<=0;attempts<=0;send_prepare<=0;send_query<=0;prepare_body<=0;last_view<=0;
            job_start<=0;job_snapshot<=0;job_previous<=0;job_index<=0;job_layout<=0;job_window<=0;job_generation<=0;
            active_layout<=0;active_mask<=0;active_generation<=0;view_status_valid<=0;view_status_body<=0;
        end else begin
            send_prepare<=0;send_query<=0;job_start<=0;view_status_valid<=0;
            timer<=timer+1'b1;
            if(view_event)begin
                last_view<=view_received;active_layout<=view_received[25:24];
                active_generation<=view_received[23:8];active_mask<=view_received[51:48];
                view_busy<=view_received[32];view_status_body<=view_received;view_status_valid<=1;
            end
            case(state)
                WAIT_LINK:if(link_ready)begin send_query<=1;timer<=0;state<=SYNC_VIEW;end
                SYNC_VIEW:if(view_event && !view_received[32])begin state<=IDLE;timer<=0;end
                    else if(timer>=CLK_HZ/2)begin send_query<=1;timer<=0;end
                IDLE:if(!view_busy && link_ready)begin
                    if(!loaded || next_request || prev_request || layout_request || snapshot_request)begin
                        action_held<=!loaded || layout_request ? 0 : (snapshot_request ? 4 : (prev_request ? 2 : 1));
                        layout_held<=!loaded ? 0 : (layout_request ? requested_layout : active_layout);
                        preferred_held<=touch_request ? 8'hfe : 8'hff;
                        page_build<=loaded && layout_request && requested_layout!=0 && requested_layout!=active_layout;
                        failed<=0;
                        request_target(!loaded || layout_request ? 0 : (snapshot_request ? 4 : (prev_request ? 2 : 1)),
                                       !loaded ? 0 : (layout_request ? requested_layout : active_layout),
                                       touch_request ? 8'hfe : 8'hff);
                        state<=WAIT_PREP;
                    end
                end else if(view_busy && link_ready && timer>=CLK_HZ/2)begin
                    // VIEW_STATUS is UDP: if the release event is lost, keep
                    // querying until the display confirms its lease is idle.
                    send_query<=1;timer<=0;
                end
                WAIT_PREP:if(prepare_event && prepare_received[7:0]==prepare_body[7:0])begin
                    if(prepare_received[15:8]==0)begin
                        job_layout<=layout_held;job_window<=prepare_received[17:16];
                        job_generation<=prepare_received[47:32];job_snapshot<=action_held==4;job_previous<=action_held==2;
                        if(!loaded)job_index<=first_bmp[4:0];
                        else if(action_held==1)job_index<=bmp_next[6*prepare_received[52:48]+:5];
                        else if(action_held==2)job_index<=bmp_prev[6*prepare_received[52:48]+:5];
                        else job_index<=prepare_received[52:48];
                        state<=LAUNCH;
                    end else begin state<=SYNC_VIEW;send_query<=1;timer<=0;loaded<=current_valid;end
                end else if(timer>=CLK_HZ)begin
                    if(attempts<3)begin send_prepare<=1;attempts<=attempts+1'b1;timer<=0;end
                    else begin request_target(3,active_layout,255);state<=RELEASE;failed<=1;end
                end
                LAUNCH:if(link_ready)begin job_start<=1;state<=WAIT_JOB;end
                WAIT_JOB:if(job_done)begin
                    if(job_result==3 && page_build && job_window<(job_layout==1 ? 1 : 3))begin
                        job_window<=job_window+1'b1;job_index<=bmp_next[6*job_index+:5];state<=LAUNCH;
                    end else if(job_result==2)begin
                        if(job_snapshot)begin request_target(5,active_layout,255);state<=RELEASE;end
                        else begin send_query<=1;state<=WAIT_STATUS;timer<=0;loaded<=1;end
                    end else begin request_target(3,active_layout,255);state<=RELEASE;failed<=1;end
                end
                RELEASE:if(prepare_event && prepare_received[7:0]==prepare_body[7:0])begin
                    send_query<=1;timer<=0;state<=WAIT_STATUS;
                end else if(timer>=CLK_HZ)begin
                    if(attempts<3)begin send_prepare<=1;attempts<=attempts+1'b1;timer<=0;end
                    else begin send_query<=1;timer<=0;state<=WAIT_STATUS;end
                end
                WAIT_STATUS:if(view_event && !view_received[32] &&
                    (failed || job_snapshot || (view_received[25:24]==job_layout && view_received[23:8]==job_generation)))begin
                    state<=IDLE;timer<=0;
                end else if(timer>=CLK_HZ/2)begin send_query<=1;timer<=0;end
                default:state<=WAIT_LINK;
            endcase
        end
    end
endmodule
