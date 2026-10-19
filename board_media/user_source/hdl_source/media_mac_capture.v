`timescale 1ns/1ps
// Optional relocation of existing probe B: last production frame before MAC.
// Two 128-byte banks retain the latest formal packet; X freezes and dumps it,
// then capture re-arms at the next packet boundary. Dump words are repeated
// three times to retain probe B's default 3:1 sampler.
module media_mac_capture #(parameter integer HEADER_OFFSET=42) (
    input wire clk,rst,
    input wire [7:0] byte_data,
    input wire valid_n,ready_n,sof_n,eof_n,overflow,
    input wire dump,
    output reg tap_valid,tap_end,
    output reg [31:0] tap_word
);
    reg [7:0] ram[0:255]; /* fehdl force_ram=1, ram_style="bram" */
    reg saved_bank,write_bank,have_saved,frozen;
    reg [15:0] pos,saved_length;
    reg [7:0] kind,saved_kind;
    reg magic_ok,was_stalled,overflow_seen,end_seen;
    reg [2:0] state;
    reg [7:0] read_byte;
    reg [6:0] read_index;
    reg [7:0] read_count;
    reg wait_sof;
    reg [31:0] assembled;
    reg [1:0] repeat_count;
    reg [1:0] metadata;
    // After a dump, ignore any remainder of the packet that was interrupted
    // by the freeze and re-arm only at the next frame boundary.
    wire take=!valid_n && !ready_n && !frozen && (!wait_sof || !sof_n);
    wire [7:0] write_address={!sof_n ? !saved_bank : write_bank,!sof_n ? 7'd0 : pos[6:0]};
    wire write_enable=take && (!sof_n || pos<128);
    wire read_enable=state==1;
    always @(posedge clk)begin
        if(write_enable)ram[write_address]<=byte_data;
        if(read_enable)read_byte<=ram[{saved_bank,read_index}];
    end
    always @(posedge clk)begin
        if(rst)begin
            saved_bank<=0;write_bank<=1;have_saved<=0;frozen<=0;pos<=0;saved_length<=0;
            kind<=0;saved_kind<=0;magic_ok<=0;was_stalled<=0;overflow_seen<=0;end_seen<=0;
            state<=0;read_index<=0;read_count<=0;assembled<=0;repeat_count<=0;metadata<=0;wait_sof<=0;
            tap_valid<=0;tap_end<=0;tap_word<=0;
        end else begin
            tap_valid<=0;tap_end<=0;
            if(overflow)overflow_seen<=1;
            if(!valid_n && ready_n)was_stalled<=1;
            if(take)begin
                if(!sof_n)begin
                    write_bank<=!saved_bank;pos<=1;
                    magic_ok<=(HEADER_OFFSET==0) && (byte_data==8'haa);
                    kind<=0;wait_sof<=0;
                end else begin
                    pos<=pos+1'b1;
                    case(pos)
                        HEADER_OFFSET+0:magic_ok<=byte_data==8'haa;
                        HEADER_OFFSET+1:magic_ok<=magic_ok && byte_data==8'hbb;
                        HEADER_OFFSET+2:magic_ok<=magic_ok && byte_data==8'hcc;
                        HEADER_OFFSET+3:magic_ok<=magic_ok && byte_data==8'hdd;
                        HEADER_OFFSET+4:kind<=byte_data;
                        HEADER_OFFSET+5:magic_ok<=magic_ok && byte_data==0;
                        default:;
                    endcase
                    if(!eof_n && magic_ok && kind>=8'h20 && kind<=8'h24)begin
                        saved_bank<=write_bank;saved_length<=pos+1'b1;saved_kind<=kind;have_saved<=1;
                        if(kind==8'h21)end_seen<=0;
                        if(kind==8'h23)end_seen<=1;
                    end
                end
            end
            if(dump && state==0)begin
                frozen<=1;wait_sof<=1;tap_word<=32'h5041434d;repeat_count<=0;metadata<=0;state<=4;
                read_index<=0;read_count<=saved_length>128?8'd128:saved_length[7:0];
            end else case(state)
                0:;
                1:state<=2;
                2:begin
                    assembled[8*read_index[1:0]+:8]<=read_byte;
                    if(read_index[1:0]==3 || read_index+1>=read_count)state<=3;
                    else begin read_index<=read_index+1'b1;state<=1;end
                end
                3:begin tap_word<=assembled;repeat_count<=0;state<=4;metadata<=2;end
                4:begin
                    tap_valid<=1;
                    if(repeat_count==2)begin
                        repeat_count<=0;
                        if(metadata==0)begin
                            tap_word<={4'd0,have_saved,end_seen,was_stalled,overflow_seen,saved_kind,saved_length};metadata<=1;
                        end else if(metadata==1 && have_saved && read_count!=0)begin
                            read_index<=0;assembled<=0;state<=1;
                        end else if(metadata==2 && read_index+1<read_count)begin
                            read_index<=read_index+1'b1;assembled<=0;state<=1;
                        end else begin tap_end<=1;state<=0;frozen<=0;end
                    end else repeat_count<=repeat_count+1'b1;
                end
                default:state<=0;
            endcase
        end
    end
endmodule
