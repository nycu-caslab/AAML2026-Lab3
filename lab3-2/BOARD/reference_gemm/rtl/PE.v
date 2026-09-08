module PE #(
    parameter DATA_WIDTH = 32,
    parameter PSUM_WIDTH = 32,
    parameter multiplication_cycle = 8
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  input_valid,
    input  wire                  clr_accum,

    input  wire [DATA_WIDTH-1:0] a_in,
    input  wire [DATA_WIDTH-1:0] b_in,

    output reg  [DATA_WIDTH-1:0] a_out,
    output reg  [DATA_WIDTH-1:0] b_out,
    output wire [PSUM_WIDTH-1:0] psum_out
);

    reg [PSUM_WIDTH-1:0] accum;

    assign psum_out = accum;

    wire        fma_a_ready;
    wire        fma_b_ready;
    wire        fma_c_ready;

    wire [31:0] fma_result;
    wire        fma_result_valid;

    wire        fma_input_ready;
    wire        fma_accept;

    wire [31:0] fma_c_data;

    assign fma_input_ready =
        fma_a_ready &&
        fma_b_ready &&
        fma_c_ready;

    assign fma_accept = input_valid && fma_input_ready;

    assign fma_c_data = accum;

    fp32_mult_add u_fp32_mult_add (
        .aclk                    (clk),

        .s_axis_a_tvalid         (input_valid), // we have data, input
        .s_axis_a_tready         (fma_a_ready), // PE can accept data, output
        .s_axis_a_tdata          (a_in),

        .s_axis_b_tvalid         (input_valid),
        .s_axis_b_tready         (fma_b_ready),
        .s_axis_b_tdata          (b_in),

        .s_axis_c_tvalid         (input_valid),
        .s_axis_c_tready         (fma_c_ready),
        .s_axis_c_tdata          (fma_c_data),

        .m_axis_result_tvalid    (fma_result_valid),
        .m_axis_result_tready    (1'b1),
        .m_axis_result_tdata     (fma_result)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= {DATA_WIDTH{1'b0}};
            b_out <= {DATA_WIDTH{1'b0}};
            accum <= {PSUM_WIDTH{1'b0}};
        end else begin
            // forward the data if fma accepts a new operation
            if (fma_accept) begin
                a_out <= a_in;
                b_out <= b_in;
            end

            if (clr_accum) begin
                accum <= {PSUM_WIDTH{1'b0}};
            end else if (fma_result_valid) begin
                accum <= fma_result;
            end
        end
    end

endmodule
