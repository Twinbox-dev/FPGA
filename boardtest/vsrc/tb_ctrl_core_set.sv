`timescale 1ns/1ps

module tb_ctrl_core_set;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, cmd_val=0, set_valid=0;
    reg [7:0] cmd=0,set_op=0,set_value=0;
    wire [3:0] vol_gain,brightness_value,contrast_value;
    wire [1:0] effect,osd_mode,sensitivity_value;
    wire [2:0] cv_effect_mode,cv_effect_gray;
    wire bar_en;
    wire tx_req;
    wire [63:0] tx_pkt;
    ctrl_core #(.VK_PULSE_CYC(16)) dut (
        .clk(clk),.rst(rst),.cmd(cmd),.cmd_val(cmd_val),
        .set_valid(set_valid),.set_op(set_op),.set_value(set_value),
        .touch_next(1'b0),.touch_prev(1'b0),
        .subtitle_consume(1'b0),.subtitle_ack_pulse(1'b0),.subtitle_ack_ok(1'b0),
        .vk_next_n(),.vk_auto_n(),.vk_prev_n(),.tx_req(tx_req),.tx_pkt(tx_pkt),
        .vol_gain(vol_gain),.brightness_value(brightness_value),
        .contrast_value(contrast_value),.sensitivity_value(sensitivity_value),
        .auto_period_s(),.transition_mode(effect),.osd_mode(osd_mode),
        .cv_effect_mode(cv_effect_mode),.cv_effect_gray(cv_effect_gray),
        .vol_gray(),.bri_gray(),.ct_gray(),.bar_en(bar_en),.bar_sens_gray(),
        .pl_pkt(64'd0),.pl_pkt_val(1'b0),.pl_dump_start(),.rdump_start(),
        .state_code(4'd0),.dbg_fat_state(8'd0),.flag_a(4'd0),.flag_b(4'd0),
        .dbg_underrun(4'd0),.img_idx(5'd0),.img_wav(1'b0),.ld_diag(8'd0),.auto_on(1'b0)
    );

    task automatic apply_set(input [7:0] op,input [7:0] value);
        begin
            @(negedge clk); set_op=op;set_value=value;set_valid=1;
            @(negedge clk); set_valid=0;
            repeat(2) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        apply_set(1,4); if(vol_gain!=4) $fatal(1,"volume SET");
        apply_set(2,7); if(brightness_value!=7) $fatal(1,"brightness SET");
        apply_set(3,5); if(contrast_value!=5) $fatal(1,"contrast SET");
        apply_set(4,2); if(effect!=2) $fatal(1,"effect SET");
        apply_set(5,0); if(osd_mode!=0) $fatal(1,"OSD SET");
        apply_set(6,1); if(!bar_en) $fatal(1,"spectrum SET");
        apply_set(7,3); if(sensitivity_value!=3) $fatal(1,"sensitivity SET");
        apply_set(9,5); if(cv_effect_mode!=5 || cv_effect_gray!=3'b111) $fatal(1,"CV SET/Gray CDC mode=%0d gray=%b",cv_effect_mode,cv_effect_gray);
        apply_set(9,6); if(cv_effect_mode!=5) $fatal(1,"invalid CV SET changed mode");
        @(negedge clk);cmd=8'h2b;cmd_val=1;
        @(negedge clk);cmd_val=0;
        repeat(2) @(negedge clk);
        if(vol_gain!=5) $fatal(1,"increment command after SET");
        $display("PASS: absolute SET values and legacy relative command behavior");
        $finish;
    end
    initial begin #100000; $fatal(1,"timeout"); end
endmodule
