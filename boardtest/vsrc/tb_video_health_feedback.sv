module tb_video_health_feedback;
    reg clk=0, rst=1;
    reg nack_event=0, credit_event=0, digest_ack=0;
    reg [15:0] nack_sequence=0, credit_next_sequence=0;
    reg [7:0] free_row_credits=0;
    wire digest_req, digest_valid;
    wire [7:0] digest_data;
    wire [15:0] digest_length;
    reg [7:0] bytes[0:7];
    integer n, timeout;

    always #5 clk=~clk;

    direct_video_feedback_tx #(.HEALTH_FLAGS_ENABLED(1)) dut(
        .clk(clk),.rst(rst),.health_flags(7'd3),
        .nack_event(nack_event),.nack_sequence(nack_sequence),
        .credit_event(credit_event),.credit_next_sequence(credit_next_sequence),
        .free_row_credits(free_row_credits),
        .digest_req(digest_req),.digest_valid(digest_valid),
        .digest_data(digest_data),.digest_length(digest_length),.digest_ack(digest_ack)
    );

    task capture_packet;
        begin
            timeout=0;
            while (!digest_req && timeout<20) begin @(negedge clk); timeout=timeout+1; end
            if (!digest_req || digest_length!=8) $fatal(1,"feedback request was not issued");
            @(negedge clk); digest_ack=1;
            @(negedge clk); digest_ack=0;
            n=0; timeout=0;
            while (n<8 && timeout<20) begin
                @(posedge clk);
                if (digest_valid) begin bytes[n]=digest_data; n=n+1; end
                timeout=timeout+1;
            end
            if (n!=8) $fatal(1,"feedback datagram was incomplete");
        end
    endtask

    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        nack_sequence=16'h1234; nack_event=1;
        @(negedge clk); nack_event=0;
        capture_packet();
        if (bytes[0]!=8'h56 || bytes[1]!=8'h41 ||
            bytes[2]!=1 || bytes[3]!=2 || {bytes[5],bytes[4]}!=16'h1234)
            $fatal(1,"NACK feedback packet fields incorrect");

        credit_next_sequence=16'h5678; free_row_credits=8'd17; credit_event=1;
        @(negedge clk); credit_event=0;
        capture_packet();
        if (bytes[0]!=8'h56 || bytes[1]!=8'h41 || bytes[2]!=1 || bytes[3]!=1 ||
            {bytes[5],bytes[4]}!=16'h5678 || bytes[6]!=17 || bytes[7]!=6)
            $fatal(1,"CREDIT feedback packet fields incorrect");

        $display("PASS compact health bits and legacy feedback: NACK sequence and absolute CREDIT window");
        $finish;
    end
endmodule


