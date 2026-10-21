`timescale 1ns/1ps

// Adapts FAT32's existing 512-byte LBA stream to the native SD host.  A full
// block is CRC-checked in the 100 MHz SD domain before this 50 MHz adapter
// exposes its first byte to FAT32.
module sd_native_adapter #(
    parameter integer DATA_TIMEOUT_CYCLES = 10000000,
    parameter integer FORCE_25MHZ = 0
) (
    input  wire        clk,
    input  wire        sd_clk_100m,
    input  wire        pll_locked,
    input  wire        rst,
    output wire        sd_clk,
    inout  wire        sd_cmd,
    input  wire [3:0]  sd_dat,
    output wire        sd_init_done,
    output wire [7:0]  sd_diag_flags, // {init, SDHC, HS support, HS active, debug-active, state[2:0]}
    output wire [15:0] init_debug_word, // failed init: first TX mismatch position/value + last 8 CMD samples
    output reg  [31:0] last_read_cycles,
    output reg  [31:0] last_failure_lba,
    output reg  [7:0]  last_failure_info, // {error[3:0], retry_count[1:0], reserved[1:0]}
    output wire [31:0] stream_debug,
    input  wire [31:0] o_lba,
    input  wire        o_req,
    output wire        i_ready,
    output reg  [7:0]  i_data,
    output reg         i_dval,
    output reg         i_done,
    output reg         i_err
);
    localparam [1:0] IDLE=2'd0,WAIT_RESULT=2'd1,STREAM=2'd2;
    reg [1:0] state;
    reg [31:0] request_lba;
    reg request_toggle;
    wire result_toggle;
    wire result_error;
    wire host_initialized;
    wire host_hs_supported,host_hs_active,host_high_capacity,host_hcs_requested;
    wire [5:0] host_state_code;
    wire [15:0] host_init_debug_word;
    wire [31:0] host_last_read_cycles;
    wire [31:0] host_last_failed_lba;
    wire [3:0] host_last_read_error_code;
    wire [1:0] host_last_read_retry_count;
    reg [1:0] init_sync,result_sync;
    reg result_seen;
    reg [7:0] diag_sync0,diag_sync1;
    reg [15:0] init_debug_sync0,init_debug_sync1;
    reg [9:0] fetch_index;
    reg [9:0] emitted_count;
    reg ram_pending;
    wire [7:0] ram_data;
    wire ram_rd_en=(state==STREAM && fetch_index<10'd512);

    // A6 diagnostic payload: top bits are adapter state. WAIT_RESULT reports
    // the requested LBA; STREAM reports fetch/emitted offsets and recent timing.
    assign stream_debug={state,
        (state==STREAM ? {fetch_index,emitted_count,host_last_read_cycles[9:0]} : request_lba[29:0])};

    assign sd_init_done=init_sync[1];
    assign sd_diag_flags=diag_sync1;
    assign init_debug_word=init_debug_sync1;
    assign i_ready=sd_init_done && state==IDLE;

    sd_native_host #(.DATA_TIMEOUT_CYCLES(DATA_TIMEOUT_CYCLES),
                     .FORCE_25MHZ(FORCE_25MHZ)) u_host (
        .clk(sd_clk_100m),.rst(rst),.pll_locked(pll_locked),.sd_clk(sd_clk),.sd_cmd(sd_cmd),.sd_dat(sd_dat),
        .req_toggle_async(request_toggle),.req_lba_async(request_lba),
        .result_toggle(result_toggle),.result_error(result_error),.initialized(host_initialized),
        .high_speed_supported(host_hs_supported),.high_speed_active(host_hs_active),
        .high_capacity(host_high_capacity),.high_capacity_support_req(host_hcs_requested),
        .state_code(host_state_code),.init_debug_word(host_init_debug_word),
        .last_read_cycles(host_last_read_cycles),.last_failed_lba(host_last_failed_lba),
        .last_read_error_code(host_last_read_error_code),.last_read_retry_count(host_last_read_retry_count),
        .ram_rd_clk(clk),.ram_rd_en(ram_rd_en),.ram_rd_addr(fetch_index[8:0]),.ram_rd_data(ram_data)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE;request_lba<=0;request_toggle<=0;init_sync<=0;result_sync<=0;
            result_seen<=0;fetch_index<=0;emitted_count<=0;ram_pending<=0;
            diag_sync0<=0;diag_sync1<=0;last_read_cycles<=0;last_failure_lba<=0;last_failure_info<=0;
            init_debug_sync0<=0;init_debug_sync1<=0;
            i_data<=0;i_dval<=0;i_done<=0;i_err<=0;
        end else begin
            init_sync<={init_sync[0],host_initialized};
            result_sync<={result_sync[0],result_toggle};
            diag_sync0<={host_initialized,host_high_capacity,host_hs_supported,host_hs_active,
                         host_initialized && host_state_code!=6'd29,
                         host_state_code[2:0]};
            diag_sync1<=diag_sync0;
            init_debug_sync0<=host_init_debug_word;init_debug_sync1<=init_debug_sync0;
            i_dval<=0;i_done<=0;i_err<=0;
            case (state)
                IDLE: begin
                    ram_pending<=0;
                    if (o_req && i_ready) begin
                        request_lba<=o_lba;request_toggle<=~request_toggle;state<=WAIT_RESULT;
                    end
                end
                WAIT_RESULT: begin
                    if (result_sync[1]!=result_seen) begin
                        result_seen<=result_sync[1];
                        last_read_cycles<=host_last_read_cycles;
                        last_failure_lba<=host_last_failed_lba;
                        last_failure_info<={host_last_read_error_code,host_last_read_retry_count,2'b00};
                        if (result_error) begin i_err<=1;state<=IDLE;end
                        else begin fetch_index<=0;emitted_count<=0;ram_pending<=0;state<=STREAM;end
                    end
                end
                STREAM: begin
                    if (ram_rd_en) begin fetch_index<=fetch_index+1'b1;ram_pending<=1;end
                    if (ram_pending) begin
                        i_data<=ram_data;i_dval<=1;
                        if (emitted_count==10'd511) begin
                            i_done<=1;state<=IDLE;ram_pending<=0;
                        end else emitted_count<=emitted_count+1'b1;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end

endmodule
