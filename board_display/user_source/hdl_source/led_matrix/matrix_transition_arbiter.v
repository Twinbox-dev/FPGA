// Selects live audio bitmap or transition bitmap for the IS31FL3731 driver.
// transition_start_toggle is generated in sd_card_bmp's sd_card_clk domain;
// transition_done_toggle and frame_tick_toggle originate in video_clk and are
// synchronized here before use.
module matrix_transition_arbiter (
    input  wire         clk,
    input  wire         rst,
    input  wire         hard_cut,
    input  wire [1:0]   transition_type_in,
    input  wire         transition_direction_in,
    input  wire         transition_start_toggle,
    input  wire         transition_done_toggle,
    input  wire         frame_tick_toggle,
    input  wire [6:0]   transition_duration_frames_in,
    input  wire [104:0] audio_bitmap,
    input  wire         audio_frame_ready,
    output wire [104:0] matrix_bitmap_out,
    output reg          frame_ready_out
);
    reg start_toggle_d;
    reg [2:0] done_sync;
    reg [2:0] frame_sync;
    reg done_toggle_d;
    reg frame_toggle_d;
    reg transition_active;
    reg [1:0] transition_type_latched;
    reg transition_direction_latched;
    reg [6:0] transition_duration_latched;

    wire start_event = transition_start_toggle ^ start_toggle_d;
    wire done_event = done_sync[2] ^ done_toggle_d;
    wire frame_event = frame_sync[2] ^ frame_toggle_d;

    wire [104:0] effect_bitmap;
    wire effect_frame_valid;
    wire [6:0] elapsed_frames;

    matrix_transition_animator u_matrix_transition_animator (
        .clk                         (clk),
        .rst                         (rst),
        .active                      (transition_active),
        .transition_type             (transition_type_latched),
        .transition_direction        (transition_direction_latched),
        .transition_duration_frames (transition_duration_latched),
        .frame_tick                  (frame_event),
        .audio_bitmap                (audio_bitmap),
        .effect_bitmap               (effect_bitmap),
        .effect_frame_valid          (effect_frame_valid),
        .elapsed_frames              (elapsed_frames)
    );

    assign matrix_bitmap_out = transition_active ? effect_bitmap : audio_bitmap;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            start_toggle_d <= 1'b0;
            done_sync <= 3'b000;
            frame_sync <= 3'b000;
            done_toggle_d <= 1'b0;
            frame_toggle_d <= 1'b0;
            transition_active <= 1'b0;
            transition_type_latched <= 2'd0;
            transition_direction_latched <= 1'b0;
            transition_duration_latched <= 7'd1;
            frame_ready_out <= 1'b0;
        end else begin
            start_toggle_d <= transition_start_toggle;
            done_sync <= {done_sync[1:0], transition_done_toggle};
            frame_sync <= {frame_sync[1:0], frame_tick_toggle};
            done_toggle_d <= done_sync[2];
            frame_toggle_d <= frame_sync[2];

            // One-cycle update request for the matrix driver.
            frame_ready_out <= 1'b0;

            if (done_event) begin
                transition_active <= 1'b0;
                frame_ready_out <= 1'b1; // Restore the latest audio bitmap.
            end else if (start_event) begin
                if (!hard_cut) begin
                    transition_active <= 1'b1;
                    transition_type_latched <= transition_type_in;
                    transition_direction_latched <= transition_direction_in;
                    transition_duration_latched <= transition_duration_frames_in;
                    frame_ready_out <= 1'b1; // Publish the first transition frame.
                end else begin
                    transition_active <= 1'b0;
                    frame_ready_out <= 1'b1;
                end
            end else if (transition_active && effect_frame_valid) begin
                frame_ready_out <= 1'b1;
            end else if (transition_active &&
                         transition_type_latched != 2'd1 && audio_frame_ready) begin
                // Effects without a matrix renderer yet keep the live audio
                // image updating instead of freezing it for the video cut.
                frame_ready_out <= 1'b1;
            end else if (!transition_active && audio_frame_ready) begin
                frame_ready_out <= 1'b1;
            end
        end
    end
endmodule
