`timescale 1ns/10ps

`define CYCLE_TIME 20.0
`include "global_buffer.v"

`timescale 1ns/10ps

module PATTERN(
    output reg          clk,
    output reg          rst_n,
    output reg          in_valid,
    output reg [7:0]    M,
    output reg [7:0]    N,
    input               busy,

    input               A_ram_en,
    input      [15:0]   A_index,
    output     [31:0]   A_data_out,
    input               B_ram_en,
    input      [15:0]   B_index,
    output     [31:0]   B_data_out,
    input               C_ram_en,
    input               C_wr_en,
    input      [15:0]   C_index,
    input      [127:0]  C_data_in,
    output     [127:0]  C_data_out
);

integer PATNUM;
integer patcount;
integer cycles;
integer total_cycles;
integer in_fd;
integer scan_result;
integer error_count;
integer c_write_count;
integer a_read_count;
integer b_read_count;
integer expected_c_words;
integer expected_a_reads;
integer expected_b_reads;
integer max_cycles;
integer computation_started;

localparam RS_SEED  = 0;
localparam RS_SHIFT = 1;

integer rs_out_row;
integer rs_kernel_row_tile;
integer rs_output_tile;
integer rs_phase;
integer rs_seed_col;
integer rs_kernel_col;
integer rs_rows_completed;
integer rs_a_done;
integer rs_valid_lanes;
integer rs_output_col_base;
integer rs_expected_a_index;
integer rs_expected_b_index;
integer rs_expected_c_index;

reg [7:0] M_golden, N_golden;
reg [127:0] GOLDEN [0:65535];

initial clk = 1'b0;
always #(`CYCLE_TIME/2.0) clk = ~clk;

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(32)) gbuff_A(
    .clk(clk), .rst_n(rst_n), .ram_en(A_ram_en), .wr_en(1'b0),
    .index(A_index), .data_in(32'd0), .data_out(A_data_out)
);

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(32)) gbuff_B(
    .clk(clk), .rst_n(rst_n), .ram_en(B_ram_en), .wr_en(1'b0), .index(B_index),
    .data_in(32'd0), .data_out(B_data_out)
);

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(128)) gbuff_C(
    .clk(clk), .rst_n(rst_n), .ram_en(C_ram_en), .wr_en(C_wr_en), .index(C_index),
    .data_in(C_data_in), .data_out(C_data_out)
);

// Bram access checks
always @(negedge clk) begin
    if (rst_n && !busy) begin
        if (A_ram_en !== 1'b0 || B_ram_en !== 1'b0 || C_ram_en !== 1'b0 || C_wr_en !== 1'b0) begin
            $display("FAIL: BRAM access while TPU is idle");
            wrong_ans;
        end
    end
    if (rst_n && busy) begin
        if ((A_ram_en !== 1'b0 && A_ram_en !== 1'b1) ||
            (B_ram_en !== 1'b0 && B_ram_en !== 1'b1) ||
            (C_ram_en !== 1'b0 && C_ram_en !== 1'b1) ||
            (C_wr_en !== 1'b0 && C_wr_en !== 1'b1)) begin
            $display("FAIL: BRAM control signals must be 0 or 1 while TPU is busy");
            wrong_ans;
        end
        if (A_ram_en && (A_index + 3) >= M_golden * (M_golden + 3)) begin
            $display("FAIL: out-of-range input read A_index=%0d", A_index);
            wrong_ans;
        end
        if (B_ram_en && B_index >= N_golden * ((N_golden + 3) / 4)) begin
            $display("FAIL: out-of-range weight read B_index=%0d", B_index);
            wrong_ans;
        end
        if (A_ram_en) begin
            if (^A_index === 1'bx || b_read_count != expected_b_reads || rs_a_done ||
                (rs_out_row > 0 && c_write_count < rs_out_row * ((M_golden - N_golden + 4) / 4)))
                rs_wrong_ans;

            rs_output_col_base = rs_output_tile * 4;
            if ((M_golden - N_golden + 1 - rs_output_col_base) >= 4)
                rs_valid_lanes = 4;
            else
                rs_valid_lanes = M_golden - N_golden + 1 - rs_output_col_base;

            if (rs_phase == RS_SEED)
                rs_expected_a_index = (rs_output_col_base + rs_seed_col) * (M_golden + 3) + rs_out_row + rs_kernel_row_tile * 4;
            else
                rs_expected_a_index = (rs_output_col_base + rs_valid_lanes - 1 + rs_kernel_col) * (M_golden + 3) + rs_out_row + rs_kernel_row_tile * 4;

            if (A_index !== rs_expected_a_index[15:0]) begin
                rs_wrong_ans;
            end

            a_read_count = a_read_count + 1;
            computation_started = 1;
            advance_rs_a;
        end
        if (B_ram_en) begin
            if (^B_index === 1'bx || computation_started)
                rs_wrong_ans;
            rs_expected_b_index = b_read_count;
            if (B_index !== rs_expected_b_index[15:0])
                rs_wrong_ans;
            b_read_count = b_read_count + 1;
        end
        if (C_wr_en && !C_ram_en) begin
            $display("FAIL: C_wr_en asserted without C_ram_en");
            wrong_ans;
        end
        if (C_ram_en && C_wr_en) begin
            if (^C_index === 1'bx || ^C_data_in === 1'bx) begin
                $display("FAIL: C write address or data is invalid");
                wrong_ans;
            end
            if (C_index >= expected_c_words) begin
                $display("FAIL: out-of-range output write C_index=%0d", C_index);
                wrong_ans;
            end
            rs_expected_c_index = c_write_count;
            if (C_index !== rs_expected_c_index[15:0] ||
                (C_index / ((M_golden - N_golden + 4) / 4)) >= rs_rows_completed)
                rs_wrong_ans;
            c_write_count = c_write_count + 1;
        end
    end
end

initial begin
    rst_n = 1'b1;
    in_valid = 1'b0;
    M = 'bx;
    N = 'bx;
    total_cycles = 0;
    c_write_count = 0;
    a_read_count = 0;
    b_read_count = 0;
    computation_started = 0;

    reset_task;
    in_fd = $fopen("./TESTBENCH/input.txt", "r");
    if (in_fd == 0) begin
        $display("FAIL: cannot open TESTBENCH/input.txt");
        wrong_ans;
    end
    scan_result = $fscanf(in_fd, "%d", PATNUM);

    for (patcount = 0; patcount < PATNUM; patcount = patcount + 1) begin
        read_config;
        validate_config;
        read_input_sram;
        read_weight_sram;
        read_golden;

        repeat (3) @(negedge clk);
        c_write_count = 0;
        a_read_count = 0;
        b_read_count = 0;
        computation_started = 0;
        reset_rs_checker;
        in_valid = 1'b1;
        M = M_golden;
        N = N_golden;
        @(negedge clk);
        in_valid = 1'b0;
        M = 'bx;
        N = 'bx;

        if (busy !== 1'b1) begin
            $display("FAIL pattern %0d: busy was not asserted after in_valid", patcount);
            wrong_ans;
        end

        wait_finished;
        golden_check;
        $display("\033[0;34mPASS PATTERN NO.%4d,\033[m \033[0;32m Cycles: %3d\033[m", patcount, cycles);
        total_cycles = total_cycles + cycles;
        repeat (3) @(negedge clk);
    end

    YOU_PASS_task;
    $finish;
end

task reset_task; begin
    force clk = 1'b0;
    #(`CYCLE_TIME * 2); rst_n = 1'b0;
    #(`CYCLE_TIME * 2);
    if (busy !== 1'b0 || A_ram_en !== 1'b0 || B_ram_en !== 1'b0 || C_ram_en !== 1'b0 || C_wr_en !== 1'b0) begin
        $display("----------------------------------------------------------------");
        $display("                        Reset failed!                           ");
        $display("         Output signal should be 0 after initial RESET at %8t   ", $time);
        $display("----------------------------------------------------------------");
        wrong_ans;
    end
    #(`CYCLE_TIME); rst_n = 1'b1;
    release clk;
end endtask

task read_config; begin
    scan_result = $fscanf(in_fd, "%h %h", M_golden, N_golden);
end endtask

task validate_config; begin
    integer a_words;
    integer b_words;
    integer l_value;
    l_value = M_golden - N_golden + 1;
    a_words = M_golden * (M_golden + 3);
    b_words = N_golden * ((N_golden + 3) / 4);
    expected_c_words = l_value * ((l_value + 3) / 4);
    expected_b_reads = N_golden * ((N_golden + 3) / 4);
    expected_a_reads = l_value * ((N_golden + 3) / 4) * (l_value + ((l_value + 3) / 4) * (N_golden - 1));
    if (N_golden == 0 || M_golden < N_golden || a_words > 65536 || b_words > 65536 || expected_c_words > 65536) begin
        $display("FAIL: invalid or oversized test configuration M=%0d N=%0d",
                 M_golden, N_golden);
        wrong_ans;
    end
end endtask

task reset_rs_checker; begin
    rs_out_row = 0;
    rs_kernel_row_tile = 0;
    rs_output_tile = 0;
    rs_phase = RS_SEED;
    rs_seed_col = 0;
    rs_kernel_col = 1;
    rs_rows_completed = 0;
    rs_a_done = 0;
    rs_valid_lanes = 0;
    rs_output_col_base = 0;
    rs_expected_a_index = 0;
    rs_expected_b_index = 0;
    rs_expected_c_index = 0;
end endtask

task advance_rs_a; begin
    if (rs_phase == RS_SEED) begin
        if (rs_seed_col + 1 < rs_valid_lanes) begin
            rs_seed_col = rs_seed_col + 1;
        end
        else if (N_golden > 1) begin
            rs_phase = RS_SHIFT;
            rs_kernel_col = 1;
        end
        else begin
            advance_rs_tile;
        end
    end
    else begin
        if (rs_kernel_col + 1 < N_golden)
            rs_kernel_col = rs_kernel_col + 1;
        else
            advance_rs_tile;
    end
end endtask

task advance_rs_tile; begin
    rs_phase = RS_SEED;
    rs_seed_col = 0;
    rs_kernel_col = 1;
    if (rs_output_tile + 1 < ((M_golden - N_golden + 4) / 4)) begin
        rs_output_tile = rs_output_tile + 1;
    end
    else begin
        rs_output_tile = 0;
        if (rs_kernel_row_tile + 1 < ((N_golden + 3) / 4)) begin
            rs_kernel_row_tile = rs_kernel_row_tile + 1;
        end
        else begin
            rs_kernel_row_tile = 0;
            rs_rows_completed = rs_rows_completed + 1;
            if (rs_out_row + 1 < (M_golden - N_golden + 1))
                rs_out_row = rs_out_row + 1;
            else
                rs_a_done = 1;
        end
    end
end endtask

task rs_wrong_ans; begin
    $display("FAIL: design does not follow the required row-stationary dataflow");
    wrong_ans;
end endtask

task read_input_sram; begin
    reg [7:0] value;
    reg [7:0] input_bytes [0:65535];
    integer bytes;
    integer index;
    bytes = M_golden * (M_golden + 3);
    for (index = 0; index < bytes; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h", value);
        input_bytes[index] = value;
    end
    for (index = 0; index <= bytes - 4; index = index + 1) begin
        gbuff_A.gbuff[index] = {input_bytes[index], input_bytes[index + 1],
                                input_bytes[index + 2], input_bytes[index + 3]};
    end
end endtask

task read_weight_sram; begin
    reg [7:0] value0, value1, value2, value3;
    integer words;
    integer index;
    words = N_golden * ((N_golden + 3) / 4);
    for (index = 0; index < words; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h %h %h %h", value0, value1, value2, value3);
        gbuff_B.gbuff[index] = {value0, value1, value2, value3};
    end
end endtask

task read_golden; begin
    reg [31:0] value0, value1, value2, value3;
    integer index;
    for (index = 0; index < expected_c_words; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h %h %h %h", value0, value1, value2, value3);
        GOLDEN[index] = {value0, value1, value2, value3};
    end
end endtask

task wait_finished; begin
    cycles = 0;
    max_cycles = 300 + 2 * N_golden * ((N_golden + 3) / 4) +
                 (M_golden - N_golden + 1) *
                 (((M_golden - N_golden + 4) / 4) *
                  ((N_golden + 3) / 4) * (9 * N_golden + 20) +
                  2 * (M_golden - N_golden + 1));
    while (busy === 1'b1) begin
        cycles = cycles + 1;
        if (cycles > max_cycles) begin
            $display ("------------------------------------------------------------------------------------");
            $display ("                 Pattern %0d exceeded the cycle limit (%0d cycles)                 ",
                      patcount, cycles);
            $display ("------------------------------------------------------------------------------------");
            wrong_ans;
        end
        @(negedge clk);
    end
end endtask

task golden_check; begin
    integer index;
    error_count = 0;
    if (c_write_count !== expected_c_words) begin
        $display("FAIL pattern %0d: C write count=%0d, expected=%0d",
                 patcount, c_write_count, expected_c_words);
        error_count = error_count + 1;
    end
    if (a_read_count !== expected_a_reads) begin
        rs_wrong_ans;
    end
    if (b_read_count !== expected_b_reads) begin
        rs_wrong_ans;
    end
    if (!rs_a_done || rs_rows_completed != (M_golden - N_golden + 1)) begin
        rs_wrong_ans;
    end
    for (index = 0; index < expected_c_words; index = index + 1) begin
        if (gbuff_C.gbuff[index] !== GOLDEN[index]) begin
            $display("FAIL C[%0d]=%032h, expected=%032h",
                     index, gbuff_C.gbuff[index], GOLDEN[index]);
            error_count = error_count + 1;
        end
    end
    if (error_count != 0) begin
        $display("FAIL pattern %0d: %0d errors", patcount, error_count);
        wrong_ans;
    end
end endtask

task wrong_ans; begin
    $display("       /                       \\                                          ");
    $display("    /X/                       \\X\\                                         ");
    $display("   |XX\\         _____         /XX|                                        ");   
    $display("   |XXX\\     _/       \\_     /XXX|___________                             ");      
    $display("    \\XXXXXXX             XXXXXXX/            \\\\\\                          ");  
    $display("      \\XXXX    /     \    XXXXX/                \\\\\\                       ");      
    $display("           |   0     0   |                         \\\\                      ");        
    $display("            |           |                           \\                     ");         
    $display("             \\         /                            |______//             ");       
    $display("              \\       /                             |                     ");       
    $display("               | O_O | \\                            |                     ");    
    $display("                \\ _ /   \\________________           |                     ");                 
    $display("                           | |  | |      \\         /                      ");                        
    $display("     Oh,no      ,          / |  / |       \\______/                        ");            
    $display("      Please...            \\ |  \\ |        \\ |  \\ |                       ");                           
    $display("                         __| |__| |      __| |__| |                       ");      
    $display("                         |___||___|      |___||___|                       ");    
    $display("--------------------------------------------------------------------------");
    $display("               Unfortunately, your answer is wrong                        ");
    $display("--------------------------------------------------------------------------");
    $finish;
end endtask




task YOU_PASS_task; begin
    $display("                             /  \\                                   ");                      
    $display("                            / _  \\                                  ");                        
    $display("                           | /  \\ |                                 ");                          
    $display("                           ||   || _______                         ");                               
    $display("                           ||   || | \\     \\                        ");                              
    $display("                           ||   || || \\     \\                       ");                               
    $display("                           ||   || ||  \\    |                       ");                          
    $display("                           ||   || ||   \\__/                        ");                          
    $display("                           ||   || ||   ||                         ");                        
    $display("                             \\_/  \\_/  \\_//                          ");                
    $display("                           /   _     _    \\                         ");                          
    $display("                          /                \\                        ");                       
    $display("                          |    O     O     |                        ");                    
    $display("                          |   \\  ___  /    |                        ");                
    $display("                         /     \\ \\_/ /     \\                       ");             
    $display("                        /  -----  |  -----  \\                      ");                         
    $display("                        |     \\__/|\\__/     |                      ");                
    $display("                        \\       |_|_|       /                      ");                     
    $display("                         \\_____       _____/                       ");                         
    $display("                               \\     /                             ");                       
    $display("                               |     |                             ");                 
	$display("-------------------------------------------------------------------------");
	$display("                          Congratulations!                			   ");
	$display("                   You have passed all patterns!          			   ");
	$display("                   Your execution cycles = %5d cycles   				   ", total_cycles);
	$display("                   Your clock period = %.1f ns        				   ", `CYCLE_TIME);
	$display("                   Your total latency = %.1f ns         				   ", total_cycles*`CYCLE_TIME);
	$display("------------------------------------------------------------------------");
	$finish;
end endtask

endmodule
