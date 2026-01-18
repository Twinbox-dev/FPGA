// SD_Read_Block.v
// 读取单个 512 字节扇区（CMD17）

module SD_Read_Block (
    input            clk,        // 系统时钟 50MHz
    input            rst_n,      // 低电平复位
    input            init_done,  // 来自 SD_Initial 的初始化完成信号（如 led_o[3] == 0）
    input            MISO,       // SD 卡数据输入
    output           CS,         // 片选（低有效）
    output           MOSI,       // 主机输出
    output           spi_clk,    // 生成的读取时钟
    input [31:0]   read_addr,   // 读取地址（LBA 地址，单位为 block - 扇区）

    // 读出的数据（可连接到 RAM/FIFO/UART 等）
    output reg [7:0] data_out,
    output reg       data_valid, // 高电平表示 data_out 有效（持续 512 个周期）
    output reg       read_done   // 一次读操作完成
);

// ============================================
// 基于50MHz时钟生成25MHz读取时钟
localparam READ_CLK_DIV = 4; // 50MHz / 4 = 12.5MHz
reg [2:0] read_spi_counter = 0;  
reg spi_clk_reg = 0;
reg spi_clk_prev = 0;

// 边沿检测
wire spi_clk_posedge;
wire spi_clk_negedge;

assign spi_clk = spi_clk_reg;

// 读取时钟生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        read_spi_counter <= 0;
        spi_clk_reg <= 0;
        spi_clk_prev <= 0;
    end else begin
        // 保存上一个时钟周期的SPI时钟状态
        spi_clk_prev <= spi_clk_reg;
        
        if (read_spi_counter >= (READ_CLK_DIV - 1)) begin
            read_spi_counter <= 0;
            spi_clk_reg <= ~spi_clk_reg; // 翻转SPI时钟
        end else begin
            read_spi_counter <= read_spi_counter + 1'b1; // 更新计数器
        end 
    end
end

// 边沿检测（因为主时钟是系统时钟,该边沿检测做到主时钟到来时模块内代码只触发一次）
assign spi_clk_posedge = (spi_clk_prev == 1'b0) && (spi_clk_reg == 1'b1);
assign spi_clk_negedge = (spi_clk_prev == 1'b1) && (spi_clk_reg == 1'b0);
// ===========================================

// CMD17: 读取 LBA = 0（对 SDHC/SDXC，地址单位是 block，不是 byte）
// 命令格式：CMD17 (0x51) + 32-bit address + 7-bit CRC (通常可设为 0xFF，SD 卡忽略)
// 实际 CRC 可计算得出95，但 SPI 模式下也可接受 0xFF
reg [47:0] cmd17 = {8'h51,32'h00_00_61_00,8'h95}; // 48'h51_00_00_00_00_95;

// 状态机
localparam IDLE        = 4'd0;
localparam WAIT_INIT   = 4'd1;
localparam SEND_CMD17  = 4'd2;
localparam WAIT_RESP   = 4'd3;
localparam READ_RESP   = 4'd4;
localparam WAIT_TOKEN  = 4'd5;
localparam READ_DATA   = 4'd6;
localparam READ_CRC    = 4'd7;
localparam DONE        = 4'd8;

reg [3:0] state = IDLE;
reg [7:0] bit_cnt = 0;
reg [7:0] resp = 0;
reg [9:0] byte_cnt = 0; // 0~511 字节 + 2 字节 CRC
reg [7:0] init_attempts = 0;    // 2^(7+1) - 1 = 255 次 -- 即255字节WAIT_TOKEN等待

// 控制信号
reg cs_reg = 1;
reg mosi_reg = 1;

// 输出寄存器               
assign CS = cs_reg;
assign MOSI = mosi_reg;
reg [15:0] CRC = 16'h0000;


always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        bit_cnt <= 0;
        byte_cnt <= 0;
        cs_reg <= 1;
        mosi_reg <= 1;
        resp <= 0;
        read_done <= 0;
        init_attempts <= 0;
    end else begin
        case (state)
            IDLE: begin
                read_done <= 0;
                if (init_done) begin
                    state <= WAIT_INIT;
                    // 等待一小段时间再拉低 CS（可选）
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
                        state <= SEND_CMD17;
                    end
                end
            end

            SEND_CMD17: begin
                if (spi_clk_negedge) begin
                    if (bit_cnt < 48) begin
                        mosi_reg <= cmd17[47 - bit_cnt];
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
                    mosi_reg <= 1;
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
                        // 检查是否为 0x00（就绪）或 0x01（忙）等 | 且R1[7]=0 表示响应有效
                        if (resp == 8'h00) begin
                            bit_cnt <= 0;
                            resp <= {resp[6:0], MISO};
                            state <= WAIT_TOKEN;
                        end else begin
                            // 超时或错误
                            state <= DONE;
                        end
                    end
                end
            end

//>==============================================================================
            WAIT_TOKEN: begin
                // 等待 0xFE（数据令牌）
                if (spi_clk_posedge) begin
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 7) begin
                        if (resp == 8'hFE || resp == 8'hFC) begin
                            /*
                            resp <= 8'h00; 
                    证实猜想:非阻塞性赋值应该整个块代码一起阅读。并且在时钟上升沿到来瞬间,所有变量的值都会固定住 -- 变量的值和比较操作用到的值都是这个上升沿触发后的10ns脉冲中记录的
                            (是旧值,也就是上一个时钟中保留的值 -- 上升沿/下降沿都是一个10ns的脉冲,在这10ns内会完成整个块内代码的执行),变量的值将在1ns脉冲过后更新;
                            所有变量的更新,只有当该上升沿将要结束时才会更新为新值。即非阻塞赋值满足以下核心规则:
                            1.同时读取:在时钟上升沿到来瞬间(10ns),所有变量用的是同一个值(旧值) 
                            - 例如上面代码中的bit_cnt,上升沿到来时,当前块内所有bit_cnt都是7。
                            2.延迟写入:在时钟上升沿结束时(即10ns后),所有变量才会更新为新值 
                            - 例如上面代码中的bit_cnt,在当前块内所有bit_cnt都是7,但bit_cnt <= bit_cnt + 1'b1 会变成8,不过不会立即写入。而是会在上升沿结束的时候才记录为8。
                            3.覆盖规则:如果在同一个时钟周期内,对同一个变量进行了多次非阻塞赋值,那么最终该变量会被更新为最后一次赋值的结果。 
                            - 所以注释块中加入了resp <= 8'h00,这会将resp的值重置为0,否则将会是8'hFC -- 这是延迟写入和覆盖规则的共同效果导致的。
                    查看波形:我们在看波形图的时候,应该将波形放大到最大。这样便能清晰地看到，变量是在时钟
                            上升沿/下降沿到来的[10ns脉冲中]保持不变的(这个值将用于比较等操作),而在[10ns脉冲结束后]才会更新为新值。
                    最终结论:变量的值和比较操作所使用的值都是这个10ns脉冲中记录的。
                            我们平时所说的上升沿/下降沿结束 都指的是10ns脉冲结束的时刻 -- 即时钟上升沿/下降沿到来的1ns后。
                            */
                            bit_cnt <= 0;
                            byte_cnt <= 0;
                            state <= READ_DATA;
                        end else begin
                            bit_cnt <= 0;
                            resp <= {resp[6:0], MISO};  // 有无并没有影响
                            init_attempts <= init_attempts + 1'b1; // 继续等待
                            if (init_attempts == 255) begin
                                // 超时直接退出
                                state <= DONE;
                            end
                        end
                    end
                end
            end

            READ_DATA: begin
                if (spi_clk_posedge) begin
                    data_valid <= 0;
                    resp <= {resp[6:0], MISO};
                    bit_cnt <= bit_cnt + 1'b1;
                    if (bit_cnt == 7) begin
                        bit_cnt <= 0;
                        data_out <= resp;
                        data_valid <= 1;
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt == 512) begin 
                            bit_cnt <= 0;
                            byte_cnt <= 0;
                            state <= READ_CRC;
                        end
                    end
                end
            end

            READ_CRC: begin
                // 2 字节 CRC
                if (spi_clk_posedge) begin
                    if (bit_cnt < 16) begin
                        bit_cnt <= bit_cnt + 1'b1;
                        CRC <= {CRC[14:0], MISO};
                    end else begin
                        state <= DONE;
                    end
                end
            end


//>==============================================================================


            DONE: begin
                read_done <= 1;
                cs_reg <= 1; // 拉高 CS，结束传输
                mosi_reg <= 1;
                // 可保持 done 状态，或回到 IDLE
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule