// vsrc/audio_fifo.v — 音频样本环形缓冲（3a，从卡实时流式）
//
// 位置：wav_reader 之后、48kHz 输出之前。wav_reader 按卡速产样本（快且突发），
// 消费端是 48kHz 节拍器。本 FIFO 平滑两者，吸收图片装载期间 SD 读的抖动：
//
//   卡 ─► wav_reader ─(快/突发)─► audio_fifo ─(48kHz 节拍)─► o_left/o_right/o_sval
//
// 容量 8KB = 2048 个 32bit 样本（L[31:16] R[15:0]），约 42ms@48kHz 立体声。
// 卡产速(≈800k样本/s) > 消费速(48k/s)，故稳态下 FIFO 偏满，写满即丢（环形天然
// 保留最早未消费样本，消费是连续流，丢尾部新样本无影响）。真正要防的是读侧下溢：
// 靠 sd_arbiter 的音频优先 + 低水位请求保证，这里是最后一层缓冲。
//
// i_flush：切图时清空旧音频（新音频从头开始）。读侧 i_rd_en 为 48kHz 节拍。
module audio_fifo (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 写侧（来自 wav_reader）----
    input  wire        i_sval,
    input  wire signed [15:0] i_left,
    input  wire signed [15:0] i_right,
    input  wire        i_flush,          // 切图：清空旧音频

    // ---- 读侧（48kHz 输出）----
    input  wire        i_rd_en,          // 48kHz 节拍
    output reg  signed [15:0] o_left,
    output reg  signed [15:0] o_right,
    output reg         o_sval,           // 输出样本有效（一拍）
    output reg         o_underrun,       // 读时为空：输出静音

    // ---- 状态 ----
    output wire [11:0] o_fill            // 当前样本数（0..2048）
);

    localparam [11:0] DEPTH = 12'd2048;

    reg [31:0] mem [0:2047];             // L[31:16] R[15:0]
    reg [10:0] wptr, rptr;
    reg [11:0] cnt;

    assign o_fill = cnt;

    wire w_en = i_sval && (cnt < DEPTH);
    wire r_en = i_rd_en && (cnt != 12'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr <= 11'd0;
            rptr <= 11'd0;
            cnt  <= 12'd0;
            o_left   <= 16'sd0;
            o_right  <= 16'sd0;
            o_sval   <= 1'b0;
            o_underrun <= 1'b0;
        end
        else begin
            o_sval <= 1'b0;
            o_underrun <= 1'b0;

            if (i_flush) begin
                wptr <= 11'd0;
                rptr <= 11'd0;
                cnt  <= 12'd0;
            end
            else begin
                // 写：满则丢（环形保留最早未消费样本）
                if (w_en) begin
                    mem[wptr] <= {i_left, i_right};
                    wptr <= wptr + 11'd1;
                    cnt  <= cnt + 12'd1;
                end
                // 读：空则下溢静音
                if (r_en) begin
                    o_left  <= mem[rptr][31:16];
                    o_right <= mem[rptr][15:0];
                    o_sval  <= 1'b1;
                    rptr <= rptr + 11'd1;
                    cnt  <= cnt - 12'd1;
                end
                else if (i_rd_en && cnt == 12'd0) begin
                    o_underrun <= 1'b1;      // 节拍到了但没样本：静音一拍
                end
            end
        end
    end

endmodule
