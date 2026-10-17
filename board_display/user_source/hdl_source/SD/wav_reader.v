// =============================================================================
// wav_reader.v — WAV 文件头解析 + PCM 样本流（板级音频规格：24kHz / 8bit / 单声道）
// -----------------------------------------------------------------------------
// 上游：fat32_ro 的文件字节流（i_byte/i_bval，fat32_ro 按目录项 size 截止并拉
//       一拍 o_file_done）；本模块在 i_restart（文件请求同拍）复位解析状态。
//
// 解析规则（与 boardtest/csrc/board_sim.cpp 的 golden 解析逐条一致）：
//   - RIFF/WAVE 魔数校验，不符 → o_fmt_err，吞掉剩余字节
//   - chunk 链遍历：'fmt ' 捕获 audioFormat/channels/rate/bits（体 <16 字节视为
//     畸形 → 拒绝）；'data' 前必须已见合法 fmt，否则 o_fmt_err 吞流；
//     其余 chunk（LIST/INFO/fact...）按 ckSize 跳过 —— 不能按固定偏移找 data
//   - fmt 硬校验：PCM(0x0001) / 1 声道 / 24000 Hz / 8 bit，不符 → o_fmt_err
//   - 通过后 data 块字节 = 无符号 8bit 样本，逐字节 o_smp/o_sval 流出，
//     流满 ckSize 即停（尾随字节如有则吞掉，等下一次 i_restart）
//
// 输出约定：
//   o_hdr_ok / o_fmt_err 为电平，i_restart 清零；o_data_bytes = data 块声明长度，
//   进入 data 时锁存（golden 交叉核对用）。
// =============================================================================
module wav_reader (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 文件字节流（接 fat32_ro）----
    input  wire [7:0]  i_byte,
    input  wire        i_bval,
    input  wire        i_restart,   // 新文件请求同拍脉冲（复位解析状态）

    // ---- PCM 样本流 ----
    output reg  [7:0]  o_smp,
    output reg         o_sval,

    // ---- 头解析结果 ----
    output reg         o_hdr_ok,     // 电平：头合法且已进入 data 流
    output reg         o_fmt_err,    // 电平：格式拒绝（魔数/fmt 不合法/data 无 fmt）
    output reg  [31:0] o_data_bytes  // data 块声明长度（进入 data 时锁存）
);

    // ---------------- 状态 ----------------
    localparam [2:0]
        S_RIFF  = 3'd0,   // 12 字节：'RIFF' + size(4,忽略) + 'WAVE'
        S_CKHDR = 3'd1,   // 8 字节：chunk id(4) + ckSize(4, 小端)，第 8 字节拍组合分发
        S_FMT   = 3'd2,   // fmt 块体：捕获前 16 字节，多余跳过
        S_SKIP  = 3'd3,   // 跳过未知 chunk：ckSize 字节
        S_DATA  = 3'd4,   // data 块：字节流 = 样本
        S_REST  = 3'd5;   // 吞流/收尾：等下一次 i_restart

    reg [2:0]  state;
    reg [4:0]  ph;              // 块内字节相位
    reg [31:0] cksz;            // 当前 chunk 声明长度（cksz_v = 含本拍字节的组合值）
    reg [31:0] dcnt;            // data 已流字节数
    reg [31:0] skipcnt;         // 跳过剩余字节
    reg [31:0] id_reg;          // chunk id（字节 k 在 [8k+7:8k]）
    reg        seen_fmt;        // 已见 fmt 块（体 ≥16 字节才算）
    // fmt 字段（小端捕获）
    reg [15:0] f_format, f_ch, f_bits;
    reg [31:0] f_rate;

    wire [31:0] cksz_v = {i_byte, cksz[31:8]};   // ph==7 拍：含本拍字节的完整 ckSize

    wire fmt_legal = seen_fmt
                  && (f_format == 16'd1)
                  && (f_ch     == 16'd1)
                  && (f_rate   == 32'd24000)
                  && (f_bits   == 16'd8);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_RIFF;
            ph           <= 5'd0;
            cksz         <= 32'd0;
            dcnt         <= 32'd0;
            skipcnt      <= 32'd0;
            id_reg       <= 32'd0;
            seen_fmt     <= 1'b0;
            f_format     <= 16'd0;
            f_ch         <= 16'd0;
            f_rate       <= 32'd0;
            f_bits       <= 16'd0;
            o_smp        <= 8'd0;
            o_sval       <= 1'b0;
            o_hdr_ok     <= 1'b0;
            o_fmt_err    <= 1'b0;
            o_data_bytes <= 32'd0;
        end
        else if (i_restart) begin
            // 新文件：清解析状态（o_hdr_ok/o_fmt_err 一并清，供本文件重新判定）
            state        <= S_RIFF;
            ph           <= 5'd0;
            cksz         <= 32'd0;
            dcnt         <= 32'd0;
            skipcnt      <= 32'd0;
            id_reg       <= 32'd0;
            seen_fmt     <= 1'b0;
            o_sval       <= 1'b0;
            o_hdr_ok     <= 1'b0;
            o_fmt_err    <= 1'b0;
            o_data_bytes <= 32'd0;
        end
        else begin
            o_sval <= 1'b0;

            if (i_bval) begin
                case (state)

                    // ---- RIFF/WAVE 头（12 字节；4..7 = RIFF size 忽略）----
                    S_RIFF: begin
                        if ((ph == 5'd0 && i_byte != 8'h52) ||   // 'R'
                            (ph == 5'd1 && i_byte != 8'h49) ||   // 'I'
                            (ph == 5'd2 && i_byte != 8'h46) ||   // 'F'
                            (ph == 5'd3 && i_byte != 8'h46) ||   // 'F'
                            (ph == 5'd8 && i_byte != 8'h57) ||   // 'W'
                            (ph == 5'd9 && i_byte != 8'h41) ||   // 'A'
                            (ph == 5'd10 && i_byte != 8'h56) ||  // 'V'
                            (ph == 5'd11 && i_byte != 8'h45)) begin // 'E'
                            o_fmt_err <= 1'b1;
                            state     <= S_REST;
                            ph        <= 5'd0;
                        end
                        else if (ph == 5'd11) begin
                            ph    <= 5'd0;
                            state <= S_CKHDR;
                        end
                        else begin
                            ph <= ph + 5'd1;
                        end
                    end

                    // ---- chunk 头（8 字节）；ph==7 拍用 cksz_v 组合分发，不丢字节 ----
                    S_CKHDR: begin
                        if (ph < 5'd4) begin
                            id_reg[8*ph +: 8] <= i_byte;
                            ph <= ph + 5'd1;
                        end
                        else begin
                            cksz <= cksz_v;
                            if (ph == 5'd7) begin
                                ph <= 5'd0;
                                if (id_reg == 32'h20746D66) begin           // "fmt "
                                    state <= S_FMT;
                                end
                                else if (id_reg == 32'h61746164) begin      // "data"
                                    if (fmt_legal) begin
                                        o_hdr_ok     <= 1'b1;
                                        o_data_bytes <= cksz_v;
                                        dcnt         <= 32'd0;
                                        state        <= (cksz_v == 32'd0)
                                                        ? S_CKHDR : S_DATA;
                                    end
                                    else begin
                                        o_fmt_err <= 1'b1;
                                        state     <= S_REST;
                                    end
                                end
                                else begin                                  // 未知 chunk
                                    if (cksz_v == 32'd0) begin
                                        state <= S_CKHDR;                   // 空 chunk
                                    end
                                    else begin
                                        skipcnt <= cksz_v;
                                        state   <= S_SKIP;
                                    end
                                end
                            end
                            else begin
                                ph <= ph + 5'd1;
                            end
                        end
                    end

                    // ---- fmt 块体：捕获 16 字节字段，多余跳过 ----
                    S_FMT: begin
                        if (cksz >= 32'd16) begin
                            case (ph)
                                5'd0:  f_format[7:0]  <= i_byte;
                                5'd1:  f_format[15:8] <= i_byte;
                                5'd2:  f_ch[7:0]      <= i_byte;
                                5'd3:  f_ch[15:8]     <= i_byte;
                                5'd4:  f_rate[7:0]    <= i_byte;
                                5'd5:  f_rate[15:8]   <= i_byte;
                                5'd6:  f_rate[23:16]  <= i_byte;
                                5'd7:  f_rate[31:24]  <= i_byte;
                                // 8..11 = byteRate，忽略；12..13 = blockAlign，忽略
                                5'd14: f_bits[7:0]    <= i_byte;
                                5'd15: f_bits[15:8]   <= i_byte;
                                default: ;
                            endcase
                            if (ph == 5'd15) begin
                                seen_fmt <= 1'b1;
                                ph       <= 5'd0;
                                if (cksz == 32'd16) begin
                                    state <= S_CKHDR;
                                end
                                else begin
                                    skipcnt <= cksz - 32'd16;   // cbSize 等扩展字段
                                    state   <= S_SKIP;
                                end
                            end
                            else begin
                                ph <= ph + 5'd1;
                            end
                        end
                        else begin
                            // fmt 体不足 16 字节：畸形，拒绝（已捕字段作废）
                            o_fmt_err <= 1'b1;
                            state     <= S_REST;
                            ph        <= 5'd0;
                        end
                    end

                    // ---- 跳过未知 chunk（skipcnt = 剩余待吞字节）----
                    S_SKIP: begin
                        if (skipcnt <= 32'd1) begin
                            state <= S_CKHDR;    // 本拍吞掉最后一个字节
                        end
                        skipcnt <= skipcnt - 32'd1;
                    end

                    // ---- data 块：字节流 = 无符号 8bit 样本 ----
                    S_DATA: begin
                        o_smp  <= i_byte;
                        o_sval <= 1'b1;
                        if (dcnt + 32'd1 >= cksz) begin
                            state <= S_REST;     // 声明长度流完（正常应接近文件尾）
                        end
                        dcnt <= dcnt + 32'd1;
                    end

                    // ---- 吞流/收尾（S_REST）：静默直到 i_restart ----
                    default: ;
                endcase
            end
        end
    end

endmodule
