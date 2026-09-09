// Reference interface for a signed INT8 PE. You can change it.
module PE (
    input wire clk,
    input wire rst_n,
    input wire input_valid,
    input wire clr_accum,
    input wire signed [7:0] a_in,
    input wire signed [7:0] b_in,
    output reg signed [7:0] a_out,
    output reg signed [7:0] b_out,
    output reg signed [31:0] psum_out
);

// Implement your PE design here.

endmodule
