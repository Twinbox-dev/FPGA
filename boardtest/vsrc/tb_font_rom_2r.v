`timescale 1ns/1ps
module tb_font_rom_2r;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg [6:0] ascii_a = 7'd0, ascii_b = 7'd0;
    reg [3:0] row_a = 4'd0, row_b = 4'd0;
    wire [7:0] row_data_a, row_data_b;
    reg [7:0] golden [0:2047];

    font_rom_2r #(
        .MEM_FILE("../board_display/user_source/hdl_source/SD/font.mem")
    ) dut (
        .video_clk(clk),
        .ascii_a(ascii_a), .row_a(row_a), .row_data_a(row_data_a),
        .ascii_b(ascii_b), .row_b(row_b), .row_data_b(row_data_b)
    );

    task automatic check_pair;
        reg [7:0] expect_a, expect_b;
        begin
            expect_a = golden[{ascii_a, row_a}];
            expect_b = golden[{ascii_b, row_b}];
            @(posedge clk); #1;
            if (row_data_a !== expect_a || row_data_b !== expect_b)
                $fatal(1, "dual font read mismatch A=%02x/%02x B=%02x/%02x got=%02x/%02x expected=%02x/%02x",
                       ascii_a, row_a, ascii_b, row_b,
                       row_data_a, row_data_b, expect_a, expect_b);
        end
    endtask

    initial begin
        $readmemh("../board_display/user_source/hdl_source/SD/font.mem", golden);
        ascii_a = "A"; row_a = 4'd1;
        ascii_b = "B"; row_b = 4'd7;
        check_pair();
        ascii_a = "V"; row_a = 4'd15;
        ascii_b = "0"; row_b = 4'd3;
        check_pair();
        ascii_a = 7'd0; row_a = 4'd0;
        ascii_b = "z"; row_b = 4'd12;
        check_pair();
        $display("PASS shared font ROM: independent synchronous reads on both ports");
        $finish;
    end
endmodule
