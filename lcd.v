module lcd_timing
(
    input                   clk,    // 系统时钟50MHz
    input                   lcd_clk,
    input                   rst_n, // user button K16
    output                  lcd_en,
    output                  lcd_clk,

    output          [5:0]   lcd_r,
    output          [5:0]   lcd_b,
    output          [5:0]   lcd_g
);
    



    // 定义ROM存储器,需要综合布局布线--40min
    reg [15:0] image_rom [0:383999];  // 800 * 480 = 384000个像素


    // Horizen count to Hsync, then next Horizen line.
    parameter       H_Pixel_Valid    = 16'd800;
    parameter       H_FrontPorch     = 16'd210;
    parameter       H_BackPorch      = 16'd182;  
    parameter       PixelForHS       = H_Pixel_Valid + H_FrontPorch + H_BackPorch;

    parameter       V_Pixel_Valid    = 16'd480; 
    parameter       V_FrontPorch     = 16'd45;  
    parameter       V_BackPorch      = 16'd8;    
    parameter       PixelForVS       = V_Pixel_Valid + V_FrontPorch + V_BackPorch;

    // Horizen pixel count
    reg         [15:0]  H_PixelCount;
    reg         [15:0]  V_PixelCount;

    // 像素地址计算
    wire [18:0] pixel_addr;
    reg  [15:0] pixel_data;
    wire        display_area;

    // 时序计数器
    always @( posedge lcd_clk or negedge rst_n ) begin
        if( !rst_n ) begin
            V_PixelCount <= 16'b0;     
            H_PixelCount <= 16'b0;
        end
        else if( H_PixelCount == PixelForHS - 1 ) begin
            H_PixelCount <= 16'b0;
            if( V_PixelCount == PixelForVS - 1 )
                V_PixelCount <= 16'b0;
            else
                V_PixelCount <= V_PixelCount + 1'b1;
        end
        else begin
            H_PixelCount <= H_PixelCount + 1'b1;
        end
    end

    // 显示区域判断
    assign display_area = (H_PixelCount >= H_BackPorch) && 
                        (H_PixelCount < H_Pixel_Valid + H_BackPorch) &&
                        (V_PixelCount >= V_BackPorch) && 
                        (V_PixelCount < V_Pixel_Valid + V_BackPorch);

    // 像素地址计算 (行优先)
    assign pixel_addr = (V_PixelCount - V_BackPorch) * H_Pixel_Valid + 
                        (H_PixelCount - H_BackPorch);

    // 从ROM读取像素数据
    always @(posedge lcd_clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_data <= 16'h0000;
        end else if (display_area && (pixel_addr < 384000)) begin
            pixel_data <= image_rom[pixel_addr];
        end else begin
            pixel_data <= 16'h0000;  // 非显示区域输出黑色
        end
    end

    // RGB565 转 RGB666 (低位补零)
    // RGB565格式: RRRRR GGGGGG BBBBB (16位)
    // RGB666格式: RRRRRR GGGGGG BBBBBB (18位，每个颜色6位)
    
    wire [4:0] rgb565_r = pixel_data[15:11];  // 高5位是红色
    wire [5:0] rgb565_g = pixel_data[10:5];   // 中间6位是绿色  
    wire [4:0] rgb565_b = pixel_data[4:0];    // 低5位是蓝色
    
    // 将5位扩展到6位：复制高位到低位
    assign lcd_r = {rgb565_r, rgb565_r[4]};  // R5 -> R6: 复制最高位
    assign lcd_g = rgb565_g;                // G6保持不变
    assign lcd_b = {rgb565_b, rgb565_b[4]};  // B5 -> B6: 复制最高位

    // 或者使用另一种扩展方法：低位补0（更简单）
    // assign lcd_r = {rgb565_r, 1'b0};  // R5 -> R6: 低位补0
    // assign lcd_g = rgb565_g;          // G6保持不变  
    // assign lcd_b = {rgb565_b, 1'b0};  // B5 -> B6: 低位补0

    // DE信号生成
    assign lcd_en = display_area;

endmodule
