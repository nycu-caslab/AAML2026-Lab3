module uart_controller #(
    parameter memory_depth = 1024,
    parameter memory_bits  = $clog2(memory_depth),
    parameter BRAM_READ_LATENCY = 1
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Controller operation
    input  wire                   load_enable,
    input  wire                   tpu_done,

    // UART RX
    input  wire [7:0]             rx_data,
    input  wire                   rx_valid,

    // UART TX
    output reg  [7:0]             tx_data,
    output reg                    tx_start,
    input  wire                   tx_busy,

    // Configuration
    output reg  [7:0]             K_value, // can be extended in the future 
    output reg  [7:0]             M_value,
    output reg  [7:0]             N_value,
    output reg                    config_valid,
    output reg                    load_done,

    // BRAM A write
    output reg                    A_wr_en,
    output reg [memory_bits-1:0]  A_index,
    output reg [127:0]            A_data_in,

    // BRAM B write
    output reg                    B_wr_en,
    output reg [memory_bits-1:0]  B_index,
    output reg [127:0]            B_data_in,

    // BRAM C read
    output reg [memory_bits-1:0]  C_index,
    input  wire [127:0]           C_data_out,

    // Transmission status
    output reg                    send_done
);

//
// UART RX state machine
//
localparam [2:0] RX_WAIT_ENABLE = 3'd0;
localparam [2:0] RX_GET_K       = 3'd1;
localparam [2:0] RX_GET_M       = 3'd2;
localparam [2:0] RX_GET_N       = 3'd3;
localparam [2:0] RX_GET_A       = 3'd4;
localparam [2:0] RX_GET_B       = 3'd5;
localparam [2:0] RX_WAIT_RELEASE = 3'd6;

reg [2:0] rx_state;

// Number of completed 128-bit words
reg [31:0] A_word_count;
reg [31:0] B_word_count;
reg [31:0] A_word_counter;
reg [31:0] B_word_counter;

// Receive one FP32 as four little-endian bytes
reg [31:0] fp32_buffer;
reg [1:0]  fp32_byte_count;

// Four FP32 values per BRAM word
reg [1:0]  fp32_lane_count;

//
// UART TX state machine
//
localparam [2:0] TX_IDLE       = 3'd0;
localparam [2:0] TX_WAIT_BRAM  = 3'd1;
localparam [2:0] TX_SEND_BYTE  = 3'd2;
localparam [2:0] TX_WAIT_BUSY  = 3'd3;
localparam [2:0] TX_WAIT_DONE  = 3'd4;

reg [2:0] tx_state;

reg [31:0] C_word_count;
reg [31:0] C_word_counter;
reg [31:0] bram_wait_counter;

reg [127:0] tx_word;
reg [3:0]   tx_byte_count;

reg tpu_done_d;

//
// Select one byte from the C BRAM word.
//
// Every FP32 is transmitted little-endian, but the four FP32
// lanes are transmitted in logical lane order:
//
// lane 0 = C_data_out[127:96]
// lane 1 = C_data_out[ 95:64]
// lane 2 = C_data_out[ 63:32]
// lane 3 = C_data_out[ 31: 0]
//
function [7:0] select_tx_byte;
    input [127:0] data_word;
    input [3:0]   byte_number;
    begin
        case (byte_number)
            // FP32 lane 0
            4'd0:  select_tx_byte = data_word[103:96];
            4'd1:  select_tx_byte = data_word[111:104];
            4'd2:  select_tx_byte = data_word[119:112];
            4'd3:  select_tx_byte = data_word[127:120];

            // FP32 lane 1
            4'd4:  select_tx_byte = data_word[71:64];
            4'd5:  select_tx_byte = data_word[79:72];
            4'd6:  select_tx_byte = data_word[87:80];
            4'd7:  select_tx_byte = data_word[95:88];

            // FP32 lane 2
            4'd8:  select_tx_byte = data_word[39:32];
            4'd9:  select_tx_byte = data_word[47:40];
            4'd10: select_tx_byte = data_word[55:48];
            4'd11: select_tx_byte = data_word[63:56];

            // FP32 lane 3
            4'd12: select_tx_byte = data_word[7:0];
            4'd13: select_tx_byte = data_word[15:8];
            4'd14: select_tx_byte = data_word[23:16];
            4'd15: select_tx_byte = data_word[31:24];

            default:
                select_tx_byte = 8'd0;
        endcase
    end
endfunction

//
// UART receive controller
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_state         <= RX_WAIT_ENABLE;

        K_value          <= 8'd0;
        M_value          <= 8'd0;
        N_value          <= 8'd0;

        config_valid     <= 1'b0;
        load_done        <= 1'b0;

        A_wr_en          <= 1'b0;
        A_index          <= {memory_bits{1'b0}};
        A_data_in        <= 128'd0;

        B_wr_en          <= 1'b0;
        B_index          <= {memory_bits{1'b0}};
        B_data_in        <= 128'd0;

        A_word_count     <= 32'd0;
        B_word_count     <= 32'd0;
        A_word_counter   <= 32'd0;
        B_word_counter   <= 32'd0;

        fp32_buffer      <= 32'd0;
        fp32_byte_count  <= 2'd0;
        fp32_lane_count  <= 2'd0;
    end
    else begin
        // Pulse-type outputs
        config_valid <= 1'b0;
        load_done    <= 1'b0;

        //
        // Dropping load_enable resets the receive protocol.
        // Previously written BRAM contents are not cleared, but the next
        // transfer starts again from address zero.
        //
        if (!load_enable) begin
            rx_state         <= RX_WAIT_ENABLE;

            A_wr_en          <= 1'b0;
            B_wr_en          <= 1'b0;

            A_index          <= {memory_bits{1'b0}};
            B_index          <= {memory_bits{1'b0}};

            A_word_counter   <= 32'd0;
            B_word_counter   <= 32'd0;

            fp32_buffer      <= 32'd0;
            fp32_byte_count  <= 2'd0;
            fp32_lane_count  <= 2'd0;
        end
        else begin
            case (rx_state)

                RX_WAIT_ENABLE: begin
                    A_wr_en         <= 1'b0;
                    B_wr_en         <= 1'b0;

                    A_index         <= {memory_bits{1'b0}};
                    B_index         <= {memory_bits{1'b0}};

                    A_data_in       <= 128'd0;
                    B_data_in       <= 128'd0;

                    A_word_counter  <= 32'd0;
                    B_word_counter  <= 32'd0;

                    fp32_buffer     <= 32'd0;
                    fp32_byte_count <= 2'd0;
                    fp32_lane_count <= 2'd0;

                    rx_state        <= RX_GET_K;
                end

                //
                // Packet begins with K, M and N in order.
                //
                RX_GET_K: begin
                    A_wr_en <= 1'b0;
                    B_wr_en <= 1'b0;

                    if (rx_valid) begin
                        K_value <= rx_data;
                        rx_state <= RX_GET_M;
                    end
                end

                RX_GET_M: begin
                    if (rx_valid) begin
                        M_value <= rx_data;
                        rx_state <= RX_GET_N;
                    end
                end

                RX_GET_N: begin
                    if (rx_valid) begin
                        N_value      <= rx_data;
                        config_valid <= 1'b1;
                        
                        // set the condition of the data to be read next

                        //
                        // A_word_count = ceil(M / 4) * K
                        //
                        A_word_count <=
                            ((({24'd0, M_value} + 32'd3) >> 2) *
                              {24'd0, K_value});

                        //
                        // B_word_count = ceil(N / 4) * K
                        //
                        B_word_count <=
                            ((({24'd0, rx_data} + 32'd3) >> 2) *
                              {24'd0, K_value});

                        A_index         <= {memory_bits{1'b0}};
                        A_word_counter  <= 32'd0;
                        A_data_in       <= 128'd0;

                        fp32_buffer     <= 32'd0;
                        fp32_byte_count <= 2'd0;
                        fp32_lane_count <= 2'd0;

                        rx_state <= RX_GET_A;
                    end
                end

                //
                // Receive matrix A.
                //
                RX_GET_A: begin
                    B_wr_en <= 1'b0;

                    //
                    // A_wr_en was asserted during the previous cycle.
                    // At this edge the BRAM performs the actual write.
                    //
                    if (A_wr_en) begin // finish writing the previous word
                        A_wr_en <= 1'b0;

                        if ((A_word_counter + 32'd1) >= A_word_count) begin // finish reading the A matrix data, start to read B matrix data
                            B_index         <= {memory_bits{1'b0}};
                            B_word_counter  <= 32'd0;
                            B_data_in       <= 128'd0;

                            fp32_buffer     <= 32'd0;
                            fp32_byte_count <= 2'd0;
                            fp32_lane_count <= 2'd0;

                            rx_state <= RX_GET_B;
                        end
                        else begin
                            A_word_counter <= A_word_counter + 32'd1;
                            A_index        <= A_index + 1'b1;
                            A_data_in      <= 128'd0;
                        end
                    end
                    else if (rx_valid) begin
                        case (fp32_byte_count)
                            2'd0: begin
                                fp32_buffer[7:0] <= rx_data;
                                fp32_byte_count  <= 2'd1;
                            end

                            2'd1: begin
                                fp32_buffer[15:8] <= rx_data;
                                fp32_byte_count   <= 2'd2;
                            end

                            2'd2: begin
                                fp32_buffer[23:16] <= rx_data;
                                fp32_byte_count    <= 2'd3;
                            end

                            2'd3: begin
                                fp32_byte_count <= 2'd0;

                                case (fp32_lane_count)
                                    2'd0: begin
                                        A_data_in[127:96] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd1;
                                    end

                                    2'd1: begin
                                        A_data_in[95:64] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd2;
                                    end

                                    2'd2: begin
                                        A_data_in[63:32] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd3;
                                    end

                                    2'd3: begin
                                        A_data_in[31:0] <=
                                            {rx_data, fp32_buffer[23:0]};

                                        fp32_lane_count <= 2'd0;
                                        A_wr_en         <= 1'b1;
                                    end
                                endcase
                            end
                        endcase
                    end
                end

                //
                // Receive matrix B.
                //
                RX_GET_B: begin
                    A_wr_en <= 1'b0;

                    //
                    // B_wr_en was asserted during the previous cycle.
                    // At this edge the BRAM performs the write.
                    //
                    if (B_wr_en) begin
                        B_wr_en <= 1'b0;

                        if ((B_word_counter + 32'd1) >= B_word_count) begin
                            load_done <= 1'b1;
                            rx_state  <= RX_WAIT_RELEASE;
                        end
                        else begin
                            B_word_counter <= B_word_counter + 32'd1;
                            B_index        <= B_index + 1'b1;
                            B_data_in      <= 128'd0;
                        end
                    end
                    else if (rx_valid) begin
                        case (fp32_byte_count) // one time of rx valid brings one byte, so we need four times to build a word 
                            2'd0: begin
                                fp32_buffer[7:0] <= rx_data;
                                fp32_byte_count  <= 2'd1;
                            end

                            2'd1: begin
                                fp32_buffer[15:8] <= rx_data;
                                fp32_byte_count   <= 2'd2;
                            end

                            2'd2: begin
                                fp32_buffer[23:16] <= rx_data;
                                fp32_byte_count    <= 2'd3;
                            end

                            2'd3: begin
                                fp32_byte_count <= 2'd0;

                                case (fp32_lane_count) // the target is 4 bytes send to the bram simultaneously
                                    2'd0: begin
                                        B_data_in[127:96] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd1;
                                    end

                                    2'd1: begin
                                        B_data_in[95:64] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd2;
                                    end

                                    2'd2: begin
                                        B_data_in[63:32] <=
                                            {rx_data, fp32_buffer[23:0]};
                                        fp32_lane_count <= 2'd3;
                                    end

                                    2'd3: begin
                                        B_data_in[31:0] <=
                                            {rx_data, fp32_buffer[23:0]};

                                        fp32_lane_count <= 2'd0;
                                        B_wr_en         <= 1'b1;
                                    end
                                endcase
                            end
                        endcase
                    end
                end

                //
                // Prevent load_done from repeatedly asserting while
                // load_enable remains high.
                //
                RX_WAIT_RELEASE: begin
                    A_wr_en <= 1'b0;
                    B_wr_en <= 1'b0;

                    if (!load_enable)
                        rx_state <= RX_WAIT_ENABLE;
                end

                default: begin
                    rx_state <= RX_WAIT_ENABLE;
                    A_wr_en  <= 1'b0;
                    B_wr_en  <= 1'b0;
                end
            endcase
        end
    end
end

//
// UART transmission controller
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state          <= TX_IDLE;

        tx_data           <= 8'd0;
        tx_start          <= 1'b0;
        send_done         <= 1'b0;

        C_index           <= {memory_bits{1'b0}};
        C_word_count      <= 32'd0;
        C_word_counter    <= 32'd0;

        bram_wait_counter <= 32'd0;
        tx_word           <= 128'd0;
        tx_byte_count     <= 4'd0;

        tpu_done_d        <= 1'b0;
    end
    else begin
        tpu_done_d <= tpu_done;

        // Pulse-type outputs
        tx_start  <= 1'b0;
        send_done <= 1'b0;

        case (tx_state)

            TX_IDLE: begin
                tx_byte_count     <= 4'd0;
                C_word_counter    <= 32'd0;
                bram_wait_counter <= 32'd0;

                //
                // Start only on the rising edge of tpu_done.
                //
                if (tpu_done && !tpu_done_d) begin
                    C_index <= {memory_bits{1'b0}};

                    //
                    // C_word_count = ceil(N / 4) * M
                    //
                    C_word_count <=
                        ((({24'd0, N_value} + 32'd3) >> 2) *
                          {24'd0, M_value});

                    if ((M_value == 8'd0) || (N_value == 8'd0)) begin // the special case, do not send any bit
                        send_done <= 1'b1;
                    end
                    else begin
                        tx_state <= TX_WAIT_BRAM;
                    end
                end
            end

            //
            // C_index was changed before entering this state.
            // Wait for the synchronous BRAM output.
            //
            TX_WAIT_BRAM: begin
                if (bram_wait_counter < BRAM_READ_LATENCY) begin
                    bram_wait_counter <= bram_wait_counter + 32'd1;
                end
                else begin // the data can be read from BRAM
                    tx_word           <= C_data_out;
                    tx_byte_count     <= 4'd0;
                    bram_wait_counter <= 32'd0;
                    tx_state          <= TX_SEND_BYTE;
                end
            end

            //
            // Submit one byte to uart_tx.
            //
            TX_SEND_BYTE: begin
                if (!tx_busy) begin
                    tx_data  <= select_tx_byte(tx_word, tx_byte_count);
                    tx_start <= 1'b1;
                    tx_state <= TX_WAIT_BUSY;
                end
            end

            //
            // Wait until uart_tx accepts tx_start and raises tx_busy.
            //
            TX_WAIT_BUSY: begin
                if (tx_busy)
                    tx_state <= TX_WAIT_DONE;
            end

            //
            // Wait until transmission of the current byte finishes.
            //
            TX_WAIT_DONE: begin
                if (!tx_busy) begin
                    if (tx_byte_count == 4'd15) begin
                        if ((C_word_counter + 32'd1) >= C_word_count) begin // finish sending the C matrix data
                            send_done <= 1'b1;
                            tx_state  <= TX_IDLE;
                        end
                        else begin
                            C_word_counter    <= C_word_counter + 32'd1;
                            C_index           <= C_index + 1'b1;
                            tx_byte_count     <= 4'd0;
                            bram_wait_counter <= 32'd0;
                            tx_state          <= TX_WAIT_BRAM; // wait bram to read another data 
                        end
                    end
                    else begin
                        tx_byte_count <= tx_byte_count + 1'b1;
                        tx_state      <= TX_SEND_BYTE; // keep sending bytes, until 16 bytes
                    end
                end
            end

            default: begin
                tx_state  <= TX_IDLE;
                tx_start  <= 1'b0;
                send_done <= 1'b0;
            end
        endcase
    end
end

endmodule