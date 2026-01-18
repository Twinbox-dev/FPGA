module SD_Initial(
    input            MISO,      // SD卡数据输入
    input            clk,       // 系统时钟（50MHz）
    input            rst_n,     // 低电平复位
    output reg [5:0] led_o,     // 表示各个状态机是否正确完成（共阳极，0亮1灭）
    output           CS,        // 片选（低有效）
    output           MOSI,      // 主机输出
    output           spi_clk    // 低速 SPI 时钟
);

// ============================================
// 基于50MHz时钟生成100kHz SPI时钟
localparam SPI_CLK_DIV = 125; // 50MHz / 125 = 400kHz
reg [8:0] spi_counter = 0;  
reg spi_clk_reg = 0;
reg spi_clk_prev = 0;

// 边沿检测
wire spi_clk_posedge;
wire spi_clk_negedge;

assign spi_clk = spi_clk_reg;

// SPI 时钟生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        spi_counter <= 0;
        spi_clk_reg <= 0;
        spi_clk_prev <= 0;
    end else begin
        // 保存上一个时钟周期的SPI时钟状态
        spi_clk_prev <= spi_clk_reg;
        
        if (spi_counter >= (SPI_CLK_DIV - 1)) begin
            spi_counter <= 0;
            spi_clk_reg <= ~spi_clk_reg; // 翻转SPI时钟
        end else begin
            spi_counter <= spi_counter + 1'b1; // 更新计数器
        end 
    end
end

// 边沿检测（因为主时钟是系统时钟,该边沿检测做到主时钟到来时模块内代码只触发一次）
assign spi_clk_posedge = (spi_clk_prev == 1'b0) && (spi_clk_reg == 1'b1);
assign spi_clk_negedge = (spi_clk_prev == 1'b1) && (spi_clk_reg == 1'b0);
// ===========================================

// SPI 主机状态机
localparam IDLE          = 5'd0;
localparam INIT_CLK      = 5'd1;
localparam SEND_CMD0     = 5'd2;
localparam WAIT_RESP0    = 5'd3;
localparam READ_RESP0    = 5'd4;
localparam SEND_CMD8     = 5'd5;
localparam WAIT_RESP8    = 5'd6;
localparam READ_RESP8    = 5'd7;
localparam SEND_CMD55    = 5'd8;
localparam WAIT_RESP55   = 5'd9;
localparam READ_RESP55   = 5'd10;
localparam SEND_ACMD41   = 5'd11;
localparam WAIT_RESP41   = 5'd12;
localparam READ_RESP41   = 5'd13;
localparam SEND_CMD58    = 5'd14;
localparam WAIT_RESP58   = 5'd15;
localparam READ_RESP58   = 5'd16;
localparam DONE          = 5'd17;

reg [4:0] state = IDLE;
reg [7:0] bit_cnt = 0;
reg [7:0] resp = 0;
reg [31:0] resp32 = 0;
reg cs_reg = 1;
reg mosi_reg = 1;

// SD卡命令定义
reg [47:0] cmd0  = 48'h40_00_00_00_00_95;  // CMD0 + CRC
reg [47:0] cmd8  = 48'h48_00_00_01_AA_87;  // CMD8 + 电压检查 + 检查模式
reg [47:0] cmd55 = 48'h77_00_00_00_00_65;  // CMD55 + CRC  
reg [47:0] acmd41= 48'h69_40_00_00_00_77;  // ACMD41 + HCS位 + CRC
reg [47:0] cmd58 = 48'h7A_00_00_00_00_FD;  // CMD58 + CRC

// 状态寄存器
reg [6:0] init_attempts = 0;  // ACMD41初始化尝试次数

assign CS = cs_reg;
assign MOSI = mosi_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        led_o <= 6'b111111;  // 共阳极，初始全灭
        state <= IDLE;
        bit_cnt <= 0;
        resp <= 0;
        resp32 <= 0;
        cs_reg <= 1;
        mosi_reg <= 1;
        init_attempts <= 0;
    end else begin
        case (state)
            IDLE: begin
                cs_reg <= 1;
                mosi_reg <= 1;
                bit_cnt <= 0;
                state <= INIT_CLK;
            end
            
            INIT_CLK: begin
                // 发送至少74个时钟进行初始化（SD卡要求）
                if (spi_clk_negedge) begin
                    if (bit_cnt < 200) begin // 发送200个时钟确保初始化
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= SEND_CMD0;
                    end
                end
            end

            SEND_CMD0: begin
                cs_reg <= 0; // 拉低 CS
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd0[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP0;
                    end
                end
            end

            WAIT_RESP0: begin
                mosi_reg <= 1; // 发送dummy位
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        resp <= 0;
                        state <= READ_RESP0;
                    end
                end
            end

            READ_RESP0: begin
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 8) begin
                        if (resp == 8'h01) begin // 响应应为0x01
                            bit_cnt <= 0;
                            led_o[0] <= 0; // CMD0完成，点亮LED0
                            state <= SEND_CMD8;
                        end else begin
                            // 重试机制
                            if (init_attempts < 3) begin
                                init_attempts <= init_attempts + 1'b1;
                                state <= INIT_CLK;
                            end else begin
                                state <= DONE; // 失败
                            end
                        end
                    end
                end
            end

            SEND_CMD8: begin
                cs_reg <= 0;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd8[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP8;
                    end
                end
            end

            WAIT_RESP8: begin
                mosi_reg <= 1;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        resp <= 0;
                        state <= READ_RESP8;
                    end
                end
            end

            READ_RESP8: begin
                if (spi_clk_posedge) begin
                    if (bit_cnt < 8) begin
                        resp <= {resp[6:0], MISO};
                        bit_cnt <= bit_cnt + 1'b1;
                    end else if (bit_cnt < 40) begin // 读取32位响应数据
                        resp32 <= {resp32[30:0], MISO};
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                    
                    if (bit_cnt == 40) begin
                        $display("CMD8 Response - R1: %h, Data: %h", resp, resp32);
                        if (resp == 8'h01 && resp32[11:8] == 4'b0001 && resp32[7:0] == 8'hAA) begin
                            led_o[1] <= 0; // CMD8完成
                            bit_cnt <= 0;
                            state <= SEND_CMD55;
                        end else begin
                            state <= DONE; // 失败
                        end
                    end
                end
            end

            SEND_CMD55: begin
                cs_reg <= 0;
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd55[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP55;
                    end
                end
            end

            WAIT_RESP55: begin
                mosi_reg <= 1;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        resp <= 0;
                        state <= READ_RESP55;
                    end
                end
            end

            READ_RESP55: begin
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    
                    if (bit_cnt == 8) begin
                        if (resp == 8'h01) begin
                            bit_cnt <= 0;
                            state <= SEND_ACMD41;
                        end else begin
                            state <= DONE; // 失败
                        end
                    end
                end
            end

            SEND_ACMD41: begin
                cs_reg <= 0;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= acmd41[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP41;
                    end
                end
            end

            WAIT_RESP41: begin
                mosi_reg <= 1;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        resp <= 0;
                        state <= READ_RESP41;
                    end
                end
            end

            READ_RESP41: begin
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    
                    if (bit_cnt == 8) begin
                        if (resp == 8'h00) begin // 初始化完成
                            bit_cnt <= 0;
                            led_o[2] <= 0; // ACMD41完成
                            state <= SEND_CMD58;
                        end else if (resp == 8'h01 && init_attempts < 100) begin
                            // 卡忙，重试
                            init_attempts <= init_attempts + 1'b1;
                            bit_cnt <= 0;
                            state <= SEND_CMD55;
                        end else begin
                            state <= DONE; // 失败或超时
                        end
                    end
                end
            end

            SEND_CMD58: begin
                cs_reg <= 0;
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd58[47 - bit_cnt];
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        state <= WAIT_RESP58;
                    end
                end
            end

            WAIT_RESP58: begin
                mosi_reg <= 1;
                
                if (spi_clk_negedge) begin
                    if (bit_cnt < 7) begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end else begin
                        bit_cnt <= 0;
                        resp <= 0;
                        resp32 <= 0;
                        state <= READ_RESP58;
                    end
                end
            end

            READ_RESP58: begin
                if (spi_clk_posedge) begin
                    if (bit_cnt < 8) begin              // 读取8位"是否正确执行命令以及卡状态"响应
                        resp <= {resp[6:0], MISO};
                        bit_cnt <= bit_cnt + 1'b1;
                    end else if (bit_cnt < 40) begin    // 读取32位响应数据
                        resp32 <= {resp32[30:0], MISO};
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                    
                    if (bit_cnt == 40) begin
                        if (resp == 8'h00) begin
                            led_o[3] <= 0; // CMD58完成
                            // 检查CCS位（bit30）判断卡类型
                            if (resp32[30] == 1'b1) begin
                                led_o[4] <= 0; // SDHC/SDXC卡
                            end else begin
                                led_o[5] <= 0; // SDSC卡
                            end
                        end
                        state <= DONE;
                    end
                end
            end

            DONE: begin
                // 保持最终状态
                cs_reg <= 1;
                mosi_reg <= 1;
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule