module TPU #(
    parameter A_WIDTH = 4,
    parameter B_WIDTH = 8,
    parameter PSUM_WIDTH = 32
)(
    input                  clk,
    input                  rst_n,

    input                  in_valid,
    input      [7:0]       K,
    input      [7:0]       M,
    input      [7:0]       N,
    output reg             busy,

    output                 A_wr_en,
    output     [15:0]      A_index,
    output     [A_WIDTH*4-1:0] A_data_in,
    input      [A_WIDTH*4-1:0] A_data_out,

    output                 B_wr_en,
    output     [15:0]      B_index,
    output     [B_WIDTH*4-1:0] B_data_in,
    input      [B_WIDTH*4-1:0] B_data_out,

    output                 C_wr_en,
    output     [15:0]      C_index,
    output     [127:0]     C_data_in,
    input      [127:0]     C_data_out
);

// implement your TPU design here

endmodule
