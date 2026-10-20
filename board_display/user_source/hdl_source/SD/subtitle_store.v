// Two text banks in one dual-clock RAM. The SD domain writes only the inactive
// bank; a complete upload switches the visible bank on a video VS boundary.
module subtitle_store (
    input  wire       sd_clk,
    input  wire       video_clk,
    input  wire       rst,
    input  wire       wr_en,
    input  wire [7:0] wr_index,
    input  wire [7:0] wr_char,
    input  wire       commit_toggle,
    input  wire [7:0] commit_len,
    output reg        swap_ack_toggle,
    input  wire       vs,
    input  wire [7:0] rd_index,
    output reg  [7:0] rd_char,
    output reg  [7:0] active_len,
    output reg        text_changed_pulse
);
    reg [7:0] text_mem [0:511]; /* fehdl force_ram=1, ram_style="bram" */
    reg active_bank;
    reg active_s0, active_s1;
    reg commit_s0, commit_s1, commit_s2;
    reg [7:0] len_s0, len_s1;
    reg pending;
    reg vs_d;
    wire vs_rise = vs && !vs_d;
    wire commit_pulse = commit_s1 ^ commit_s2;

    always @(posedge sd_clk or posedge rst) begin
        if (rst) begin
            active_s0 <= 1'b0;
            active_s1 <= 1'b0;
        end else begin
            active_s0 <= active_bank;
            active_s1 <= active_s0;
        end
    end
    always @(posedge sd_clk)
        if (wr_en)
            text_mem[{~active_s1, wr_index}] <= wr_char;

    always @(posedge video_clk)
        rd_char <= text_mem[{active_bank, rd_index}];

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            active_bank <= 1'b0;
            active_len <= 8'd0;
            swap_ack_toggle <= 1'b0;
            text_changed_pulse <= 1'b0;
            commit_s0 <= 1'b0; commit_s1 <= 1'b0; commit_s2 <= 1'b0;
            len_s0 <= 8'd0; len_s1 <= 8'd0;
            pending <= 1'b0;
            vs_d <= 1'b0;
        end else begin
            commit_s0 <= commit_toggle;
            commit_s1 <= commit_s0;
            commit_s2 <= commit_s1;
            len_s0 <= commit_len;
            len_s1 <= len_s0;
            vs_d <= vs;
            text_changed_pulse <= 1'b0;
            if (commit_pulse)
                pending <= 1'b1;
            if (vs_rise && pending) begin
                active_bank <= ~active_bank;
                active_len <= len_s1;
                swap_ack_toggle <= ~swap_ack_toggle;
                text_changed_pulse <= 1'b1;
                pending <= 1'b0;
            end
        end
    end
endmodule
