// 转场动画帧步进与紧缩编码模块（无损零大表优化版）
`timescale 1ns / 1ps

module matrix_transition_animator (
    input  wire         clk,
    input  wire         rst,
    input  wire         active,
    input  wire [1:0]   transition_type,
    input  wire         transition_direction,
    input  wire [6:0]   transition_duration_frames,
    input  wire         frame_tick,
    input  wire [104:0] audio_bitmap,
    output wire [104:0] effect_bitmap,
    output wire         effect_frame_valid,
    output reg  [6:0]   elapsed_frames
);
    wire [6:0] safe_duration = (transition_duration_frames == 7'd0) ?
                               7'd1 : transition_duration_frames;
    reg  [7:0] frame_phase;
    reg  [4:0] animation_frame;
    wire [5:0] animation_frame_count = (transition_type == 2'd1) ? 6'd16 : 6'd21;
    wire [7:0] next_phase = {1'b0, frame_phase} + {2'b00, animation_frame_count};

    wire fade_selected        = active && (transition_type == 2'd1);
    wire left_slide_selected  = active && (transition_type == 2'd2) && !transition_direction;
    wire right_slide_selected = active && (transition_type == 2'd2) &&  transition_direction;

    // 紧缩动画模式编码：0=音频频谱，1=菱形淡入淡出，2=左滑，3=右滑
    wire [1:0] anim_mode = fade_selected        ? 2'd1 :
                           left_slide_selected  ? 2'd2 :
                           right_slide_selected ? 2'd3 : 2'd0;

    // 低 90 位直通音频柱高与顶灯状态（0 LUT 门级开销），[96:90] 携带 7-bit 动画状态
    assign effect_bitmap      = {8'd0, anim_mode, animation_frame, audio_bitmap[89:0]};
    assign effect_frame_valid = frame_tick && (anim_mode != 2'd0);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            elapsed_frames  <= 7'd0;
            frame_phase     <= 8'd0;
            animation_frame <= 5'd0;
        end else if (!active) begin
            elapsed_frames  <= 7'd0;
            frame_phase     <= 8'd0;
            animation_frame <= 5'd0;
        end else if (frame_tick) begin
            if (elapsed_frames < safe_duration)
                elapsed_frames <= elapsed_frames + 7'd1;

            if (animation_frame < animation_frame_count - 1'b1) begin
                if (next_phase >= {1'b0, safe_duration}) begin
                    frame_phase     <= next_phase - {1'b0, safe_duration};
                    animation_frame <= animation_frame + 5'd1;
                end else begin
                    frame_phase <= next_phase[7:0];
                end
            end
        end
    end

endmodule
