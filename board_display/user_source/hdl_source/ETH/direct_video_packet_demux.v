// Split direct-video row datagrams from the existing display control stream.
// The first two payload bytes are held until the VD magic is known. A single
// pending byte then preserves one-byte-per-cycle throughput for both paths.
module direct_video_packet_demux #(parameter DROP_AUDIO=0)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx_valid,
    input  wire [7:0]  rx_data,
    input  wire [15:0] rx_length,
    input  wire        rx_packet_start,
    input  wire        rx_packet_end,

    output reg         app_valid,
    output reg  [7:0]  app_data,
    output reg  [15:0] app_length,
    output reg         app_packet_start,
    output reg         app_packet_end,

    output reg         video_valid,
    output reg  [7:0]  video_data,
    output reg  [15:0] video_length,
    output reg         video_packet_start,
    output reg         video_packet_end
);
    reg probing;
    reg active;
    reg route_video;reg route_drop;
    reg [7:0] first_data;
    reg [15:0] first_length;
    reg first_end;
    reg pending_valid;
    reg [7:0] pending_data;
    reg [15:0] pending_length;
    reg pending_start;
    reg pending_end;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            probing <= 1'b0;
            active <= 1'b0;
            route_video <= 1'b0;route_drop<=0;
            first_data <= 8'd0;
            first_length <= 16'd0;
            first_end <= 1'b0;
            pending_valid <= 1'b0;
            pending_data <= 8'd0;
            pending_length <= 16'd0;
            pending_start <= 1'b0;
            pending_end <= 1'b0;
            app_valid <= 1'b0;
            app_data <= 8'd0;
            app_length <= 16'd0;
            app_packet_start <= 1'b0;
            app_packet_end <= 1'b0;
            video_valid <= 1'b0;
            video_data <= 8'd0;
            video_length <= 16'd0;
            video_packet_start <= 1'b0;
            video_packet_end <= 1'b0;
        end else begin
            app_valid <= 1'b0;
            app_packet_start <= 1'b0;
            app_packet_end <= 1'b0;
            video_valid <= 1'b0;
            video_packet_start <= 1'b0;
            video_packet_end <= 1'b0;

            if (rx_valid && rx_packet_start) begin
                if (pending_valid) begin
                    if (route_video) begin
                        video_valid <= 1'b1;
                        video_data <= pending_data;
                        video_length <= pending_length;
                        video_packet_start <= pending_start;
                        video_packet_end <= pending_end;
                    end else if(!route_drop)begin
                        app_valid <= 1'b1;
                        app_data <= pending_data;
                        app_length <= pending_length;
                        app_packet_start <= pending_start;
                        app_packet_end <= pending_end;
                    end
                end
                probing <= 1'b1;
                active <= 1'b0;
                first_data <= rx_data;
                first_length <= rx_length;
                first_end <= rx_packet_end;
                pending_valid <= 1'b0;
            end else if (probing && rx_valid) begin
                route_video <= (first_data == 8'h56) && (rx_data == 8'h44);
                route_drop<=DROP_AUDIO && first_data==8'h41 && rx_data==8'h44;
                if ((first_data == 8'h56) && (rx_data == 8'h44)) begin
                    video_valid <= 1'b1;
                    video_data <= first_data;
                    video_length <= first_length;
                    video_packet_start <= 1'b1;
                    video_packet_end <= first_end;
                end else if(!(DROP_AUDIO && first_data==8'h41 && rx_data==8'h44))begin
                    app_valid <= 1'b1;
                    app_data <= first_data;
                    app_length <= first_length;
                    app_packet_start <= 1'b1;
                    app_packet_end <= first_end;
                end
                pending_valid <= 1'b1;
                pending_data <= rx_data;
                pending_length <= rx_length;
                pending_start <= 1'b0;
                pending_end <= rx_packet_end;
                probing <= 1'b0;
                active <= 1'b1;
            end else if (probing && !rx_valid && first_end) begin
                app_valid <= 1'b1;
                app_data <= first_data;
                app_length <= first_length;
                app_packet_start <= 1'b1;
                app_packet_end <= 1'b1;
                probing <= 1'b0;
            end else if (active) begin
                if (pending_valid) begin
                    if (route_video) begin
                        video_valid <= 1'b1;
                        video_data <= pending_data;
                        video_length <= pending_length;
                        video_packet_start <= pending_start;
                        video_packet_end <= pending_end;
                    end else if(!route_drop)begin
                        app_valid <= 1'b1;
                        app_data <= pending_data;
                        app_length <= pending_length;
                        app_packet_start <= pending_start;
                        app_packet_end <= pending_end;
                    end
                end
                if (rx_valid) begin
                    pending_valid <= 1'b1;
                    pending_data <= rx_data;
                    pending_length <= rx_length;
                    pending_start <= 1'b0;
                    pending_end <= rx_packet_end;
                end else begin
                    pending_valid <= 1'b0;
                    if (pending_end)
                        active <= 1'b0;
                end
            end else if (rx_valid && rx_packet_end) begin
                // A malformed one-byte datagram still reaches the legacy app
                // parser so its existing rejection/timeout behavior applies.
                app_valid <= 1'b1;
                app_data <= rx_data;
                app_length <= rx_length;
                app_packet_start <= rx_packet_start;
                app_packet_end <= 1'b1;
            end
        end
    end
endmodule
