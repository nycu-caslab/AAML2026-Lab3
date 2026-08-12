

`define CYCLE_TIME 20.0

`include "global_buffer.v"


module PATTERN #(
    parameter A_WIDTH = 4,
    parameter B_WIDTH = 8
)(
    clk,
    rst_n,
    
    in_valid,
    K,
    M,
    N,
    busy,

    A_wr_en,
    A_index,
    A_data_in,
    A_data_out,

    B_wr_en,
    B_index,
    B_data_in,
    B_data_out,

    C_wr_en,
    C_index,
    C_data_in,
    C_data_out
);


output reg          clk;
output reg          rst_n;

output reg          in_valid;
output reg [7:0]    K;
output reg [7:0]    M;
output reg [7:0]    N;
input               busy;


input               A_wr_en;
input      [15:0]   A_index;
input      [A_WIDTH*4-1:0] A_data_in;
output     [A_WIDTH*4-1:0] A_data_out;

input               B_wr_en;
input      [15:0]   B_index;
input      [B_WIDTH*4-1:0] B_data_in;
output     [B_WIDTH*4-1:0] B_data_out;

input               C_wr_en;
input      [15:0]   C_index;
input      [127:0]  C_data_in;
output     [127:0]  C_data_out;


// parameter PATNUM = 1000;


integer PATNUM;

integer cycles;
integer total_cycles;
integer in_fd;
integer patcount;
integer err;


real CYCLE;





reg [127:0] GOLDEN [65535:0];

reg [7:0] K_golden;
reg [7:0] M_golden;
reg [7:0] N_golden;



initial CYCLE = `CYCLE_TIME;
always #(CYCLE/2.0) clk = ~clk;



global_buffer #(
    .ADDR_BITS(16),
    .DATA_BITS(A_WIDTH*4)
)
gbuff_A(
    .clk(clk),
    .rst_n(rst_n),
    .wr_en(A_wr_en),
    .index(A_index),
    .data_in(A_data_in),
    .data_out(A_data_out)
);

global_buffer #(
    .ADDR_BITS(16),
    .DATA_BITS(B_WIDTH*4)
) gbuff_B(
    .clk(clk),
    .rst_n(rst_n),
    .wr_en(B_wr_en),
    .index(B_index),
    .data_in(B_data_in),
    .data_out(B_data_out)
);


global_buffer #(
    .ADDR_BITS(16),
    .DATA_BITS(128)
) gbuff_C(
    .clk(clk),
    .rst_n(rst_n),
    .wr_en(C_wr_en),
    .index(C_index),
    .data_in(C_data_in),
    .data_out(C_data_out)
);





integer dummy_var_for_iverilog;

initial begin

    rst_n = 1'b1;
    in_valid = 1'b0;
    K = 'bx;
    M = 'bx;
    N = 'bx;
    cycles = 0;
    total_cycles = 0;

    force clk = 0;


    reset_task;


    in_fd = $fopen("./TESTBENCH/input.txt", "r");

    //* PATNUM
    dummy_var_for_iverilog = $fscanf(in_fd, "%d", PATNUM);

    for(patcount = 0; patcount < PATNUM; patcount = patcount + 1) begin

        //* read input
        read_KMN;
        read_A_Matrix;
        read_B_Vector;
        read_golden_vector;
    
        //* start to feed data
        repeat(3) @(negedge clk);

        in_valid = 1'b1;
        K = K_golden;
        M = M_golden;
        N = N_golden;
        @(negedge clk);

        in_valid = 1'b0;
        K = 'bx;
        M = 'bx;
        N = 'bx;

        wait_finished;
        
        golden_check;

        $display("\033[0;34mPASS PATTERN NO.%4d,\033[m \033[0;32m Cycles: %3d\033[m", patcount ,cycles);
        total_cycles = total_cycles + cycles;
        cycles = 0;
        repeat(5) @(negedge clk);
    end

    YOU_PASS_task;
    $finish;

end


task reset_task ; begin

    #(3*`CYCLE_TIME); rst_n = 0;
    #(3*`CYCLE_TIME);

    if(busy !== 1'b0) begin
        $display("----------------------------------------------------------------");
        $display("                        Reset failed!                           ");
        $display("         Output signal should be 0 after initial RESET at %8t   ", $time);
        $display("----------------------------------------------------------------");
        #(100);
        $finish;
    end

    #(`CYCLE_TIME); rst_n = 1;
    release clk;
end endtask



task read_KMN; begin
    dummy_var_for_iverilog = $fscanf(in_fd, "%h", K_golden);
    dummy_var_for_iverilog = $fscanf(in_fd, "%h", M_golden);
    dummy_var_for_iverilog = $fscanf(in_fd, "%h", N_golden);
end endtask


task read_A_Matrix; begin
    reg [7:0] rbuf_a [3:0];
    integer nrow_a;
    integer i_a;

    nrow_a = (M_golden[1:0] !== 2'b00) ?  K_golden * ((M_golden>>2) + 1) : K_golden * (M_golden>>2);
    
    for(i_a=0;i_a<nrow_a;i_a=i_a+1) begin
        dummy_var_for_iverilog = $fscanf(in_fd, "%h %h %h %h", rbuf_a[3], rbuf_a[2], rbuf_a[1], rbuf_a[0]);
        gbuff_A.gbuff[i_a] = {
            rbuf_a[3][A_WIDTH-1:0],
            rbuf_a[2][A_WIDTH-1:0],
            rbuf_a[1][A_WIDTH-1:0],
            rbuf_a[0][A_WIDTH-1:0]
        };
        // $display("A[%d] = %8h", i_a, gbuff_A.gbuff[i_a]);
    end

end endtask


task read_B_Vector; begin
    reg [7:0] rbuf_b [3:0];
    integer nrow_b;
    integer i_b;

    nrow_b = K_golden;

    for(i_b=0;i_b<nrow_b;i_b=i_b+1) begin
        dummy_var_for_iverilog = $fscanf(in_fd, "%h %h %h %h", rbuf_b[3], rbuf_b[2], rbuf_b[1], rbuf_b[0]);
        gbuff_B.gbuff[i_b] = {
            rbuf_b[3][B_WIDTH-1:0],
            rbuf_b[2][B_WIDTH-1:0],
            rbuf_b[1][B_WIDTH-1:0],
            rbuf_b[0][B_WIDTH-1:0]
        };
        // $display("x[%d] = %8h", i_b, gbuff_B.gbuff[i_b]);
    end

end endtask


task read_golden_vector; begin
    reg [31:0] goldenbuf [3:0];
    integer nrow_golden;
    integer i_g;

    nrow_golden = M_golden;

    for(i_g=0;i_g<nrow_golden;i_g=i_g+1) begin
        dummy_var_for_iverilog = $fscanf(in_fd, "%h %h %h %h", goldenbuf[3], goldenbuf[2], goldenbuf[1], goldenbuf[0]);
        GOLDEN[i_g] = {goldenbuf[3], goldenbuf[2], goldenbuf[1], goldenbuf[0]};
        // $display("GOLDEN[%d] = %8h", i_g, GOLDEN[i_g][127:96]);
    end

end endtask


task wait_finished; begin

    cycles = 0;
    while(busy === 1'b1) begin
        cycles = cycles + 1;
        if(cycles >= 1500000) begin
            exceed_1500000_cycles;
        end
        @(negedge clk);
    end

end endtask




task exceed_1500000_cycles; begin
    $display ("------------------------------------------------------------------------------------");
    $display ("                               exceed 1500000 cycles, (%d) wrong                      ", cycles);
    $display ("------------------------------------------------------------------------------------");
    repeat(10)@(negedge clk);
    $finish;
end endtask



task golden_check; begin
    integer nrow_gc;
    integer i_gc;
    err = 0;

    nrow_gc = M_golden;
    for(i_gc=0;i_gc<nrow_gc;i_gc=i_gc+1) begin
        if(GOLDEN[i_gc][127:96] !== gbuff_C.gbuff[i_gc][127:96]) begin
            $display("gbuff[%d][127:96] = %8h, expect = %8h", i_gc, gbuff_C.gbuff[i_gc][127:96], GOLDEN[i_gc][127:96]);
            err = err + 1;
        end 

        if(GOLDEN[i_gc][95:64] !== gbuff_C.gbuff[i_gc][95:64]) begin
            $display("gbuff[%d][95:64] = %8h, expect = %8h", i_gc, gbuff_C.gbuff[i_gc][95:64], GOLDEN[i_gc][95:64]);
            err = err + 1;
        end

        if(GOLDEN[i_gc][63:32] !== gbuff_C.gbuff[i_gc][63:32]) begin
            $display("gbuff[%d][63:32] = %8h, expect = %8h", i_gc, gbuff_C.gbuff[i_gc][63:32], GOLDEN[i_gc][63:32]);
            err = err + 1;
        end

        if(GOLDEN[i_gc][31:0] !== gbuff_C.gbuff[i_gc][31:0]) begin
            $display("gbuff[%d][31:0] = %8h, expect = %8h", i_gc, gbuff_C.gbuff[i_gc][31:0], GOLDEN[i_gc][31:0]);
            err = err + 1;
        end
    end


    if(err != 0) begin
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
    $display ("------------------------------------------------------------------");
	$display ("                            Congratulations!                  ");
	$display ("                     You have passed all patterns!            ");
	$display ("                     Your execution cycles = %5d cycles         ", total_cycles);
	$display ("                     Your clock period = %.1f ns           ", `CYCLE_TIME);
	$display ("                     Your total latency = %.1f ns               ", total_cycles*`CYCLE_TIME);
	$display ("------------------------------------------------------------------");
	$finish;
end endtask












endmodule








