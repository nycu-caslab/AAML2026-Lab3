module TPU #(
    parameter multiplication_cycle = 15,
    parameter memory_depth = 1024,
    parameter memory_bits = $clog2(memory_depth),
    parameter bram_latency_cycle = 1,
    parameter PE_size = 4
)(
    clk,
    rst_n,

    in_valid,
    bram_data_enable,
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


input clk;
input rst_n;
input            in_valid;
input            bram_data_enable;
input [7:0]      K;
input [7:0]      M;
input [7:0]      N;
output  reg      busy; // busy means that the TPU is processing, data shouldn't come in

output           A_wr_en;
output [memory_bits-1:0]    A_index; // this generate the index we want and take the data from A buffer
output [127:0]   A_data_in;
input  [127:0]   A_data_out;

output           B_wr_en;
output [memory_bits-1:0]    B_index; // this generate the index we want and take the data from B buffer
output [127:0]   B_data_in;
input  [127:0]   B_data_out;

output           C_wr_en;
output [memory_bits-1:0]    C_index; // this generate the index we want and put the data to C buffer
output [127:0]   C_data_in;
input  [127:0]   C_data_out;

// state in the TPU
// read_state and control signal
(* mark_debug = "true" *) reg [2:0] read_state;
localparam WRITE_RESULT_COUNT_BITS = (PE_size <= 1) ? 1 : $clog2(PE_size);
reg [WRITE_RESULT_COUNT_BITS-1:0] write_result_count;
wire valid_c_row;
wire write_result_last;

// computation_state and control signal
reg [2:0] computation_state;
reg [9:0] computation_count; // count the number of computation, waiting for K+6 cycles

// stall for vivado IP computation cycle
reg [3:0] computation_stall_cycle;
wire issue_cycle;
wire bram_data_ready;
wire doing_computation;
wire waiting_for_bram_data;
wire bram_data_fire;
wire array_step_fire;

// store KMN value
reg [7:0] K_reg;
reg [7:0] M_reg;
reg [7:0] N_reg;

// store the current M,N computation index, reading from A and B buffer, and write to C buffer
reg [7:0] K_idx;
(* mark_debug = "true" *)reg [7:0] M_idx; 
(* mark_debug = "true" *)reg [7:0] N_idx;

// store temporary value of A,B for output stationary dataflow
wire [127:0] A_exe_data;
wire [127:0] B_exe_data;
reg [31:0] A_temp1;
reg [31:0] A_temp2[1:0];
reg [31:0] A_temp3[2:0];
reg [31:0] B_temp1;
reg [31:0] B_temp2[1:0];
reg [31:0] B_temp3[2:0];


parameter IDLE = 3'b000, READ_AB = 3'b001, Finish_reading = 3'b010,Wait_Writing = 3'b011;
parameter do_computation = 3'b001, finish_computation = 3'b010;

assign issue_cycle = (computation_stall_cycle == 1);
assign bram_data_ready = (read_state == READ_AB) && bram_data_enable;
assign doing_computation = (read_state != READ_AB) && (computation_state == do_computation);
assign waiting_for_bram_data = (read_state == READ_AB) && !bram_data_enable;
assign bram_data_fire = issue_cycle && bram_data_ready; // consume one A/B word from BRAM
assign array_step_fire = issue_cycle && (bram_data_ready || doing_computation); // advance the systolic array
assign write_result_last = (write_result_count == (PE_size - 1));


//* Implement your design here
// finish 4 x 4 systolic array, try to generates 16 element for matrix C in one time.

// control the read write state machine
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        read_state <= IDLE;
        K_reg <= 8'b0;
        M_reg <= 8'b0;
        N_reg <= 8'b0;
        M_idx <= 0;
        N_idx <= 0;
        K_idx <= 0;
        write_result_count <= {WRITE_RESULT_COUNT_BITS{1'b0}};
    end
    else begin
        case(read_state)
            IDLE: begin
                if(in_valid) begin
                    K_reg <= K;
                    M_reg <= M;
                    N_reg <= N;
                    read_state <= READ_AB; // do not need cycle for reading KMN
                end
                else begin // reset KMN
                    K_reg <= 8'b0;
                    M_reg <= 8'b0;
                    N_reg <= 8'b0;
                    read_state <= read_state; // stay in IDLE
                end
            end
            READ_AB: begin
                if(bram_data_fire) begin // only when PE accepts valid BRAM data, the K idx advances
                    if(K_idx+1 == K_reg) begin
                        read_state <= Finish_reading;
                        K_idx <= 0;
                    end
                    else begin
                        read_state <= read_state; // stay in READ_AB
                        K_idx <= K_idx+1;
                    end
                end
                else begin
                    read_state <= read_state; // stay in READ_AB
                    K_idx <= K_idx;
                end
            end
            Finish_reading: begin
                if(computation_state == finish_computation)begin
                    read_state <= Wait_Writing;
                end
                else begin
                    read_state <= read_state; // stay in Finish_reading
                end
            end
            Wait_Writing: begin // start to write the C buffer, wait 4 cycle
                if(write_result_last) begin
                    write_result_count <= {WRITE_RESULT_COUNT_BITS{1'b0}}; // reset to 0
                    // update the M_idx and N_idx, but only one can be updated
                    if(N_idx+4 < N_reg) begin // go right first, then down
                        read_state <= READ_AB;
                        N_idx <= N_idx+4;
                    end
                    else if(M_idx+4 < M_reg) begin // go down
                        read_state <= READ_AB;
                        M_idx <= M_idx+4;
                        N_idx <= 0;
                    end
                    else begin
                        // no space to continue computation
                        read_state <= IDLE; // finish the whole computation
                        M_idx <= 0;
                        N_idx <= 0;
                    end
                end
                else begin
                    read_state <= read_state; // stay in Wait_Writing
                    write_result_count <= write_result_count + 1;
                end
            end
        endcase
    end
end


// control the computation state machine
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        computation_state <= IDLE;
        computation_count <= 0;
    end
    else begin
        case(computation_state)
            IDLE: begin
                if(read_state == READ_AB)begin
                    computation_state <= do_computation;
                end
                else begin
                    computation_state <= computation_state; // stay in IDLE
                end
            end
            do_computation: begin
                if(array_step_fire) begin
                    if(computation_count == (K_reg + 2 * (PE_size - 1))) begin
                        computation_state <= finish_computation;
                        computation_count <= 0; // reset the computation_count
                    end
                    else begin
                        computation_state <= computation_state; // stay in do_computation
                        computation_count <= computation_count + 1;
                    end
                end
                else begin
                    computation_state <= computation_state; // stay in do_computation
                    computation_count <= computation_count;
                end
            end
            finish_computation: begin
                if(read_state == READ_AB) begin // wait for 4 cycles to write the result to C buffer
                    computation_state <= do_computation;
                end
                else begin
                    computation_state <= computation_state; // stay in finish_computation
                end
            end
        endcase
    end
end

// control busy signal
always @(posedge clk or negedge rst_n) begin
   if(!rst_n)begin
        busy <= 1'b0;
    end
    else begin
        if(M_idx+4 >= M_reg && N_idx+4 >= N_reg && read_state == Wait_Writing && write_result_last)begin // only off after the final C row is written
            busy <= 1'b0;
        end
        else if(read_state == IDLE && in_valid)begin
            busy <= 1'b1;
        end
        else begin
            busy <= busy; // stay in the current state
        end
    end
end

// enable signal
assign valid_c_row = (M_idx + write_result_count) < M_reg;
assign A_wr_en = 1'b0; // do not enable writing value to matrix A
assign B_wr_en = 1'b0;
assign C_wr_en = ((read_state == Wait_Writing) && valid_c_row) ? 1'b1 : 1'b0;

// unuseful for A and B buffer, read only
assign A_data_in = 128'd0;
assign B_data_in = 128'd0;
 
///////// control the computation cycle delay caused by Fp32 multiplication
reg start_count; // used to detect if stall cycle can start to compute
always @(posedge clk or negedge rst_n) begin // store K, M, N
    if(!rst_n) begin
       computation_stall_cycle <= 0;
       start_count <= 0;
    end
    else begin
        if(computation_state == finish_computation)begin // the computation has finished, and the stall cycle and count has to be reset
            start_count <= 0;
            computation_stall_cycle <= 0;
        end
        else if(read_state == READ_AB || computation_state == do_computation)begin
            start_count <= 1;

            if(issue_cycle && waiting_for_bram_data) begin // wait for BRAM read latency
                computation_stall_cycle <= computation_stall_cycle;
            end
            else if(start_count) begin
                if(computation_stall_cycle == multiplication_cycle)begin 
                    computation_stall_cycle <= 0;
                end
                else begin
                    computation_stall_cycle <= computation_stall_cycle+1;
                end
            end
            else begin
                computation_stall_cycle <= computation_stall_cycle + 1;
            end
        end
        else begin
            start_count <= start_count;
            computation_stall_cycle <= computation_stall_cycle;
        end
    end
end


// compute the index
// this need to be changed if the pe size changed, M_idx >> n^(1/2), n = pe_size
assign A_index = (read_state == READ_AB) ? ((M_idx >> 2) * K_reg + K_idx) : {memory_bits{1'b0}};
assign B_index = (read_state == READ_AB) ? ((N_idx >> 2) * K_reg + K_idx) : {memory_bits{1'b0}};
assign C_index = (read_state == Wait_Writing)
               ? (((N_idx >> 2) * M_reg) + M_idx + write_result_count)
               : {memory_bits{1'b0}}; // for C writing, it goes from top to down to write for 4*4 elements
               // it will be accessed for four elements in one time (in one row)
               // and go from top to down for four rows
               /*
                C_index 0 = row 0, columns 0~3
                C_index 1 = row 1, columns 0~3
                C_index 2 = row 2, columns 0~3 ...
                so we use (write_result_count +1) to represent go down in this execution 
               */

// use another wire to store the input data, and analysis the input data is valid or not
assign A_exe_data = bram_data_ready ? A_data_out : 128'b0;
assign B_exe_data = bram_data_ready ? B_data_out : 128'b0;

// storage system, the real data for computation is at PE unit.
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        // for A , data from top
        A_temp1 <= 32'b0;
        A_temp2[0] <= 32'b0;
        A_temp2[1] <= 32'b0;
        A_temp3[0] <= 32'b0;
        A_temp3[1] <= 32'b0;
        A_temp3[2] <= 32'b0;
        // for B, data from left
        B_temp1 <= 32'b0;
        B_temp2[0] <= 32'b0;
        B_temp2[1] <= 32'b0;
        B_temp3[0] <= 32'b0;
        B_temp3[1] <= 32'b0;
        B_temp3[2] <= 32'b0;
        end
        else begin // the data can be transferred to the next section
        if(read_state == READ_AB || computation_state == do_computation)begin 
            if(array_step_fire) begin
                // although the read is finish, the computation is still executing.
                // new data
                A_temp1 <= A_exe_data[95:64];
                A_temp2[1] <= A_exe_data[63:32];
                A_temp3[2] <= A_exe_data[31:0];
                B_temp1 <= B_exe_data[95:64];
                B_temp2[1] <= B_exe_data[63:32];
                B_temp3[2] <= B_exe_data[31:0];
                // old data transfer flow
                A_temp2[0] <= A_temp2[1];
                A_temp3[0] <= A_temp3[1];
                A_temp3[1] <= A_temp3[2];
                B_temp2[0] <= B_temp2[1];
                B_temp3[0] <= B_temp3[1];
                B_temp3[1] <= B_temp3[2];
            end
            else begin
                A_temp1 <= A_temp1;
                A_temp2[0] <= A_temp2[0];
                A_temp2[1] <= A_temp2[1];
                A_temp3[0] <= A_temp3[0];
                A_temp3[1] <= A_temp3[1];
                A_temp3[2] <= A_temp3[2];
                B_temp1 <= B_temp1;
                B_temp2[0] <= B_temp2[0];
                B_temp2[1] <= B_temp2[1];
                B_temp3[0] <= B_temp3[0];
                B_temp3[1] <= B_temp3[1];
                B_temp3[2] <= B_temp3[2];
            end
        end
        else begin
            // for A , data from top
            A_temp1 <= 32'b0;
            A_temp2[0] <= 32'b0;
            A_temp2[1] <= 32'b0;
            A_temp3[0] <= 32'b0;
            A_temp3[1] <= 32'b0;
            A_temp3[2] <= 32'b0;
            // for B, data from left
            B_temp1 <= 32'b0;
            B_temp2[0] <= 32'b0;
            B_temp2[1] <= 32'b0;
            B_temp3[0] <= 32'b0;
            B_temp3[1] <= 32'b0;
            B_temp3[2] <= 32'b0;
        end
    end
end

//////////////////PE logic////////////////////////
wire pe_clr_accum;
assign pe_clr_accum = (write_result_last && read_state == Wait_Writing);

// left to right
wire [31:0] P00_to_01, P01_to_02, P02_to_03, P03_to_right;
wire [31:0] P10_to_11, P11_to_12, P12_to_13, P13_to_right;
wire [31:0] P20_to_21, P21_to_22, P22_to_23, P23_to_right;
wire [31:0] P30_to_31, P31_to_32, P32_to_33, P33_to_right;

// up to down
wire [31:0] P00_to_10, P10_to_20, P20_to_30, P30_to_down;
wire [31:0] P01_to_11, P11_to_21, P21_to_31, P31_to_down;
wire [31:0] P02_to_12, P12_to_22, P22_to_32, P32_to_down;
wire [31:0] P03_to_13, P13_to_23, P23_to_33, P33_to_down;

wire [31:0] psum00, psum01, psum02, psum03;
wire [31:0] psum10, psum11, psum12, psum13;
wire [31:0] psum20, psum21, psum22, psum23;
wire [31:0] psum30, psum31, psum32, psum33;

assign C_data_in = (write_result_count == 3'd0) ? {psum00, psum01, psum02, psum03} :
                   (write_result_count == 3'd1) ? {psum10, psum11, psum12, psum13} :
                   (write_result_count == 3'd2) ? {psum20, psum21, psum22, psum23} :
                                                   {psum30, psum31, psum32, psum33};

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE00(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(A_exe_data[127:96]),
    .b_in(B_exe_data[127:96]),
    .a_out(P00_to_01),
    .b_out(P00_to_10),
    .psum_out(psum00)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE01(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P00_to_01),
    .b_in(B_temp1),
    .a_out(P01_to_02),
    .b_out(P01_to_11),
    .psum_out(psum01)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE02(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P01_to_02),
    .b_in(B_temp2[0]),
    .a_out(P02_to_03),
    .b_out(P02_to_12),
    .psum_out(psum02)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE03(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P02_to_03),
    .b_in(B_temp3[0]),
    .a_out(P03_to_right),
    .b_out(P03_to_13),
    .psum_out(psum03)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE10(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(A_temp1),
    .b_in(P00_to_10),
    .a_out(P10_to_11),
    .b_out(P10_to_20),
    .psum_out(psum10)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE11(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P10_to_11),
    .b_in(P01_to_11),
    .a_out(P11_to_12),
    .b_out(P11_to_21),
    .psum_out(psum11)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE12(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P11_to_12),
    .b_in(P02_to_12),
    .a_out(P12_to_13),
    .b_out(P12_to_22),
    .psum_out(psum12)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE13(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P12_to_13),
    .b_in(P03_to_13),
    .a_out(P13_to_right),
    .b_out(P13_to_23),
    .psum_out(psum13)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE20(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(A_temp2[0]),
    .b_in(P10_to_20),
    .a_out(P20_to_21),
    .b_out(P20_to_30),
    .psum_out(psum20)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE21(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P20_to_21),
    .b_in(P11_to_21),
    .a_out(P21_to_22),
    .b_out(P21_to_31),
    .psum_out(psum21)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE22(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P21_to_22),
    .b_in(P12_to_22),
    .a_out(P22_to_23),
    .b_out(P22_to_32),
    .psum_out(psum22)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE23(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P22_to_23),
    .b_in(P13_to_23),
    .a_out(P23_to_right),
    .b_out(P23_to_33),
    .psum_out(psum23)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE30(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(A_temp3[0]),
    .b_in(P20_to_30),
    .a_out(P30_to_31),
    .b_out(P30_to_down),
    .psum_out(psum30)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE31(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P30_to_31),
    .b_in(P21_to_31),
    .a_out(P31_to_32),
    .b_out(P31_to_down),
    .psum_out(psum31)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE32(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P31_to_32),
    .b_in(P22_to_32),
    .a_out(P32_to_33),
    .b_out(P32_to_down),
    .psum_out(psum32)
);

PE #(
    .multiplication_cycle(multiplication_cycle)
) PE33(
    .clk(clk),
    .rst_n(rst_n),
    .input_valid(array_step_fire),
    .clr_accum(pe_clr_accum),
    .a_in(P32_to_33),
    .b_in(P23_to_33),
    .a_out(P33_to_right),
    .b_out(P33_to_down),
    .psum_out(psum33)
);


endmodule
