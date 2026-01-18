module top(
    input sys_clk,      // 系统时钟（50MHz）
    input rst_n,        // 复位按钮K16,按下时复位
    input MISO,         // SD卡数据输入
    output CS,          // 片选（低有效）
    output MOSI,        // 主机输出
    output spi_clk,     // SPI时钟
    output [5:0] led_o  // 表示各个状态机是否正确完成（共阳极，0亮1灭）
);

// 状态定义
localparam [1:0] 
    STATE_INIT = 2'b00,
    STATE_READ = 2'b01,
    STATE_IDLE = 2'b10;
    
reg [1:0] state = STATE_INIT;
wire init_done;
wire read_done;
wire [7:0] data_out;   
wire data_valid;

// 来自两个模块的输出信号
wire init_cs, init_mosi, init_spi_clk;
wire read_cs, read_mosi, read_spi_clk;
reg cs, mosi;  // 最终的输出信号

// 选择使用哪个时钟
reg use_read_clk = 0;

// 初始化完成检测（修正）
// 注意：不要用组合逻辑直接赋值，用wire
assign init_done = (led_o == 6'b100000) ? 1'b1 : 1'b0;

// 实例化 SD卡初始化 模块
SD_Initial sd_init_inst(
    .MISO(MISO),
    .clk(sys_clk), 
    .rst_n(rst_n),
    .led_o(led_o),
    .CS(init_cs),        // 改为内部信号
    .MOSI(init_mosi),    // 改为内部信号
    .spi_clk(init_spi_clk)  // 获取初始化模块生成的时钟
);

// 实例化 SD卡读扇区 模块
SD_Read_Block sd_read_inst(
    .clk(sys_clk),
    .rst_n(rst_n),
    .init_done(init_done),  // 来自初始化完成信号
    .MISO(MISO),
    .CS(read_cs),          // 改为内部信号
    .MOSI(read_mosi),      // 改为内部信号
    .spi_clk(read_spi_clk), // 获取读取模块生成的时钟
    .read_addr(32'd0),     // 读取地址
    .data_out(data_out),
    .data_valid(data_valid),
    .read_done(read_done)
);

// ===========================================
// 仲裁控制器：选择哪个模块控制SPI总线
// ===========================================
always @(posedge sys_clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= STATE_INIT;
        cs <= 1'b1;    // 默认不选中SD卡
        mosi <= 1'b1;  // 默认MOSI为高
        use_read_clk <= 0; // 默认使用初始化时钟
    end else begin
        case (state)
            STATE_INIT: begin
                // 初始化模块控制总线
                cs <= init_cs;
                mosi <= init_mosi;
                
                // 等待初始化完成
                if (init_done) begin
                    state <= STATE_READ;
                    use_read_clk <= 1; // 切换到读取时钟
                end
            end
            
            STATE_READ: begin
                // 读模块控制总线
                cs <= read_cs;
                mosi <= read_mosi;
                
                // 等待读取完成
                if (read_done) begin
                    state <= STATE_IDLE;
                end
            end
            
            STATE_IDLE: begin
                // 空闲状态，不选中SD卡
                cs <= 1'b1;
                mosi <= 1'b1;
                
                // 这里可以添加自动重启或其他逻辑
            end
            
            default: begin
                state <= STATE_INIT;
            end
        endcase
    end
end

// 根据状态选择时钟源输出到SD卡
assign spi_clk = use_read_clk ? read_spi_clk : init_spi_clk;

// 连接到输出端口
assign CS = cs;
assign MOSI = mosi;

endmodule