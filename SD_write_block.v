// SD_Write_Block.v
// 写入单个 512 字节扇区（CMD24）

module SD_Write_Block (
    input            clk,        // 系统时钟 50MHz
    input            rst_n,      // 低电平复位
    input            init_done,  // 来自 SD_Initial 的初始化完成信号
    input            MISO,       // SD 卡数据输入
    output           CS,         // 片选（低有效）
    output           MOSI,       // 主机输出
    output           spi_clk,    // 生成的写入时钟
    input [31:0]     write_addr, // 写入地址（LBA 地址，单位为 block - 扇区）
    input [7:0]      data_in,    // 写入数据（需要外部提供512字节数据）
    input            data_valid, // 数据有效信号（高电平表示 data_in 有效）
    output reg       write_done, // 一次写操作完成
    output reg       busy        // 模块忙碌信号
);

// ============================================
// 基于50MHz时钟生成25MHz写入时钟（与读取模块相同）
localparam WRITE_CLK_DIV = 4; // 50MHz / 4 = 12.5MHz
reg [2:0] write_spi_counter = 0;  
reg spi_clk_reg = 0;
reg spi_clk_prev = 0;

// 边沿检测
wire spi_clk_posedge;
wire spi_clk_negedge;

assign spi_clk = spi_clk_reg;

// 写入时钟生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        write_spi_counter <= 0;
        spi_clk_reg <= 0;
        spi_clk_prev <= 0;
    end else begin
        // 保存上一个时钟周期的SPI时钟状态
        spi_clk_prev <= spi_clk_reg;
        
        if (write_spi_counter >= (WRITE_CLK_DIV - 1)) begin
            write_spi_counter <= 0;
            spi_clk_reg <= ~spi_clk_reg; // 翻转SPI时钟
        end else begin
            write_spi_counter <= write_spi_counter + 1'b1; // 更新计数器
        end 
    end
end

// 边沿检测（因为主时钟是系统时钟,该边沿检测做到主时钟到来时模块内代码只触发一次）
assign spi_clk_posedge = (spi_clk_prev == 1'b0) && (spi_clk_reg == 1'b1);
assign spi_clk_negedge = (spi_clk_prev == 1'b1) && (spi_clk_reg == 1'b0);
// ===========================================

// CMD24: 写入 LBA = 0（对 SDHC/SDXC，地址单位是 block，不是 byte）
// 命令格式：CMD24 (0x58) + 32-bit address + 7-bit CRC (通常可设为 0xFF，SD 卡忽略)
// 实际 CRC 可计算得出 0xFF，SPI 模式下也可接受 0xFF
reg [47:0] cmd24;

// 状态机
localparam IDLE          = 4'd0;
localparam WAIT_INIT     = 4'd1;
localparam SEND_CMD24    = 4'd2;
localparam WAIT_RESP     = 4'd3;
localparam READ_RESP     = 4'd4;
localparam SEND_TOKEN    = 4'd5;
localparam WRITE_DATA    = 4'd6;
localparam WAIT_DATA_RESP= 4'd7;
localparam READ_DATA_RESP= 4'd8;
localparam WAIT_BUSY     = 4'd9;
localparam DONE          = 4'd10;

reg [3:0] state = IDLE;
reg [8:0] bit_cnt = 0;       // 最大512字节需要9位计数器
reg [7:0] resp = 0;
reg [8:0] byte_cnt = 0;      // 0~511 字节
reg [7:0] wait_busy_cnt = 0; // 等待忙信号计数器

// 控制信号
reg cs_reg = 1;
reg mosi_reg = 1;

// 输出寄存器               
assign CS = cs_reg;
assign MOSI = mosi_reg;

// 数据缓冲
reg [7:0] data_buffer = 0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        bit_cnt <= 0;
        byte_cnt <= 0;
        cs_reg <= 1;
        mosi_reg <= 1;
        resp <= 0;
        write_done <= 0;
        busy <= 0;
        cmd24 <= 0;
        data_buffer <= 0;
        wait_busy_cnt <= 0;
    end else begin
        case (state)
            IDLE: begin
                write_done <= 0;
                busy <= 0;
                cmd24 <= {8'h58, write_addr, 8'hFF}; // 构造CMD24命令
                if (init_done) begin
                    busy <= 1;
                    state <= WAIT_INIT;
                end
            end

            WAIT_INIT: begin
                // 发送 8 个 dummy clocks（可选，确保稳定）
                if (spi_clk_negedge) begin
                    if (bit_cnt < 8) begin
                        bit_cnt <= bit_cnt + 1'b1;
                        mosi_reg <= 1;
                    end else begin
                        bit_cnt <= 0;
                        cs_reg <= 0; // 拉低 CS
                        state <= SEND_CMD24;
                    end
                end
            end

            SEND_CMD24: begin
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd24[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP;
                    end
                end
            end

            WAIT_RESP: begin
                mosi_reg <= 1;
                
                // 发送 dummy clocks，等待响应（最多 8 字节）
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= READ_RESP;
                    end
                end
            end

            READ_RESP: begin
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 8) begin
                        // 检查是否为 0x00（就绪）
                        if (resp == 8'h00) begin
                            bit_cnt <= 0;
                            byte_cnt <= 0;
                            state <= SEND_TOKEN;
                        end else begin
                            // 错误或超时
                            state <= DONE;
                        end
                    end
                end
            end

            SEND_TOKEN: begin
                // 发送起始令牌 0xFE
                if (spi_clk_negedge) begin
                    if (bit_cnt < 8) begin
                        mosi_reg <= (bit_cnt == 0) ? 1'b0 : 1'b1; // 0xFE = 8'b11111110
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WRITE_DATA;
                        data_buffer <= data_in; // 缓冲第一个数据
                    end
                end
            end

            WRITE_DATA: begin
                // 写入512字节数据
                if (spi_clk_negedge) begin
                    if (bit_cnt < 8) begin
                        mosi_reg <= data_buffer[7 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        byte_cnt <= byte_cnt + 1'b1;
                        
                        // 检查是否还有有效数据
                        if (byte_cnt < 9'd511) begin
                            // 需要更多数据
                            if (data_valid) begin
                                data_buffer <= data_in;
                            end else begin
                                // 数据不足，填充0xFF
                                data_buffer <= 8'hFF;
                            end
                        end else begin
                            // 512字节已发送完毕
                            state <= WAIT_DATA_RESP;
                        end
                    end
                end
            end

            WAIT_DATA_RESP: begin
                // 等待SD卡处理数据并返回响应
                mosi_reg <= 1; // 发送高电平
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 8) begin
                        bit_cnt <= 0;
                        state <= READ_DATA_RESP;
                    end
                end
            end

            READ_DATA_RESP: begin
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 8) begin
                        // 检查数据响应令牌 (期望得到 0x05 表示接收成功)
                        if ((resp & 8'h1F) == 5'h05) begin
                            bit_cnt <= 0;
                            wait_busy_cnt <= 0;
                            state <= WAIT_BUSY;
                        end else begin
                            // 写入失败
                            state <= DONE;
                        end
                    end
                end
            end

            WAIT_BUSY: begin
                // 等待SD卡完成内部写入操作（MISO为低电平表示忙碌）
                mosi_reg <= 1;
                if (spi_clk_posedge) begin
                    if (MISO == 1'b0) begin
                        // SD卡仍然忙碌
                        wait_busy_cnt <= wait_busy_cnt + 1'b1;
                        // 设置一个超时时间防止无限等待
                        if (wait_busy_cnt >= 8'hFF) begin
                            state <= DONE;
                        end
                    end else begin
                        // SD卡已完成操作
                        state <= DONE;
                    end
                end
            end

            DONE: begin
                write_done <= 1;
                busy <= 0;
                cs_reg <= 1; // 拉高 CS，结束传输
                mosi_reg <= 1;
                // 可保持 done 状态，或回到 IDLE
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule