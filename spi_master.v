module spi_master (
    input sys_clk,      // 系统时钟（50MHz）
    input rst_n,        // 复位按钮K16,按下时复位
    input MISO,         // SD卡数据输入
    output reg CS,      // 片选（低有效）
    output reg MOSI,    // 主机输出
    output reg spi_clk, // SPI时钟
    input [5:0] cmd,    // 命令输入
    input [31:0] addr,  // 地址输入
    input [7:0] data_in,// 写入数据
    output reg [7:0] data_out,// 读出数据
    output reg ready    // 操作完成信号
);

    // 定义状态
    typedef enum reg [2:0] {
        IDLE = 3'b001,
        INIT = 3'b010,
        CMD = 3'b100,
        DATA_WRITE = 3'b101,
        DATA_READ = 3'b110
    } state_t;
    state_t state, next_state;

    // 状态机
    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n)
            state <= IDLE;
        else
            state <= next_state;
    end

    // 状态机的下一个状态逻辑
    always @(*) begin
        case (state)
            IDLE : begin
                if (cmd != 6'b000000)
                    next_state = INIT;
                else
                    next_state = IDLE;
            end
            INIT : next_state = (sd_init_done) ? CMD : INIT;
            CMD : next_state = (cmd == 6'b000001) ? DATA_WRITE : DATA_READ;
            DATA_WRITE : next_state = IDLE; // 假设写操作完成后直接返回空闲
            DATA_READ : next_state = IDLE;  // 假设读操作完成后直接返回空闲
            default : next_state = IDLE;
        endcase
    end

    // 状态机输出逻辑
    always @(posedge sys_clk) begin
        if (state == IDLE) begin
            ready <= 1;
            CS <= 1;
        end else if (state == INIT) begin
            ready <= 0;
            CS <= 0;
        end else if (state == CMD) begin
            ready <= 0;
            // 根据cmd的值发送合适的命令序列
        end else if (state == DATA_WRITE) begin
            ready <= 0;
            // 根据addr和data_in写入数据
        end else if (state == DATA_READ) begin
            ready <= 0;
            // 根据addr读取数据，保存到data_out
        end
    end

    // 实例化 SD_Initial 模块
    wire sd_init_done;
    wire [5:0] led_o; // 如果你需要使用led_o，可以在这里定义

    SD_Initial sd_init_inst (
        .MISO(MISO),
        .clk(sys_clk),
        .rst_n(rst_n),
        .led_o(led_o),
        .CS(CS),
        .MOSI(MOSI),
        .spi_clk(spi_clk),
        .sd_init_done(sd_init_done)
    );

endmodule
