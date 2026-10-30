module tb_direct_video_row_parser #(
    parameter integer PIXELS_PER_ROW=720,
    parameter integer ACTIVE_LINES=360
);
    localparam integer PACKET_BYTES=14+2*PIXELS_PER_ROW;
    localparam integer CRC_OFFSET=PACKET_BYTES-2;
    reg clk=0, rst=1;
    reg packet_start=0, packet_end=0;
    reg [15:0] packet_length=0;
    reg rx_valid=0;
    reg [7:0] rx_data=0;
    wire row_prepare,row_begin, row_stream_start, pixel_write, row_commit, row_reject;
    wire [15:0] row_frame_id, row_sequence, pixel_data,crc_seed_out,crc_expected_out;
    wire [8:0] row_index;
    wire session_request;
    wire [9:0] pixel_index;
    wire [31:0] accepted_rows, rejected_rows;

    reg [7:0] pkt [0:PACKET_BYTES-1];
    integer n, pixel_count, begin_count, start_count, commit_count, reject_count;
    integer session_request_count=0, cycle_count=0;
    integer start_cycle=-1, commit_cycle=-1, request_cycle=-1;
    reg [15:0] p;

    always #5 clk=~clk;
    reg begin_previous=0;
    always @(posedge clk)begin
        if(rst)begin_previous<=0;
        else begin
            if(pixel_write && (row_begin || begin_previous))
                $fatal(1,"parser violated the two-clock row-header/payload contract");
            begin_previous<=row_begin;
        end
    end

    always @(negedge clk)begin
        if(!rst)begin
            cycle_count=cycle_count+1;
            if(row_stream_start)start_cycle=cycle_count;
            if(row_commit)commit_cycle=cycle_count;
            if(session_request)begin
                session_request_count=session_request_count+1;
                request_cycle=cycle_count;
            end
        end
    end

    direct_video_row_parser #(.PIXELS_PER_ROW(PIXELS_PER_ROW),.ACTIVE_LINES(ACTIVE_LINES)) dut(
        .clk(clk), .rst(rst),
        .packet_start(packet_start), .packet_end(packet_end),
        .packet_length(packet_length), .rx_valid(rx_valid), .rx_data(rx_data),
        .row_prepare(row_prepare),.row_begin(row_begin), .row_stream_start(row_stream_start), .row_frame_id(row_frame_id),
        .row_index(row_index), .row_sequence(row_sequence),
        .pixel_write(pixel_write), .pixel_index(pixel_index), .pixel_data(pixel_data),
        .row_commit(row_commit), .row_reject(row_reject),.row_crc_seed(crc_seed_out),.row_crc_expected(crc_expected_out),
        .accepted_rows(accepted_rows), .rejected_rows(rejected_rows)
    );

    // Diagnostic counters may disappear; parsing, CRC and commit timing may not.
    wire [104:0] off_result;
    wire [31:0] off_accepted,off_rejected;
    direct_video_row_parser #(.PIXELS_PER_ROW(PIXELS_PER_ROW),.ACTIVE_LINES(ACTIVE_LINES),.STATUS_ENABLED(0)) off_path(
        .clk(clk),.rst(rst),.packet_start(packet_start),.packet_end(packet_end),.packet_length(packet_length),.rx_valid(rx_valid),.rx_data(rx_data),
        .row_prepare(off_result[104]),.row_begin(off_result[103]),.row_stream_start(off_result[102]),
        .row_frame_id(off_result[101:86]),.row_index(off_result[85:77]),.row_sequence(off_result[76:61]),
        .pixel_write(off_result[60]),.pixel_index(off_result[59:50]),.pixel_data(off_result[49:34]),
        .row_commit(off_result[33]),.row_reject(off_result[32]),.row_crc_seed(off_result[31:16]),.row_crc_expected(off_result[15:0]),
        .accepted_rows(off_accepted),.rejected_rows(off_rejected));
    always @(posedge clk)begin #1;if(!rst)begin
        if(off_result!=={row_prepare,row_begin,row_stream_start,row_frame_id,row_index,row_sequence,pixel_write,pixel_index,pixel_data,row_commit,row_reject,crc_seed_out,crc_expected_out})
            $fatal(1,"statistics switch changed row parser/CRC behavior");
        if({off_accepted,off_rejected}!==64'd0)$fatal(1,"disabled parser counters not zero");
    end end

    direct_video_session_gate session_gate(
        .clk(clk), .rst(rst), .row_stream_start(row_stream_start),
        .row_frame_id(row_frame_id), .row_index(row_index),
        .row_commit(row_commit), .row_reject(row_reject),
        .request(session_request)
    );

    function [15:0] crc_byte(input [15:0] old_crc, input [7:0] data);
        integer b;
        reg [15:0] v;
        begin
            v=old_crc ^ {data,8'h00};
            for (b=0;b<8;b=b+1)
                v=v[15] ? ((v<<1)^16'h1021) : (v<<1);
            crc_byte=v;
        end
    endfunction

    task build_packet(input integer frame, input integer row, input integer seq,
                      input integer corrupt_crc, input integer flags);
        integer k;
        reg [15:0] crc_value;
        reg [15:0] pixel;
        begin
            pkt[0]=8'h56; pkt[1]=8'h44; pkt[2]=8'h01; pkt[3]=flags[7:0];
            pkt[4]=frame[7:0]; pkt[5]=frame[15:8];
            pkt[6]=row[7:0]; pkt[7]=(row>>8)&8'h01;
            pkt[8]=seq[7:0]; pkt[9]=seq[15:8];
            pkt[10]=8'(PIXELS_PER_ROW); pkt[11]=8'(PIXELS_PER_ROW>>8);
            for (k=0;k<PIXELS_PER_ROW;k=k+1) begin
                pixel=16'ha000 ^ k;
                pkt[12+k*2]=pixel[7:0];
                pkt[13+k*2]=pixel[15:8];
            end
            crc_value=16'hffff;
            for (k=0;k<CRC_OFFSET;k=k+1) crc_value=crc_byte(crc_value,pkt[k]);
            if (corrupt_crc) crc_value=crc_value ^ 16'h0001;
            pkt[CRC_OFFSET]=crc_value[7:0];
            pkt[CRC_OFFSET+1]=crc_value[15:8];
        end
    endtask

    task send_packet(input integer advertised_length, input integer corrupt_crc,
                     input integer frame, input integer row, input integer seq,
                     input integer flags);
        integer k;
        begin
            build_packet(frame,row,seq,corrupt_crc,flags);
            @(negedge clk);
            packet_length=advertised_length;
            for (k=0;k<PACKET_BYTES;k=k+1) begin
                packet_start=(k==0);
                packet_end=(k==PACKET_BYTES-1);
                rx_valid=1;
                rx_data=pkt[k];
                @(posedge clk); #1;
                if (row_begin) begin
                    begin_count=begin_count+1;
                    if (row_frame_id !== frame[15:0] || row_index !== row[8:0] ||
                        row_sequence !== seq[15:0])
                        $fatal(1,"row metadata mismatch");
                end
                if (row_stream_start) start_count=start_count+1;
                if (pixel_write) begin
                    if (pixel_index !== pixel_count[9:0])
                        $fatal(1,"pixel index mismatch got %0d expected %0d",pixel_index,pixel_count);
                    if (pixel_data !== (16'ha000 ^ pixel_count))
                        $fatal(1,"pixel data mismatch at %0d got %04x",pixel_count,pixel_data);
                    pixel_count=pixel_count+1;
                end
                if (row_commit) begin
                    commit_count=commit_count+1;
                    if(PIXELS_PER_ROW==720 && frame==16'h1234 && flags==1 &&
                       (crc_seed_out!==16'h8889 || crc_expected_out!==16'hae18))
                        $fatal(1,"CRC metadata differs from independent Python binascii fixture");
                end
                if (row_reject) reject_count=reject_count+1;
                @(negedge clk);
            end
            packet_start=0; packet_end=0; rx_valid=0; rx_data=0;
            @(posedge clk); #1;
            if (row_commit) begin
                    commit_count=commit_count+1;
                    if(PIXELS_PER_ROW==720 && frame==16'h1234 && flags==1 &&
                       (crc_seed_out!==16'h8889 || crc_expected_out!==16'hae18))
                        $fatal(1,"CRC metadata differs from independent Python binascii fixture");
                end
            if (row_reject) reject_count=reject_count+1;
            @(negedge clk);
        end
    endtask

    initial begin
        pixel_count=0; begin_count=0; start_count=0; commit_count=0; reject_count=0;
        repeat(4) @(negedge clk);
        rst=0;
        send_packet(PACKET_BYTES,0,16'h1234,0,16'h020d,1);
        if (pixel_count!=PIXELS_PER_ROW || begin_count!=1 || start_count!=1 || commit_count!=1 || reject_count!=0)
            $fatal(1,"valid row counts pixel=%0d begin=%0d commit=%0d reject=%0d",
                   pixel_count,begin_count,commit_count,reject_count);
        repeat(2) @(posedge clk);
        #1;
        if(session_request_count!=1 || start_cycle<0 || commit_cycle<=start_cycle || request_cycle<=commit_cycle)
            $fatal(1,"session request must follow complete first-row commit (requests=%0d start=%0d commit=%0d request=%0d)",
                   session_request_count,start_cycle,commit_cycle,request_cycle);

        pixel_count=0;
        send_packet(PACKET_BYTES,1,16'h1235,10,16'h0216,1);
        if (pixel_count!=PIXELS_PER_ROW || commit_count!=1 || reject_count!=1)
            $fatal(1,"bad CRC row not rejected");
        repeat(2) @(posedge clk);
        #1;
        if(session_request_count!=1)
            $fatal(1,"bad CRC SESSION_START row incorrectly requested memory");

        pixel_count=0;
        send_packet(PACKET_BYTES-1,0,16'h1236,11,16'h021f,0);
        if (pixel_count!=PIXELS_PER_ROW || commit_count!=1 || reject_count!=2)
            $fatal(1,"bad length row not rejected px=%0d commit=%0d reject=%0d accepted=%0d rejected=%0d",pixel_count,commit_count,reject_count,accepted_rows,rejected_rows);

        pixel_count=0;
        send_packet(PACKET_BYTES,0,16'h1237,ACTIVE_LINES,16'h0228,0);
        if (begin_count!=3 || start_count!=1 || commit_count!=1 || reject_count!=3)
            $fatal(1,"out-of-range row not rejected");

        pixel_count=0;
        send_packet(PACKET_BYTES,0,16'h1238,0,16'h0231,2);
        if (begin_count!=3 || start_count!=1 || commit_count!=1 || reject_count!=4)
            $fatal(1,"reserved session flag bits must be rejected");

        $display("PASS direct-video row parser/session gate: CRC commit precedes lease request; bad CRC cannot request memory");
        $finish;
    end
endmodule



