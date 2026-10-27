

module hdmi_phy_wrapper#(
    parameter DEVICE = "EG",
    parameter PIXEL_REGISTER=1
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_tmds_channel_0,
    input wire[9:0] I_tmds_channel_1,
    input wire[9:0] I_tmds_channel_2,
    input wire[9:0] I_tmds_channel_clk,
    
    output wire     O_tmds_ch0_p,
    output wire     O_tmds_ch1_p,
    output wire     O_tmds_ch2_p,
    output wire     O_tmds_clk_p
);
    
    // Terminate encoder combinational paths in the pixel clock domain.
    // The serializer loads late in the pixel period; sampling the encoder's
    // live combinational bus there can mix bits from two adjacent symbols.
    // Delay all four lanes uniformly, preserving the complete encoded stream.
    reg [9:0] pixel_ch0,pixel_ch1,pixel_ch2,pixel_clock;
    always @(posedge I_pixel_clk or posedge I_rst)begin
        if(I_rst)begin pixel_ch0<=0;pixel_ch1<=0;pixel_ch2<=0;pixel_clock<=0;end
        else begin pixel_ch0<=I_tmds_channel_0;pixel_ch1<=I_tmds_channel_1;
            pixel_ch2<=I_tmds_channel_2;pixel_clock<=I_tmds_channel_clk;end
    end
    wire [9:0] stable_ch0=PIXEL_REGISTER?pixel_ch0:I_tmds_channel_0;
    wire [9:0] stable_ch1=PIXEL_REGISTER?pixel_ch1:I_tmds_channel_1;
    wire [9:0] stable_ch2=PIXEL_REGISTER?pixel_ch2:I_tmds_channel_2;
    wire [9:0] stable_clock=PIXEL_REGISTER?pixel_clock:I_tmds_channel_clk;

    wire[9:0] S_tmds_data_ch0;
    wire[9:0] S_tmds_data_ch1;
    wire[9:0] S_tmds_data_ch2;
    wire[9:0] S_tmds_data_clk;

    assign S_tmds_data_ch0 = {stable_ch0[0],
                              stable_ch0[1],
                              stable_ch0[2],
                              stable_ch0[3],
                              stable_ch0[4],
                              stable_ch0[5],
                              stable_ch0[6],
                              stable_ch0[7],
                              stable_ch0[8],
                              stable_ch0[9]};

    assign S_tmds_data_ch1 = {stable_ch1[0],
                              stable_ch1[1],
                              stable_ch1[2],
                              stable_ch1[3],
                              stable_ch1[4],
                              stable_ch1[5],
                              stable_ch1[6],
                              stable_ch1[7],
                              stable_ch1[8],
                              stable_ch1[9]};

    assign S_tmds_data_ch2 = {stable_ch2[0],
                              stable_ch2[1],
                              stable_ch2[2],
                              stable_ch2[3],
                              stable_ch2[4],
                              stable_ch2[5],
                              stable_ch2[6],
                              stable_ch2[7],
                              stable_ch2[8],
                              stable_ch2[9]};

    assign S_tmds_data_clk = {stable_clock[0],
                              stable_clock[1],
                              stable_clock[2],
                              stable_clock[3],
                              stable_clock[4],
                              stable_clock[5],
                              stable_clock[6],
                              stable_clock[7],
                              stable_clock[8],
                              stable_clock[9]};


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u0_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),

        .I_data_in    ( S_tmds_data_ch0 ),
        .O_serial_out ( O_tmds_ch0_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u1_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_ch1 ),
        .O_serial_out ( O_tmds_ch1_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u2_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_ch2 ),
        .O_serial_out ( O_tmds_ch2_p    )
    );


    lane_lvds_10_1 #(
        .DEVICE ( DEVICE )    
    )u3_lane_lvds_8_1(
        .I_pixel_clk  ( I_pixel_clk     ),
        .I_serial_clk ( I_serial_clk    ),
        .I_rst        ( I_rst           ),
        
        .I_data_in    ( S_tmds_data_clk ),
        .O_serial_out ( O_tmds_clk_p    )
    );


endmodule





