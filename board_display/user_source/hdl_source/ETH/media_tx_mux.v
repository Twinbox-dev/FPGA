`timescale 1ns/1ps

// One UDP-stack application TX port shared by control and media responses.
// Control has priority at packet boundaries. A request is granted only when
// the UDP stack is ready and its previous ACK has returned low; ownership is
// retained for the packet's declared byte length.
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
    output wire        chunk_ready,
    output wire        stack_req,
    output wire        stack_valid,
    output wire [7:0]  stack_data,
    output wire [15:0] stack_length,
    output wire        chunk_active
);
    reg active, owner_chunk;
    reg [15:0] byte_count;
    wire choose_chunk = active ? owner_chunk : (!ctrl_req && chunk_req);
    assign chunk_active = active && owner_chunk;
    assign ctrl_ready = stack_ready && (active ? !owner_chunk : !stack_ack);
    assign chunk_ready = !active && !ctrl_req && stack_ready && !stack_ack;
    assign ctrl_ack = active && !owner_chunk && stack_ack;
    assign chunk_ack = active && owner_chunk && stack_ack;
    assign stack_req = active && (owner_chunk ? chunk_req : ctrl_req);
    assign stack_valid = active && (owner_chunk ? chunk_valid : ctrl_valid);
    assign stack_data = choose_chunk ? chunk_data : ctrl_data;
    // Keep the selected producer's length live through its ACK and byte stream.
    // eth_front publishes its fixed response length when the stack ACKs; the
    // display response length is already stable before REQUEST.
    assign stack_length = choose_chunk ? chunk_length : ctrl_length;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 0;
            owner_chunk <= 0;
            byte_count <= 16'd0;
        end else if (!active) begin
            if (stack_ready && !stack_ack && (ctrl_req || chunk_req)) begin
                active <= 1;
                owner_chunk <= choose_chunk;
                byte_count <= 16'd0;
            end
        end else begin
            if (stack_valid) begin
                if (stack_length == 0 || byte_count + 16'd1 >= stack_length) begin
                    active <= 0;
                    byte_count <= 16'd0;
                end else
                    byte_count <= byte_count + 16'd1;
            end
        end
    end
endmodule
