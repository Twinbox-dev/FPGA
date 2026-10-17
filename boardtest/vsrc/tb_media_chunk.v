`timescale 1ns/1ps

// Exercises packet bytes, CRC, truncation, and the 253-word RAM boundary.
// Vendor UDP/IP is replaced by a byte-stream connection between the two
// application modules; board routing and retransmission require board tests.
module tb_media_chunk;
    reg clk=0;
    always #4 clk=~clk;
    reg rst=1, start=0, data_valid=0;
    reg [15:0] session=0, sequence_id=0;
    reg [7:0] count=0, flags=0;
    reg [31:0] data_word=0;
    wire data_ready, tx_request, tx_valid, tx_busy, tx_done;
    wire [7:0] tx_byte;
    wire [15:0] tx_length;
    reg [10:0] beat=0;
    reg inject_error=0, truncate_packet=0;
    wire rx_valid=tx_valid && !(truncate_packet && beat>=11'd25);
    wire [7:0] rx_byte=tx_byte ^ ((inject_error && beat==11'd17) ? 8'h01 : 8'h00);
    wire chunk_valid, packet_error, rx_busy, word_valid, chunk_done;
    wire [15:0] chunk_session, chunk_sequence;
    wire [7:0] chunk_count, chunk_flags;
    wire [31:0] word_data;
    integer received=0, accepted=0, rejected=0, completed=0;
    integer expected_words=0;

    media_chunk_tx sender (
        .clk(clk), .rst(rst), .start(start), .session(session),
        .sequence_id(sequence_id), .count(count), .flags(flags),
        .data_word(data_word), .data_valid(data_valid), .data_ready(data_ready),
        .tx_ack(tx_request), .tx_request(tx_request), .tx_valid(tx_valid),
        .tx_byte(tx_byte), .tx_length(tx_length), .busy(tx_busy), .done(tx_done)
    );
    media_chunk_rx receiver (
        .clk(clk), .rst(rst), .rx_byte(rx_byte), .rx_valid(rx_valid),
        .chunk_valid(chunk_valid), .chunk_session(chunk_session),
        .chunk_sequence(chunk_sequence), .chunk_count(chunk_count),
        .chunk_flags(chunk_flags), .packet_error(packet_error), .busy(rx_busy),
        .word_data(word_data), .word_valid(word_valid), .word_ready(1'b1),
        .chunk_done(chunk_done)
    );

    function [31:0] pattern;
        input integer index;
        begin
            pattern = 32'ha5c30000 ^ (32'h01020307 * index);
        end
    endfunction

    always @(posedge clk) begin
        if (rst)
            beat <= 0;
        else if (tx_valid)
            beat <= beat+11'd1;
        else
            beat <= 0;
        if (!rst) begin
            // Independent Python binascii.crc_hqx golden for the one-word
            // packet: 02 13 43 00 01 01 00 00 c3 a5 -> CRC 0x3615.
            if (tx_valid && count==8'd1 && !inject_error && !truncate_packet) begin
                if ((beat==11'd8  && tx_byte!=8'h02) ||
                    (beat==11'd9  && tx_byte!=8'h13) ||
                    (beat==11'd10 && tx_byte!=8'h43) ||
                    (beat==11'd11 && tx_byte!=8'h00) ||
                    (beat==11'd14 && tx_byte!=8'h15) ||
                    (beat==11'd15 && tx_byte!=8'h36))
                    $fatal(1,"independent header/CRC golden mismatch at %0d",beat);
            end
            if (chunk_valid) begin
                accepted=accepted+1;
                if (chunk_session!=session || chunk_sequence!=sequence_id ||
                    chunk_count!=count || chunk_flags!=flags)
                    $fatal(1,"metadata mismatch");
            end
            if (packet_error) rejected=rejected+1;
            if (word_valid) begin
                if (received>=expected_words || word_data!=pattern(received))
                    $fatal(1,"word %0d: %08x",received,word_data);
                received=received+1;
            end
            if (chunk_done) completed=completed+1;
        end
    end

    task run_case(input integer n, input bit corrupt, input bit cut_short);
        integer i, a0, r0, d0, guard;
        begin
            a0=accepted; r0=rejected; d0=completed;
            received=0; expected_words=n;
            @(negedge clk);
            session=16'h1302; sequence_id=16'h0042+n[15:0];
            count=n[7:0]; flags=8'h01;
            inject_error=corrupt; truncate_packet=cut_short;
            start=1;
            @(negedge clk); start=0;
            for (i=0; i<n; i=i+1) begin
                guard=0;
                while (!data_ready && guard<10000) begin
                    @(negedge clk); guard=guard+1;
                end
                if (!data_ready) $fatal(1,"TX load timeout");
                data_word=pattern(i); data_valid=1;
                @(negedge clk); data_valid=0;
            end
            guard=0;
            while (tx_busy && guard<10000) begin
                @(negedge clk); guard=guard+1;
            end
            if (tx_busy) $fatal(1,"TX packet timeout");
            guard=0;
            while (accepted==a0 && rejected==r0 && guard<10000) begin
                @(negedge clk); guard=guard+1;
            end
            if (guard==10000) $fatal(1,"RX completion timeout");
            guard=0;
            while (rx_busy && guard<10000) begin
                @(negedge clk); guard=guard+1;
            end
            if (rx_busy) $fatal(1,"RX drain timeout");
            repeat(5) @(negedge clk);
            if (corrupt || cut_short) begin
                if (accepted!=a0 || rejected!=r0+1 || received!=0)
                    $fatal(1,"invalid packet was accepted");
            end else if (accepted!=a0+1 || rejected!=r0 ||
                         completed!=d0+1 || received!=n)
                $fatal(1,"valid packet failed: n=%0d acc=%0d err=%0d done=%0d words=%0d",
                       n,accepted-a0,rejected-r0,completed-d0,received);
        end
    endtask

    initial begin
        repeat(5) @(negedge clk); rst=0;
        run_case(1,0,0);
        run_case(7,0,0);
        run_case(253,0,0);
        run_case(4,1,0);
        run_case(4,0,1);
        $display("PASS: media chunk framing, CRC, RAM boundary, corrupt/truncated rejection");
        $finish;
    end
endmodule
