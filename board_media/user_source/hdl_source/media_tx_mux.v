`timescale 1ns/1ps

// One UDP-stack application TX port shared by command forwarding and media
// chunks.  Control has priority before a packet starts; ownership stays fixed
// through request, ACK and the final data-valid beat.
module media_tx_mux (
    input  wire        clk,
    input  wire        rst,
    input  wire        stack_ready,
    input  wire        stack_ack,
    input  wire        ctrl_req,
    input  wire        ctrl_valid,
    input  wire [7:0]  ctrl_data,
    input  wire [15:0] ctrl_length,
    output wire        ctrl_ready,
    output wire        ctrl_ack,
    input  wire        chunk_req,
    input  wire        chunk_valid,
    input  wire [7:0]  chunk_data,
    input  wire [15:0] chunk_length,
    output wire        chunk_ack,
    output wire        stack_req,
    output wire        stack_valid,
    output wire [7:0]  stack_data,
    output wire [15:0] stack_length
);
    reg active, owner_chunk, seen_data;
    wire choose_chunk = active ? owner_chunk : (!ctrl_req && chunk_req);
    assign ctrl_ready = stack_ready && (!active || !owner_chunk);
    assign ctrl_ack = stack_ack && !choose_chunk;
    assign chunk_ack = stack_ack && choose_chunk;
    assign stack_req = active ? (owner_chunk ? chunk_req : ctrl_req)
                              : (ctrl_req || chunk_req);
    assign stack_valid = choose_chunk ? chunk_valid : ctrl_valid;
    assign stack_data = choose_chunk ? chunk_data : ctrl_data;
    assign stack_length = choose_chunk ? chunk_length : ctrl_length;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 0;
            owner_chunk <= 0;
            seen_data <= 0;
        end else if (!active) begin
            if (ctrl_req || chunk_req) begin
                active <= 1;
                owner_chunk <= choose_chunk;
                seen_data <= 0;
            end
        end else begin
            if (stack_valid)
                seen_data <= 1;
            if (seen_data && !stack_valid)
                active <= 0;
        end
    end
endmodule
