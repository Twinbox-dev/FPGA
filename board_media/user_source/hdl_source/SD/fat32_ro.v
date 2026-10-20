// vsrc/fat32_ro.v — FAT32 只读文件系统引擎（fat32_ro，W2）
//
// 上游：top 的轮播控制（给播放列表索引）；扇区数据来自 sd_spi
// 下游：bmp_dec + wav_reader（共享同一条文件字节流，各自靠文件头自识别）
// 板级：原样搬（纯协议解析，与载体无关）
// 全局视图见 docs/architecture.md
//
// 角色：sd_spi 的上层主机 + 文件字节流提供者。
// 规格（docs/design.md §5，2026-09-20 约定 v2）：
//   - 挂载双路径：LBA0 首字节 0xEB/0xE9 → superfloppy（本扇区即 BPB）；
//     否则 MBR：55AA + 第一分区项 type∈{0x0B,0x0C} → start_lba → 读 BPB
//   - 单分区、图片只在根目录；LFN/卷标/子目录/已删除项防御性跳过
//   - 播放列表：扩展名 BMP 的 32B 目录项 → {首簇, 大小}，容量 32
//   - 文件读：沿 FAT 簇链（项 ≥ 0x0FFFFFF8 为 EOC），字节流输出，
//     按目录项的 size 截止（末扇区可不满）
//
// 实现说明：
//   - 纯流式解析：所有多字节字段按扇区内字节相位捕获（小端右插），
//     目录项按 32B 相位解析（32 整除 512，项不跨扇区）——无 512B 缓冲
//   - v1 无 FAT 扇区缓存：每个簇边界重读一次 FAT 扇区（约 +6% 扇区读，
//     SPI 本身是瓶颈，无关痛痒）；缓存留作板级优化
//   - 扇区重试依赖 sd_spi 契约：o_err 路径保证此前无 o_dval（数据只会在
//     0xFE 令牌之后流动，而错误都发生在令牌之前），故重发无需回滚解析状态
module fat32_ro #(
    parameter FILE_FLOW_CONTROL = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 扇区读主机侧（接 sd_spi）----
    output reg  [31:0] o_lba,
    output reg         o_req,
    input  wire        i_ready,
    input  wire [7:0]  i_data,
    input  wire        i_dval,
    input  wire        i_done,
    input  wire        i_err,

    // ---- 文件字节流（接 bmp_dec）----
    output reg  [7:0]  o_byte,
    output reg         o_bval,
    output reg         o_file_done,  // 当前文件读完，一拍

    // ---- 控制 / 状态 ----
    input  wire [4:0]  i_file_idx,   // 播放列表索引
    input  wire        i_file_req,   // 请求读该文件（挂载后有效）
    // Optional production-stream controls. Disabled for all legacy users.
    input  wire        i_file_pause,       // stop before issuing the next data sector
    input  wire        i_header_only,      // latch on open: return at most the first 512 bytes
    input  wire        i_file_abort,       // hold until idle; finish an in-flight sector
    output reg         o_mounted,    // 挂载+扫描完成（电平）
    output reg  [5:0]  o_file_cnt,   // 播放列表文件数（图片+音频）
    output reg  [5:0]  o_bmp_cnt,    // 其中 BMP 数
    output reg  [5:0]  o_wav_cnt,    // 其中 WAV 数
    output reg  [5:0]  o_type_map,   // 低位优先的类型位图（1=WAV，0=BMP），仅前 6 项（遗留，未用）
    output reg  [5:0]  o_first_bmp,  // 首个 BMP 的播放列表索引（轮播起点）
    output reg  [191:0] o_bmp_nxt,   // BMP 轮播下一跳表：项 i（6bit × 32，i=file_idx）→ 循环序下一个 BMP 索引
                                     // 挂载扫目录时逐拍建立，替代 sd_card_bmp 里 33 级组合链的 next_bmp_idx
    output reg  [191:0] o_bmp_prv,   // BMP 循环上一跳表：项 i → 循环序上一个 BMP 索引（“上一张”）
                                     // 与 o_bmp_nxt 同拍建立；首项在扫描收口时回填为末项
    output reg         o_err,        // 挂载失败 / 索引越界，一拍
    output reg         o_cur_is_wav, // 当前/最近请求的文件是否为 WAV
    output wire        o_file_idle,  // 空闲（在 MOUNTED 态，可接受 file_req）
    output wire [7:0]  o_dbg_state,

    // ---- 播放列表查找口（供上层做同名配对，如 IMG001.BMP <-> IMG001.WAV）----
    input  wire [4:0]  i_pl_idx,     // 查找索引（0..pl_cnt-1 有效）
    output wire [63:0] o_pl_name,    // 该条目的 8 字节主名（字节 k 在 [8k+7:8k]）
    output wire        o_pl_is_wav,  // 该条目是否 WAV
    output wire        o_pl_valid    // i_pl_idx < pl_cnt
);

    // ---------------- 参数 ----------------
    localparam [1:0] RETRY_MAX = 2'd3;
    localparam [5:0] PL_MAX    = 6'd32;

    // ---------------- 状态 ----------------
    localparam [7:0]
        S_RST      = 8'd0,
        S_ISSUE    = 8'd1,   // 等 sd 就绪，发出 rd_lba 扇区读
        S_STREAM   = 8'd2,   // 扇区数据流：按 rd_kind 分派
        S_MOUNT    = 8'd3,   // LBA0 完成：判 superfloppy / MBR
        S_BPBDEC   = 8'd4,   // BPB 字段齐：sanity + 派生 + 发起目录读
        S_FATDEC   = 8'd5,   // FAT 项捕获齐：按 fat_purpose 分派
        S_DIRDONE  = 8'd6,   // 目录扇区完成：簇内推进 / 查 FAT / 扫描完成
        S_DATADONE = 8'd7,   // 数据扇区完成：簇内推进 / 查 FAT / 文件完成
        S_MOUNTED  = 8'd8,   // 挂载完成，等 file_req
        S_ERR      = 8'd9,   // 挂载失败，卡死
        S_OPEN     = 8'd10,  // 文件请求拍2：减2+按spc移位存 clu_lba（与查表分拍）
        S_LBA      = 8'd11,  // 簇→LBA 拍3：rd_lba = first_data + clu_lba（单加法）
        S_BPB2     = 8'd12;  // BPB 派生拍2：first_data / 首目录簇移位（乘法已独拍）

    // 扇区流种类
    localparam [2:0]
        K_LBA0 = 3'd0,
        K_BPB  = 3'd1,
        K_FAT  = 3'd2,
        K_DIR  = 3'd3,
        K_DATA = 3'd4;

    reg [7:0] state;
    assign o_dbg_state = state;
    assign o_file_idle = (state == S_MOUNTED);
    // 播放列表查找（组合读）
    assign o_pl_name   = pl_name[i_pl_idx];
    assign o_pl_is_wav = pl_is_wav[i_pl_idx];
    assign o_pl_valid  = ({1'b0, i_pl_idx} < pl_cnt);

    // spc 为 2 的幂（FAT 规格保证，BPB 处有一热校验）
    function [2:0] log2s;
        input [7:0] v;
        begin
            case (v)
                8'd1:    log2s = 3'd0;
                8'd2:    log2s = 3'd1;
                8'd4:    log2s = 3'd2;
                8'd8:    log2s = 3'd3;
                8'd16:   log2s = 3'd4;
                8'd32:   log2s = 3'd5;
                8'd64:   log2s = 3'd6;
                8'd128:  log2s = 3'd7;
                default: log2s = 3'd0;
            endcase
        end
    endfunction

    // ---------------- 扇区读通道 ----------------
    reg  [2:0]  rd_kind;
    reg  [31:0] rd_lba;
    reg  [8:0]  sec_bc;          // 扇区内字节序号 0..511
    reg  [1:0]  retry;

    // ---------------- 挂载捕获（小端右插）----------------
    reg        is_mbr;
    reg [15:0] bps_le;
    reg [7:0]  spc, nfats;
    reg [15:0] rsvd_le;
    reg [31:0] fatsz_le, rootclus_le, start_lba_le;
    reg        sig55, sigAA;
    reg [7:0]  mbr_type;

    // ---------------- 派生 ----------------
    // 时序：簇号→LBA = 减2、按 spc 变量移位、加 first_data，曾合一拍被 STA 报
    // -1.78ns（spc→桶形移位→加法链→rd_lba，109 端点，上板 mount 永远完不成）。
    // 拆流水：拍1 算 (簇-2)<<spc_log2 存 clu_lba，拍2（S_LBA）单加法出 rd_lba。
    reg [31:0] part_lba, fat_start, first_data;
    reg [31:0] fat_mul, part_rsvd;     // BPB 派生中间值（乘法/第一级加法各自独拍）
    reg [31:0] clu_lba;                // (簇-2)<<spc_log2 流水寄存器
    wire [2:0] spc_log2 = log2s(spc);

    // ---------------- FAT 查询 ----------------
    reg [8:0]  fat_off;          // 项在 FAT 扇区内的字节偏移
    reg [31:0] fat_val;          // 捕获到的 FAT 项
    reg        fat_purpose;      // 0=目录链 1=文件链

    // ---------------- 目录扫描 ----------------
    reg [31:0] dir_cluster;
    reg [7:0]  dir_sec;          // 簇内扇区号 0..spc-1
    reg [4:0]  entry_ph;         // 32B 项内字节相位 0..31
    reg        dir_end;          // 见到 0x00 项，扫描提前结束
    reg        ent_skip;         // 当前项跳过（E5 / LFN / 卷标 / 子目录）
    reg [63:0] name_reg;         // 8 字节主名捕获（字节 k 在 [8k+7:8k]）
    reg [7:0]  ext1, ext2, ext3;
    reg [15:0] clus_hi, clus_lo;
    reg [23:0] fsize_le;              // 大小前 3 字节（第 4 字节直通）

    // ---------------- 播放列表 ----------------
    // 类型：0=BMP 1=WAV（扩展名匹配，见目录扫描）
    (* ram_style = "bram_32k" *) reg [31:0] pl_cluster [0:31];
    reg [31:0] pl_cluster_q;
    reg [31:0] pl_size    [0:31];
    reg        pl_is_wav  [0:31];
    reg [63:0] pl_name    [0:31];   // 8 字节主名（字节 k 在 [8k+7:8k]），供同名配对
    reg [5:0]  pl_cnt;
    reg [5:0]  last_bmp;        // 建 BMP 下一跳表：上一个 BMP 索引
    reg        bmp_seen;        // 已见首个 BMP

    // ---------------- 文件读 ----------------
    reg [31:0] file_cluster;
    reg [7:0]  file_sec;
    reg [31:0] file_bytes;       // 已输出字节数
    reg [31:0] cur_size;

    // 扩展名匹配：ext1..3 为目录项的 8.3 扩展名三字节
    wire ext_is_bmp = (ext1 == 8'h42) && (ext2 == 8'h4D) && (ext3 == 8'h50);  // "BMP"
    wire ext_is_wav = (ext1 == 8'h57) && (ext2 == 8'h41) && (ext3 == 8'h56);  // "WAV"
    wire ext_hit    = ext_is_bmp || ext_is_wav;

    // Registered playlist cluster lookup: the existing S_OPEN cycle uses
    // this value, so the external file-request timing remains unchanged.
    wire pl_cluster_store = rst_n && state == S_STREAM && i_dval &&
                            rd_kind == K_DIR && !dir_end &&
                            entry_ph == 5'd31 && !ent_skip && ext_hit &&
                            pl_cnt < PL_MAX;
    always @(posedge clk) begin
        if (pl_cluster_store)
            pl_cluster[pl_cnt[4:0]] <= {clus_hi, clus_lo};
        pl_cluster_q <= pl_cluster[i_file_idx];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_RST;
            o_lba <= 32'd0;
            o_req <= 1'b0;
            o_byte <= 8'h00;
            o_bval <= 1'b0;
            o_file_done <= 1'b0;
            o_mounted <= 1'b0;
            o_file_cnt <= 6'd0;
            o_bmp_cnt <= 6'd0;
            o_wav_cnt <= 6'd0;
            o_type_map <= 6'd0;
            o_first_bmp <= 6'd0;
            o_bmp_nxt <= 192'd0;
            o_bmp_prv <= 192'd0;
            o_cur_is_wav <= 1'b0;
            o_err <= 1'b0;
            rd_kind <= K_LBA0;
            rd_lba  <= 32'd0;
            clu_lba <= 32'd0;
            sec_bc <= 9'd0;
            retry <= 2'd0;
            is_mbr <= 1'b0;
            bps_le <= 16'd0;
            spc <= 8'd0;
            nfats <= 8'd0;
            rsvd_le <= 16'd0;
            fatsz_le <= 32'd0;
            rootclus_le <= 32'd0;
            start_lba_le <= 32'd0;
            sig55 <= 1'b0;
            sigAA <= 1'b0;
            mbr_type <= 8'd0;
            part_lba <= 32'd0;
            fat_start <= 32'd0;
            first_data <= 32'd0;
            fat_off <= 9'd0;
            fat_val <= 32'd0;
            fat_purpose <= 1'b0;
            dir_cluster <= 32'd0;
            dir_sec <= 8'd0;
            entry_ph <= 5'd0;
            dir_end <= 1'b0;
            ent_skip <= 1'b0;
            name_reg <= 64'd0;
            ext1 <= 8'd0;
            ext2 <= 8'd0;
            ext3 <= 8'd0;
            clus_hi <= 16'd0;
            clus_lo <= 16'd0;
            fsize_le <= 24'd0;
            pl_cnt <= 6'd0;
            file_cluster <= 32'd0;
            file_sec <= 8'd0;
            file_bytes <= 32'd0;
            cur_size <= 32'd0;
            last_bmp <= 6'd0;
            bmp_seen <= 1'b0;
            o_first_bmp <= 6'd0;
        end
        else begin
            // 默认：脉冲清零
            o_req       <= 1'b0;
            o_bval      <= 1'b0;
            o_file_done <= 1'b0;
            o_err       <= 1'b0;

            case (state)

                // ===== 复位释放：发起 LBA0 读 =====
                S_RST: begin
                    rd_kind <= K_LBA0;
                    rd_lba  <= 32'd0;
                    state   <= S_ISSUE;
                end

                // ===== 等 sd 就绪并发出扇区读 =====
                S_ISSUE: begin
                    if (FILE_FLOW_CONTROL && rd_kind == K_DATA && i_file_abort) begin
                        o_file_done <= 1'b1;
                        state <= S_MOUNTED;
                    end else if (i_ready && !(FILE_FLOW_CONTROL && rd_kind == K_DATA && i_file_pause)) begin
                        o_req   <= 1'b1;
                        o_lba   <= rd_lba;
                        sec_bc  <= 9'd0;
                        state   <= S_STREAM;
                    end
                end

                // ===== 扇区数据流 =====
                S_STREAM: begin
                    if (i_dval) begin
                        case (rd_kind)

                            // ---- LBA0：判别字节 + MBR 字段 + BPB 字段（两用）----
                            K_LBA0: begin
                                case (sec_bc)
                                    9'd0:    is_mbr <= !(i_data == 8'hEB || i_data == 8'hE9);
                                    9'd11:   bps_le  <= {i_data, bps_le[15:8]};
                                    9'd12:   bps_le  <= {i_data, bps_le[15:8]};
                                    9'd13:   spc     <= i_data;
                                    9'd14:   rsvd_le <= {i_data, rsvd_le[15:8]};
                                    9'd15:   rsvd_le <= {i_data, rsvd_le[15:8]};
                                    9'd16:   nfats   <= i_data;
                                    9'd36:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd37:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd38:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd39:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd44:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd45:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd46:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd47:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd450:  mbr_type     <= i_data;             // 0x1C2
                                    9'd454:  start_lba_le <= {i_data, start_lba_le[31:8]};
                                    9'd455:  start_lba_le <= {i_data, start_lba_le[31:8]};
                                    9'd456:  start_lba_le <= {i_data, start_lba_le[31:8]};
                                    9'd457:  start_lba_le <= {i_data, start_lba_le[31:8]};
                                    9'd510:  sig55 <= (i_data == 8'h55);
                                    9'd511:  sigAA <= (i_data == 8'hAA);
                                    default: ;
                                endcase
                            end

                            // ---- BPB 扇区（MBR 路径）----
                            K_BPB: begin
                                case (sec_bc)
                                    9'd11:   bps_le  <= {i_data, bps_le[15:8]};
                                    9'd12:   bps_le  <= {i_data, bps_le[15:8]};
                                    9'd13:   spc     <= i_data;
                                    9'd14:   rsvd_le <= {i_data, rsvd_le[15:8]};
                                    9'd15:   rsvd_le <= {i_data, rsvd_le[15:8]};
                                    9'd16:   nfats   <= i_data;
                                    9'd36:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd37:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd38:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd39:   fatsz_le    <= {i_data, fatsz_le[31:8]};
                                    9'd44:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd45:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd46:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    9'd47:   rootclus_le <= {i_data, rootclus_le[31:8]};
                                    default: ;
                                endcase
                            end

                            // ---- FAT 扇区：捕获 fat_off 处的 4 字节项 ----
                            K_FAT: begin
                                if (sec_bc >= fat_off && sec_bc <= fat_off + 9'd3) begin
                                    fat_val <= {i_data, fat_val[31:8]};
                                end
                            end

                            // ---- 目录扇区：32B 项流式解析 ----
                            K_DIR: if (!dir_end) begin
                                // 捕获 8 字节主名（字节 k 落位 [8k+7:8k]）
                                if (entry_ph < 5'd8) begin
                                    name_reg[8*entry_ph +: 8] <= i_data;
                                end
                                case (entry_ph)
                                    5'd0: begin
                                        if (i_data == 8'h00) begin
                                            dir_end <= 1'b1;
                                        end
                                        else begin
                                            ent_skip <= (i_data == 8'hE5);
                                        end
                                    end
                                    5'd8:  ext1 <= i_data;
                                    5'd9:  ext2 <= i_data;
                                    5'd10: ext3 <= i_data;
                                    5'd11: begin
                                        // bit3: LFN(0x0F)/卷标(0x08)，bit4: 子目录(0x10)
                                        if (i_data[3] || i_data[4]) begin
                                            ent_skip <= 1'b1;
                                        end
                                    end
                                    5'd20: clus_hi <= {i_data, clus_hi[15:8]};
                                    5'd21: clus_hi <= {i_data, clus_hi[15:8]};
                                    5'd26: clus_lo <= {i_data, clus_lo[15:8]};
                                    5'd27: clus_lo <= {i_data, clus_lo[15:8]};
                                    5'd28: fsize_le <= {i_data, fsize_le[23:8]};
                                    5'd29: fsize_le <= {i_data, fsize_le[23:8]};
                                    5'd30: fsize_le <= {i_data, fsize_le[23:8]};
                                    5'd31: begin
                                        // 项完成：大小第 4 字节直通，命中则入播放列表
                                        if (!ent_skip && !dir_end && ext_hit
                                            && pl_cnt < PL_MAX) begin
                                            pl_size[pl_cnt[4:0]]    <= {i_data, fsize_le};
                                            pl_is_wav[pl_cnt[4:0]]  <= ext_is_wav;
                                            pl_name[pl_cnt[4:0]]    <= name_reg;
                                            pl_cnt <= pl_cnt + 6'd1;
                                            if (ext_is_wav) begin
                                                o_wav_cnt <= o_wav_cnt + 6'd1;
                                                if (pl_cnt < 6'd6)
                                                    o_type_map[pl_cnt[2:0]] <= 1'b1;
                                            end
                                            else begin
                                                o_bmp_cnt <= o_bmp_cnt + 6'd1;
                                                // 建轮播跳表：本 BMP → 循环序上一跳（prv）与下一跳（nxt）
                                                // nxt：前一 BMP → 本 BMP；prv：本 BMP → 前一 BMP（首项扫描收口时回填末项）
                                                o_bmp_prv[6*pl_cnt[4:0] +: 6] <= last_bmp;
                                                if (bmp_seen)
                                                    o_bmp_nxt[6*last_bmp[4:0] +: 6] <= pl_cnt;
                                                else
                                                    o_first_bmp <= pl_cnt;
                                                last_bmp  <= pl_cnt;
                                                bmp_seen  <= 1'b1;
                                            end
                                        end
                                        ent_skip <= 1'b0;
                                    end
                                    default: ;
                                endcase
                                entry_ph <= (entry_ph == 5'd31) ? 5'd0 : (entry_ph + 5'd1);
                            end

                            // ---- 数据扇区：字节流直通（按 size 截止）----
                            K_DATA: begin
                                if (file_bytes < cur_size) begin
                                    o_byte      <= i_data;
                                    o_bval      <= 1'b1;
                                    file_bytes  <= file_bytes + 32'd1;
                                end
                            end

                            default: ;
                        endcase
                        sec_bc <= sec_bc + 9'd1;
                    end

                    // ---- 扇区完成 / 失败 ----
                    if (i_err) begin
                        // sd_spi 契约：err 路径此前无数据拍，直接重发即可
                        if (retry < RETRY_MAX) begin
                            retry <= retry + 2'd1;
                            state <= S_ISSUE;
                        end
                        else begin
                            o_err <= 1'b1;
                            state <= S_ERR;
                        end
                    end
                    else if (i_done) begin
                        retry  <= 2'd0;
                        case (rd_kind)
                            K_LBA0: state <= S_MOUNT;
                            K_BPB:  state <= S_BPBDEC;
                            K_FAT:  state <= S_FATDEC;
                            K_DIR:  state <= S_DIRDONE;
                            K_DATA: state <= S_DATADONE;
                            default: state <= S_ERR;
                        endcase
                    end
                end

                // ===== LBA0 完成：判路径 =====
                S_MOUNT: begin
                    if (!is_mbr) begin
                        // superfloppy：LBA0 即 BPB，字段已捕获，直接派生
                        part_lba <= 32'd0;
                        state    <= S_BPBDEC;
                    end
                    else begin
                        if (sig55 && sigAA
                            && (mbr_type == 8'h0B || mbr_type == 8'h0C)
                            && start_lba_le != 32'd0) begin
                            part_lba <= start_lba_le;
                            rd_kind  <= K_BPB;
                            rd_lba   <= start_lba_le;
                            state    <= S_ISSUE;
                        end
                        else begin
                            o_err <= 1'b1;
                            state <= S_ERR;
                        end
                    end
                end

                // ===== BPB 字段齐：sanity + 派生 + 发起首个目录扇区 =====
                S_BPBDEC: begin
                    if (bps_le != 16'd512 || nfats == 8'd0 || fatsz_le == 32'd0
                        || (spc == 8'd0) || ((spc & (spc - 8'd1)) != 8'd0)
                        || rootclus_le < 32'd2) begin
                        o_err <= 1'b1;
                        state <= S_ERR;
                    end
                    else begin
                        // 派生拆拍：乘法 nfats*fatsz 独占一拍（原与三级加法+簇移位
                        // 合一拍，STA 违例 → 挂载首目录扇区地址错，mount 卡死）
                        part_rsvd    <= part_lba + {16'd0, rsvd_le};
                        fat_mul      <= {24'd0, nfats} * fatsz_le;
                        state        <= S_BPB2;
                    end
                end

                // ===== BPB 派生拍2：first_data / 首目录簇移位 =====
                S_BPB2: begin
                    fat_start    <= part_rsvd;
                    first_data   <= part_rsvd + fat_mul;
                    dir_cluster  <= rootclus_le;
                    dir_sec      <= 8'd0;
                    entry_ph     <= 5'd0;
                    rd_kind      <= K_DIR;
                    clu_lba      <= (rootclus_le - 32'd2) << spc_log2;
                    state        <= S_LBA;
                end

                // ===== 簇→LBA 拍3：单加法出扇区地址（全 FSM 共用）=====
                S_LBA: begin
                    rd_lba  <= first_data + clu_lba;
                    state   <= S_ISSUE;
                end

                // ===== FAT 项捕获齐：按用途分派 =====
                S_FATDEC: begin
                    if (!fat_purpose) begin
                        // 目录链：EOC → 扫描完成
                        if (fat_val >= 32'h0FFFFFF8) begin
                            o_mounted  <= 1'b1;
                            o_file_cnt <= pl_cnt;
                            if (bmp_seen) begin
                                o_bmp_nxt[6*last_bmp[4:0] +: 6] <= o_first_bmp;
                                // 收口：首项上一跳 = 末项（与 nxt 成环对称）
                                o_bmp_prv[6*o_first_bmp[4:0] +: 6] <= last_bmp;
                            end
                            state      <= S_MOUNTED;
                        end
                        else begin
                            dir_cluster <= fat_val;
                            dir_sec     <= 8'd0;
                            rd_kind     <= K_DIR;
                            clu_lba     <= (fat_val - 32'd2) << spc_log2;
                            state       <= S_LBA;
                        end
                    end
                    else begin
                        // 文件链：EOC 或字节数满 → 文件完成
                        if (fat_val >= 32'h0FFFFFF8 || file_bytes >= cur_size ||
                            (FILE_FLOW_CONTROL && i_file_abort)) begin
                            o_file_done <= 1'b1;
                            state       <= S_MOUNTED;
                        end
                        else begin
                            file_cluster <= fat_val;
                            file_sec     <= 8'd0;
                            rd_kind      <= K_DATA;
                            clu_lba      <= (fat_val - 32'd2) << spc_log2;
                            state        <= S_LBA;
                        end
                    end
                end

                // ===== 目录扇区完成：簇内推进 / 查 FAT / 结束 =====
                S_DIRDONE: begin
                    if (dir_end) begin
                        // 提前收工（见到 0x00 项）
                        o_mounted  <= 1'b1;
                        o_file_cnt <= pl_cnt;
                        if (bmp_seen) begin
                            o_bmp_nxt[6*last_bmp[4:0] +: 6] <= o_first_bmp;
                            o_bmp_prv[6*o_first_bmp[4:0] +: 6] <= last_bmp;
                        end
                        state      <= S_MOUNTED;
                    end
                    else begin
                        dir_sec <= dir_sec + 8'd1;
                        if (dir_sec + 8'd1 == spc) begin
                            // 簇完：查 FAT 找下一目录簇
                            fat_off        <= {dir_cluster[6:0], 2'b00};
                            fat_purpose    <= 1'b0;
                            rd_kind        <= K_FAT;
                            rd_lba         <= fat_start + (dir_cluster >> 7);
                            state          <= S_ISSUE;
                        end
                        else begin
                            // 簇内推进：rd_lba 即刚读完扇区的 LBA，+1 即下一扇区，
                            // 免去簇基址重算（此点曾是 -1.78ns 长链终点）
                            rd_kind <= K_DIR;
                            rd_lba  <= rd_lba + 32'd1;
                            state   <= S_ISSUE;
                        end
                    end
                end

                // ===== 数据扇区完成：簇内推进 / 查 FAT / 文件完成 =====
                S_DATADONE: begin
                    if (file_bytes >= cur_size || (FILE_FLOW_CONTROL && i_file_abort)) begin
                        o_file_done <= 1'b1;
                        state       <= S_MOUNTED;
                    end
                    else begin
                        file_sec <= file_sec + 8'd1;
                        if (file_sec + 8'd1 == spc) begin
                            // 簇完：查 FAT 找下一数据簇
                            fat_off        <= {file_cluster[6:0], 2'b00};
                            fat_purpose    <= 1'b1;
                            rd_kind        <= K_FAT;
                            rd_lba         <= fat_start + (file_cluster >> 7);
                            state          <= S_ISSUE;
                        end
                        else begin
                            // 簇内推进：同 S_DIRDONE，rd_lba+1 即可
                            rd_kind <= K_DATA;
                            rd_lba  <= rd_lba + 32'd1;
                            state   <= S_ISSUE;
                        end
                    end
                end

                // ===== 挂载完成：等文件请求 =====
                // 三拍打开：拍1 查表（32×32 簇号 mux），拍2 减2+按 spc 移位
                // （S_OPEN），拍3 加 first_data（S_LBA）。合一拍时 i_file_idx→
                // rd_lba 是长链（STA 曾报 -3.6ns），扇区地址算错 = 读错簇 = 图花。
                S_MOUNTED: begin
                    if (i_file_req) begin
                        if ({1'b0, i_file_idx} >= pl_cnt) begin
                            o_err <= 1'b1;      // 索引越界：脉冲，留在 MOUNTED
                        end
                        else begin
                            cur_size     <= (FILE_FLOW_CONTROL && i_header_only && pl_size[i_file_idx] > 32'd512)
                                            ? 32'd512 : pl_size[i_file_idx];
                            o_cur_is_wav <= pl_is_wav[i_file_idx];
                            file_bytes   <= 32'd0;
                            file_sec     <= 8'd0;
                            rd_kind      <= K_DATA;
                            state        <= S_OPEN;
                        end
                    end
                end

                S_OPEN: begin
                    file_cluster <= pl_cluster_q;
                    clu_lba <= (pl_cluster_q - 32'd2) << spc_log2;
                    state   <= S_LBA;
                end

                default: ;   // S_ERR：终态
            endcase
        end
    end

endmodule
