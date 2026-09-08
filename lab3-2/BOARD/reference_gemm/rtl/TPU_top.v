module TPU_top #(
    parameter memory_depth = 1024,
    parameter memory_bits = $clog2(memory_depth),
    parameter multiplication_cycle = 15,
    parameter bram_latency_cycle = 1,
    parameter PE_size = 4,
    parameter CLK_FREQ_HZ     = 50_000_000, // For Uart
    parameter UART_BAUD_RATE  = 115_200
)(
    // Arty A7-100T board signals
    input  wire       CLK100MHZ,
    input  wire       BTN_RESET,
    input  wire       BTN_START,
    
    // FTDI/PC TX -> FPGA RX
    input  wire       UART_TXD_IN,
    // FPGA TX -> FTDI/PC RX
    output wire       UART_RXD_OUT,
    
    output wire [3:0] LED
);

// Top-level state machine
localparam [2:0] S_IDLE      = 3'd0;
localparam [2:0] S_WAIT_UART = 3'd1;
localparam [2:0] S_RUN       = 3'd2;
localparam [2:0] S_SEND_UART = 3'd3;
localparam [2:0] S_DONE      = 3'd4;
localparam [2:0] S_CLEAR_C   = 3'd5;

localparam [31:0] BRAM_VALID_DELAY = (bram_latency_cycle > 0) ? (bram_latency_cycle - 1) : 0;
//
// Board signal aliases
//
wire clk;
wire rst_n;
wire start;
wire clk_50mhz; // lower the frequency
wire clk_locked;

clk_wiz_0 u_clk_wiz (
    .clk_in1  (CLK100MHZ),
    .reset    (~BTN_RESET),
    .clk_out1 (clk_50mhz),
    .locked   (clk_locked)
);

assign clk   = clk_50mhz;
assign rst_n = BTN_RESET & clk_locked;
assign start = BTN_START;

//
// UART internal signals
//

wire [7:0] uart_rx_data;
wire       uart_rx_valid;

wire [7:0] uart_tx_data;
wire       uart_tx_start;
wire       uart_tx_busy;

wire uart_load_done;
wire uart_config_valid;

//
// TPU status signals
//
wire       busy;
wire       tpu_rst_n;
reg        done;
reg [2:0] top_state;

//
// Connect TPU/check status to physical LEDs
//

assign LED[0] = done;
assign LED[1] = busy;
assign LED[2] = (top_state == S_WAIT_UART);
assign LED[3] = (top_state == S_RUN);

reg start_sync0;
reg start_sync1;
reg start_sync1_d;
reg in_valid;
reg busy_seen;

wire start_pulse;

/// K,M,N interface
reg [7:0] K_value;
reg [7:0] M_value;
reg [7:0] N_value;

wire [7:0] uart_K_value;
wire [7:0] uart_M_value;
wire [7:0] uart_N_value;
///

wire           A_wr_en;
wire [memory_bits-1:0]    A_index;
wire [127:0]   A_data_in;
wire [127:0]   A_data_out;

wire           B_wr_en;
wire [memory_bits-1:0]    B_index;
wire [127:0]   B_data_in;
wire [127:0]   B_data_out;

wire           C_wr_en;
wire [memory_bits-1:0]    C_index;
wire [127:0]   C_data_in;
wire [127:0]   C_data_out;

reg [memory_bits-1:0] clear_C_index;
reg                   clear_C_then_wait_uart;
wire                  clear_C_active;
wire                  bram_C_wr_en;
wire [memory_bits-1:0] bram_C_write_index;
wire [127:0]          bram_C_data_in;

// for BRAM data control
wire bram_data_enable;
reg [memory_bits-1:0] prev_A_idx;
reg [memory_bits-1:0] prev_B_idx;
reg [31:0] bram_read_latency_count;
wire bram_read_index_stable;

// Bram store the initial data
// read, 1 cycle latency
// write, the writed result be seen in the next cycle
// the address need to be adjusted if the matrix size is changed

//
// UART A/B BRAM write interface
//
wire                       uart_A_wr_en;
wire [memory_bits-1:0]     uart_A_index;
wire [127:0]               uart_A_data_in;

wire                       uart_B_wr_en;
wire [memory_bits-1:0]     uart_B_index;
wire [127:0]               uart_B_data_in;
//
// UART C BRAM read interface
//
wire [memory_bits-1:0] uart_C_index;
wire [127:0]           uart_C_data_out;


bram_A u_bram_A (
    .clka  (clk),
    .ena   (1'b1),
    .wea   (uart_A_wr_en),
    .addra (uart_A_index),
    .dina  (uart_A_data_in),

    .clkb  (clk),
    .enb   (1'b1),
    .addrb (A_index[memory_bits-1:0]),
    .doutb (A_data_out)
);

bram_B u_bram_B (
    // Port A: UART writes B
    .clka  (clk),
    .ena   (1'b1),
    .wea   (uart_B_wr_en),
    .addra (uart_B_index),
    .dina  (uart_B_data_in),

    // Port B: TPU reads B
    .clkb  (clk),
    .enb   (1'b1),
    .addrb (B_index),
    .doutb (B_data_out)
);

assign C_data_out = 128'd0;
assign clear_C_active = (top_state == S_CLEAR_C);
assign bram_C_wr_en = clear_C_active ? 1'b1 : C_wr_en;
assign bram_C_write_index = clear_C_active ? clear_C_index : C_index[memory_bits-1:0];
assign bram_C_data_in = clear_C_active ? 128'd0 : C_data_in;
assign tpu_rst_n = rst_n & ~clear_C_active;

bram_C u_bram_C (
    // Port A: TPU writes C
    .clka  (clk),
    .ena   (1'b1),
    .wea   (bram_C_wr_en),
    .addra (bram_C_write_index),
    .dina  (bram_C_data_in),

    // Port B: UART reads C
    .clkb  (clk),
    .enb   (1'b1),
    .addrb (uart_C_index),
    .doutb (uart_C_data_out)
);

// UART module
wire uart_load_enable;
wire uart_send_done;
wire uart_send_enable;

assign uart_load_enable = (top_state == S_WAIT_UART);
assign uart_send_enable = (top_state == S_SEND_UART);

uart_rx #(
    .CLK_FREQ  (CLK_FREQ_HZ),
    .BAUD_RATE (UART_BAUD_RATE)
) u_uart_rx (
    .clk       (clk),
    .rst_n     (rst_n),
    .rx        (UART_TXD_IN),
    .rx_data   (uart_rx_data),
    .rx_valid  (uart_rx_valid)
);

uart_tx #(
    .CLK_FREQ  (CLK_FREQ_HZ),
    .BAUD_RATE (UART_BAUD_RATE)
) u_uart_tx (
    .clk       (clk),
    .rst_n     (rst_n),
    .tx_data   (uart_tx_data),
    .tx_start  (uart_tx_start),
    .tx        (UART_RXD_OUT),
    .tx_busy   (uart_tx_busy)
);

uart_controller #(
    .memory_depth      (memory_depth),
    .memory_bits       (memory_bits),
    .BRAM_READ_LATENCY (bram_latency_cycle)
) u_uart_controller (
    .clk          (clk),
    .rst_n        (rst_n),

    // Controller operation
    .load_enable  (uart_load_enable),
    .tpu_done     (uart_send_enable),

    // UART RX
    .rx_data      (uart_rx_data),
    .rx_valid     (uart_rx_valid),

    // UART TX
    .tx_data      (uart_tx_data),
    .tx_start     (uart_tx_start),
    .tx_busy      (uart_tx_busy),

    // Configuration
    .K_value      (uart_K_value),
    .M_value      (uart_M_value),
    .N_value      (uart_N_value),
    .config_valid (uart_config_valid),
    .load_done    (uart_load_done),

    // BRAM A write
    .A_wr_en      (uart_A_wr_en),
    .A_index      (uart_A_index),
    .A_data_in    (uart_A_data_in),

    // BRAM B write
    .B_wr_en      (uart_B_wr_en),
    .B_index      (uart_B_index),
    .B_data_in    (uart_B_data_in),

    // BRAM C read
    .C_index      (uart_C_index),
    .C_data_out   (uart_C_data_out),

    // Transmission status
    .send_done    (uart_send_done)
);

// deal with the latency of bram
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        prev_A_idx <= 0;
        prev_B_idx <= 0;
        bram_read_latency_count <= 32'd0;
    end
    else begin
        if((prev_A_idx != A_index) || (prev_B_idx != B_index)) begin
            prev_A_idx <= A_index;
            prev_B_idx <= B_index;
            bram_read_latency_count <= 32'd0;
        end
        else if(bram_read_latency_count < BRAM_VALID_DELAY) begin
            bram_read_latency_count <= bram_read_latency_count + 1'b1;
        end
        else begin
            bram_read_latency_count <= bram_read_latency_count;
        end
    end
end
assign bram_read_index_stable = (prev_A_idx == A_index) && (prev_B_idx == B_index);
assign bram_data_enable = bram_read_index_stable && (bram_read_latency_count >= BRAM_VALID_DELAY);


assign start_pulse = start_sync1 & ~start_sync1_d;

//
// Synchronize the asynchronous push button and generate a pulse
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        start_sync0   <= 1'b0;
        start_sync1   <= 1'b0;
        start_sync1_d <= 1'b0;
    end else begin
        start_sync0   <= start;
        start_sync1   <= start_sync0;
        start_sync1_d <= start_sync1;
    end
end

//
// Store matrix configuration received through UART
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        K_value      <= 8'd0;
        M_value      <= 8'd0;
        N_value      <= 8'd0;
    end
    else if (uart_config_valid && !busy) begin
        K_value      <= uart_K_value;
        M_value      <= uart_M_value;
        N_value      <= uart_N_value;
    end
end

//
// Top-level controller
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        top_state <= S_IDLE;
        in_valid  <= 1'b0;
        busy_seen <= 1'b0;
        done      <= 1'b0;
        clear_C_index <= {memory_bits{1'b0}};
        clear_C_then_wait_uart <= 1'b0;
    end
    else begin
        // By default, in_valid is only asserted for one clock cycle.
        case (top_state)

            S_IDLE: begin
                done      <= 1'b0;
                busy_seen <= 1'b0;
                in_valid  <= 1'b0;
                clear_C_index <= {memory_bits{1'b0}};
                if (start_pulse) begin
                    clear_C_then_wait_uart <= 1'b1;
                    top_state <= S_CLEAR_C;
                end
            end
            S_WAIT_UART: begin
                done      <= 1'b0;
                busy_seen <= 1'b0;
                if (uart_load_done) begin
                    in_valid  <= 1'b1;
                    top_state <= S_RUN;
                end
                else begin
                    in_valid <= 1'b0;
                end
            end

            S_RUN: begin
                in_valid <= 1'b0;
                if (busy) begin
                    // TPU is running.
                    busy_seen <= 1'b1;
                    done      <= 1'b0;
                end
                else if (busy_seen) begin
                    // busy was previously high and is now low.
                    // Therefore, the TPU has finished.
                    busy_seen <= 1'b0;
                    done      <= 1'b0;
                    top_state <= S_SEND_UART;
                end
                else begin
                    // TPU has not asserted busy yet.
                    busy_seen <= 1'b0;
                    done      <= 1'b0;
                end
            end
            S_SEND_UART: begin
                in_valid  <= 1'b0;
                busy_seen <= 1'b0;      
                if (uart_send_done) begin
                    done      <= 1'b0;
                    clear_C_index <= {memory_bits{1'b0}};
                    clear_C_then_wait_uart <= 1'b0;
                    top_state <= S_CLEAR_C;
                end
                else begin
                    done      <= 1'b0;
                end
            end
            S_CLEAR_C: begin
                in_valid  <= 1'b0;
                done      <= 1'b0;
                busy_seen <= 1'b0;
                if (clear_C_index == (memory_depth - 1)) begin
                    clear_C_index <= {memory_bits{1'b0}};
                    if (clear_C_then_wait_uart) begin
                        clear_C_then_wait_uart <= 1'b0;
                        top_state <= S_WAIT_UART;
                    end
                    else begin
                        top_state <= S_DONE;
                    end
                end
                else begin
                    clear_C_index <= clear_C_index + 1'b1;
                end
            end
            S_DONE: begin
                in_valid  <= 1'b0;
                done      <= 1'b1;
                busy_seen <= 1'b0;
                // Allow another computation to start.
                if (start_pulse) begin
                    clear_C_then_wait_uart <= 1'b1;
                    clear_C_index <= {memory_bits{1'b0}};
                    top_state <= S_CLEAR_C;
                end
            end

            default: begin
                top_state <= S_IDLE;
                in_valid  <= 1'b0;
                busy_seen <= 1'b0;
                done      <= 1'b0;
                clear_C_then_wait_uart <= 1'b0;
            end

        endcase
    end
end
//
// TPU core
//
TPU #(
    .multiplication_cycle(multiplication_cycle),
    .memory_depth(memory_depth),
    .memory_bits(memory_bits),
    .bram_latency_cycle(bram_latency_cycle),
    .PE_size(PE_size)
)u_tpu(
    .clk        (clk),
    .rst_n      (tpu_rst_n),
    .in_valid   (in_valid),
    .bram_data_enable (bram_data_enable),
    .K          (K_value),
    .M          (M_value),
    .N          (N_value),
    .busy       (busy),

    .A_wr_en    (A_wr_en),
    .A_index    (A_index),
    .A_data_in  (A_data_in),
    .A_data_out (A_data_out),

    .B_wr_en    (B_wr_en),
    .B_index    (B_index),
    .B_data_in  (B_data_in),
    .B_data_out (B_data_out),

    .C_wr_en    (C_wr_en),
    .C_index    (C_index),
    .C_data_in  (C_data_in),
    .C_data_out (C_data_out)
);

endmodule
