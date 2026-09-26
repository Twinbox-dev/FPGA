// vsrc/wav_reader.v — WAV 文件解析器（阶段 2）
//
// 上游：fat32_ro 的文件字节流（与 bmp_dec 并联共享）
// 下游：阶段 2 只到 TB 观测口（导出 out/audio.wav 人耳验收）；
//       阶段 3 接音频缓存 → audio_out → HDMI 音频口
// 板级：原样搬，但须先补背压（同 bmp_dec，见 docs/TODO.md 3a）
// 全局视图见 docs/architecture.md
//
// 为什么不能像 BMP 那样按固定偏移读：
//   WAV 是 RIFF 容器，fmt 与 data 之间允许插入任意块（LIST/INFO、fact 等），
//   真实文件（含 Windows 录音、转码工具输出）经常带这些块。所以必须走
//   chunk 链：读 ckID(4B) + ckSize(4B) → 认识就解析、不认识就按 ckSize 跳过。
//
// 限定（与 design.md §7 一致）：PCM(fmt=1)、48kHz、16bit、单声道或立体声。
//   不合格 → o_fmt_err（不重采样、不解压，避免把 DSP 搬进控制路径）
// 输出：每帧一组样本，单声道时左右同值；o_sval 一拍有效。
module wav_reader (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 文件字节流（来自 fat32_ro）----
    input  wire [7:0]  i_byte,
    input  wire        i_bval,
    input  wire        i_restart,     // 新文件开始：复位解析状态

    // ---- PCM 样本流 ----
    output reg signed [15:0] o_left,
    output reg signed [15:0] o_right,
    output reg         o_sval,        // 样本有效，一拍
    output reg         o_hdr_ok,      // fmt/data 就位，开始出样本
    output reg         o_fmt_err,     // 非 PCM / 采样率或位宽不支持 / 结构损坏
    output reg  [31:0] o_data_bytes,  // data 块字节数（供上层算时长）
    output wire [7:0]  o_dbg_state
);

    localparam [7:0]
        S_RIFF  = 8'd0,   // 'RIFF' + 文件长度 + 'WAVE'
        S_CKHDR = 8'd1,   // 块头：ckID + ckSize
        S_FMT   = 8'd2,   // fmt 块内容
        S_SKIP  = 8'd3,   // 跳过不关心的块
        S_DATA  = 8'd4,   // PCM 数据流
        S_DONE  = 8'd5,   // data 读完
        S_ERR   = 8'd6;

    reg [7:0] state;
    assign o_dbg_state = state;

    reg [3:0]  ph;             // 块内字节相位
    reg [31:0] ck_id;          // 块 ID（大端拼接，直接和 "fmt " 等字面比）
    reg [23:0] ck_size;        // 块长度前 3 字节（第 4 字节直通）
    reg [31:0] ck_left;        // 块内剩余字节
    reg [23:0] riff_ok;        // RIFF/WAVE 标识拼接用（4 字节末字节直通比较）

    // fmt 字段
    reg [15:0] fmt_tag;
    reg [15:0] fmt_ch;
    reg [31:0] fmt_rate;
    reg [15:0] fmt_bits;
    reg        fmt_seen;

    // 样本组装：单声道 2 字节一组，立体声 4 字节一组
    reg [1:0]  smp_ph;
    reg [15:0] smp_l;
    reg [7:0]  smp_lo;

    wire ck_is_fmt  = (ck_id == "fmt ");
    wire ck_is_data = (ck_id == "data");
    wire fmt_good   = (fmt_tag == 16'd1) &&
                      (fmt_rate == 32'd48000) &&
                      (fmt_bits == 16'd16) &&
                      ((fmt_ch == 16'd1) || (fmt_ch == 16'd2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RIFF;
            ph <= 4'd0;
            ck_id <= 32'd0;
            ck_size <= 24'd0;
            ck_left <= 32'd0;
            riff_ok <= 24'd0;
            fmt_tag <= 16'd0;
            fmt_ch <= 16'd0;
            fmt_rate <= 32'd0;
            fmt_bits <= 16'd0;
            fmt_seen <= 1'b0;
            smp_ph <= 2'd0;
            smp_l <= 16'd0;
            smp_lo <= 8'd0;
            o_left <= 16'sd0;
            o_right <= 16'sd0;
            o_sval <= 1'b0;
            o_hdr_ok <= 1'b0;
            o_fmt_err <= 1'b0;
            o_data_bytes <= 32'd0;
        end
        else begin
            o_sval <= 1'b0;

            if (i_restart) begin
                state <= S_RIFF;
                ph <= 4'd0;
                ck_id <= 32'd0;
                ck_size <= 24'd0;
                ck_left <= 32'd0;
                riff_ok <= 24'd0;
                fmt_tag <= 16'd0;
                fmt_ch <= 16'd0;
                fmt_rate <= 32'd0;
                fmt_bits <= 16'd0;
                fmt_seen <= 1'b0;
                smp_ph <= 2'd0;
                o_hdr_ok <= 1'b0;
                o_fmt_err <= 1'b0;
                o_data_bytes <= 32'd0;
            end
            else if (i_bval) begin
                case (state)

                    // ===== 'RIFF' + 长度(4B) + 'WAVE' =====
                    S_RIFF: begin
                        ph <= ph + 4'd1;
                        if (ph <= 4'd3 || ph >= 4'd8) begin
                            riff_ok <= {riff_ok[15:0], i_byte};   // 大端拼接便于比字面
                        end
                        if (ph == 4'd3 && {riff_ok, i_byte} != "RIFF") begin
                            state <= S_ERR;
                            o_fmt_err <= 1'b1;
                        end
                        if (ph == 4'd11) begin
                            if ({riff_ok, i_byte} == "WAVE") begin
                                state <= S_CKHDR;
                                ph <= 4'd0;
                            end
                            else begin
                                state <= S_ERR;
                                o_fmt_err <= 1'b1;
                            end
                        end
                    end

                    // ===== 块头：ckID(4B 大端序读) + ckSize(4B 小端) =====
                    S_CKHDR: begin
                        ph <= ph + 4'd1;
                        if (ph <= 4'd3) begin
                            ck_id <= {ck_id[23:0], i_byte};
                        end
                        else begin
                            ck_size <= {i_byte, ck_size[23:8]};   // 小端右插
                        end
                        if (ph == 4'd7) begin
                            ph <= 4'd0;
                            // 此刻 ck_size 的第 4 字节还在 i_byte 上
                            ck_left <= {i_byte, ck_size};
                            if (ck_is_fmt) begin
                                state <= S_FMT;
                            end
                            else if (ck_is_data) begin
                                if (!fmt_seen || !fmt_good) begin
                                    state <= S_ERR;
                                    o_fmt_err <= 1'b1;
                                end
                                else begin
                                    o_data_bytes <= {i_byte, ck_size};
                                    o_hdr_ok <= 1'b1;
                                    smp_ph <= 2'd0;
                                    state <= S_DATA;
                                end
                            end
                            else begin
                                // 不认识的块（LIST/fact/...）：按 ckSize 跳过
                                if ({i_byte, ck_size} == 32'd0)
                                    state <= S_CKHDR;             // 空块，接着读下一个块头
                                else
                                    state <= S_SKIP;
                            end
                        end
                    end

                    // ===== fmt 块：tag/ch/rate/bits，其余字节跳过 =====
                    S_FMT: begin
                        ck_left <= ck_left - 32'd1;
                        case (ph)
                            4'd0: fmt_tag  <= {i_byte, fmt_tag[15:8]};
                            4'd1: fmt_tag  <= {i_byte, fmt_tag[15:8]};
                            4'd2: fmt_ch   <= {i_byte, fmt_ch[15:8]};
                            4'd3: fmt_ch   <= {i_byte, fmt_ch[15:8]};
                            4'd4: fmt_rate <= {i_byte, fmt_rate[31:8]};
                            4'd5: fmt_rate <= {i_byte, fmt_rate[31:8]};
                            4'd6: fmt_rate <= {i_byte, fmt_rate[31:8]};
                            4'd7: fmt_rate <= {i_byte, fmt_rate[31:8]};
                            4'd14: fmt_bits <= {i_byte, fmt_bits[15:8]};
                            4'd15: fmt_bits <= {i_byte, fmt_bits[15:8]};
                            default: ;
                        endcase
                        if (ph != 4'd15) begin
                            ph <= ph + 4'd1;
                        end
                        if (ck_left == 32'd1) begin
                            // 本块最后一个字节
                            fmt_seen <= 1'b1;
                            ph <= 4'd0;
                            state <= S_CKHDR;
                            ck_id <= 32'd0;
                        end
                    end

                    // ===== 跳过不认识的块 =====
                    S_SKIP: begin
                        ck_left <= ck_left - 32'd1;
                        if (ck_left == 32'd1) begin
                            ph <= 4'd0;
                            ck_id <= 32'd0;
                            state <= S_CKHDR;
                        end
                    end

                    // ===== data 块：小端 16bit 样本，按声道组装 =====
                    S_DATA: begin
                        ck_left <= ck_left - 32'd1;
                        if (fmt_ch == 16'd1) begin
                            // 单声道：2 字节一组，左右同值
                            if (smp_ph == 2'd0) begin
                                smp_lo <= i_byte;
                                smp_ph <= 2'd1;
                            end
                            else begin
                                o_left  <= {i_byte, smp_lo};
                                o_right <= {i_byte, smp_lo};
                                o_sval  <= 1'b1;
                                smp_ph  <= 2'd0;
                            end
                        end
                        else begin
                            // 立体声：L低 L高 R低 R高
                            case (smp_ph)
                                2'd0: begin smp_lo <= i_byte;             smp_ph <= 2'd1; end
                                2'd1: begin smp_l  <= {i_byte, smp_lo};   smp_ph <= 2'd2; end
                                2'd2: begin smp_lo <= i_byte;             smp_ph <= 2'd3; end
                                default: begin
                                    o_left  <= smp_l;
                                    o_right <= {i_byte, smp_lo};
                                    o_sval  <= 1'b1;
                                    smp_ph  <= 2'd0;
                                end
                            endcase
                        end
                        if (ck_left == 32'd1) begin
                            state <= S_DONE;
                        end
                    end

                    default: ;   // S_DONE / S_ERR：终态
                endcase
            end
        end
    end

endmodule
