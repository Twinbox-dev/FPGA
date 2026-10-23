`timescale 1ns/1ps

// The unchanged historical parser is compiled as wav_reader_reference. Check
// every output on every clock, plus independent PCM/format golden assertions.
module tb_wav_reader_compact;
    reg clk=0, rst_n=0, i_bval=0, i_restart=0;
    reg [7:0] i_byte=0;
    always #5 clk=~clk;
    wire [7:0] sample_new,sample_ref;
    wire valid_new,valid_ref,header_new,header_ref,error_new,error_ref;
    wire [31:0] bytes_new,bytes_ref;
    wav_reader dut(.clk(clk),.rst_n(rst_n),.i_byte(i_byte),.i_bval(i_bval),
        .i_restart(i_restart),.o_smp(sample_new),.o_sval(valid_new),
        .o_hdr_ok(header_new),.o_fmt_err(error_new),.o_data_bytes(bytes_new));
    wav_reader_reference reference_dut(.clk(clk),.rst_n(rst_n),.i_byte(i_byte),.i_bval(i_bval),
        .i_restart(i_restart),.o_smp(sample_ref),.o_sval(valid_ref),
        .o_hdr_ok(header_ref),.o_fmt_err(error_ref),.o_data_bytes(bytes_ref));

    integer cycle=0,seen=0,cases=0;
    bit check_pcm=0;
    reg [31:0] rng=32'h74931ab5;
    function automatic [31:0] random_word();
        rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
        return rng;
    endfunction
    function automatic [7:0] pcm(input integer index);
        return (index*73+19)&255;
    endfunction
    always @(posedge clk) begin
        #1;
        cycle=cycle+1;
        if({sample_new,valid_new,header_new,error_new,bytes_new} !==
           {sample_ref,valid_ref,header_ref,error_ref,bytes_ref})
            $fatal(1,"cycle %0d mismatch output/flags new=%x ref=%x",cycle,
                {sample_new,valid_new,header_new,error_new,bytes_new},
                {sample_ref,valid_ref,header_ref,error_ref,bytes_ref});
        if(valid_new)begin
            if(check_pcm && sample_new!==pcm(seen))
                $fatal(1,"PCM golden mismatch sample %0d got %02x",seen,sample_new);
            seen=seen+1;
        end
    end

    task automatic put(input [7:0] value);
        @(negedge clk);
        if((random_word()&7)==0)begin
            i_bval=0;repeat(2)@(negedge clk);
        end
        i_bval=1;i_byte=value;
    endtask
    task automatic u32(input [31:0] value);
        for(integer b=0;b<4;b=b+1)put(value[b*8+:8]);
    endtask
    task automatic chunk(input [31:0] tag,input [31:0] size);
        u32(tag);u32(size);
    endtask
    task automatic restart_file;
        @(negedge clk);i_bval=0;i_restart=1;
        @(negedge clk);i_restart=0;seen=0;
    endtask
    task automatic riff;
        u32(32'h46464952);u32(32'd1024);u32(32'h45564157);
    endtask
    function automatic [7:0] fmt_byte(input integer index);
        case(index)
            0,2: return 1;
            4: return 8'hc0;
            5: return 8'h5d;
            14: return 8;
            default:return 0;
        endcase
    endfunction
    task automatic format_chunk(input integer length,input integer bad_pos,input [7:0] bad_value);
        chunk(32'h20746d66,length);
        for(integer b=0;b<length;b=b+1)
            put(b==bad_pos ? bad_value : fmt_byte(b));
    endtask
    task automatic finish_case(input integer count,input bit legal);
        @(negedge clk);i_bval=0;repeat(3)@(negedge clk);
        if(legal)begin
            if(!header_new || error_new || bytes_new!=count || seen!=count)
                $fatal(1,"legal case count=%0d got samples=%0d flags=%b%b size=%0d",
                    count,seen,header_new,error_new,bytes_new);
        end else if(!error_new || seen!=0)
            $fatal(1,"invalid format accepted: flags=%b%b samples=%0d",header_new,error_new,seen);
        cases=cases+1;
    endtask
    task automatic wave(input integer count,input integer fmt_length,
                        input integer junk_length,input integer bad_pos,input [7:0] bad_value);
        bit legal;
        legal=fmt_length>=16 && (bad_pos<0 || bad_pos>=16 ||
              (bad_pos>=8 && bad_pos<=13) || bad_value==fmt_byte(bad_pos));
        restart_file();check_pcm=1;riff();
        chunk(32'h4b4e554a,junk_length);
        for(integer b=0;b<junk_length;b=b+1)put(random_word());
        format_chunk(fmt_length,bad_pos,bad_value);
        chunk(32'h61746164,count);
        for(integer b=0;b<count;b=b+1)put(pcm(b));
        // Non-empty DATA must stop exactly at its declared sample count.
        for(integer b=0;b<8;b=b+1)put(0);
        finish_case(count,legal);
    endtask

    initial begin
        repeat(4)@(negedge clk);rst_n=1;
        wave(0,16,0,-1,0);wave(1,16,2,-1,0);wave(31,18,17,-1,0);
        wave(256,40,0,-1,0);wave(511,16,4,-1,0);
        wave(512,16,0,-1,0);wave(513,16,8,-1,0);wave(1025,18,0,-1,0);
        // Exercise every value of every fmt byte, including deliberately
        // ignored byteRate/blockAlign bytes and all high bytes of fixed fields.
        for(integer field=0;field<16;field=field+1)
            for(integer value=0;value<256;value=value+1)
                wave(3,16,0,field,value[7:0]);
        for(integer length=0;length<16;length=length+1)
            wave(4,length,0,-1,0);
        // A second fmt chunk replaces the first, without carrying stale match state.
        restart_file();riff();format_chunk(16,0,0);format_chunk(18,-1,0);
        chunk(32'h61746164,2);put(pcm(0));put(pcm(1));finish_case(2,1);
        restart_file();riff();format_chunk(16,-1,0);format_chunk(16,7,1);
        chunk(32'h61746164,1);put(0);finish_case(1,0);
        restart_file();riff();chunk(32'h61746164,1);put(0);finish_case(1,0);
        // Large counters are exercised without waiting billions of cycles.
        check_pcm=0;
        restart_file();riff();chunk(32'h4b4e554a,32'hffffffff);
        repeat(97)put(random_word());
        restart_file();riff();format_chunk(16,-1,0);chunk(32'h61746164,32'hffffffff);
        repeat(97)put(random_word());
        // Truncation/restart at arbitrary header/body phases and byte-valid gaps.
        for(integer trial=0;trial<128;trial=trial+1)begin
            restart_file();riff();format_chunk(16,-1,0);chunk(32'h61746164,1024);
            repeat(trial)put(random_word());
            @(negedge clk);i_bval=0;i_restart=1;
            @(negedge clk);i_restart=0;
        end
        for(integer n=0;n<20000;n=n+1)begin
            @(negedge clk);i_byte=random_word();i_bval=(random_word()&1)!=0;
            i_restart=(random_word()&255)==0;
            if((random_word()&1023)==0)rst_n=0;else rst_n=1;
        end
        @(negedge clk);i_bval=0;i_restart=0;rst_n=1;
        wave(64,16,0,-1,0);
        $display("PASS WAV compact: %0d golden cases, %0d clocks cycle-equivalent, resets/restarts/gaps",cases,cycle);
        $finish;
    end
    initial begin #100000000;$fatal(1,"timeout");end
endmodule
