`timescale 1ns/10ps

module TPU(
    input              clk,
    input              rst_n,
    input              in_valid,
    input      [7:0]   M,
    input      [7:0]   N,
    output reg         busy,

    output             A_rd_en,
    output     [15:0]  A_index,
    input      [31:0]  A_data_out,

    output             B_rd_en,
    output     [15:0]  B_index,
    input      [31:0]  B_data_out,

    output             C_wr_en,
    output     [15:0]  C_index,
    output     [127:0] C_data_in,
    input      [127:0] C_data_out
);

// implement your TPU design here

endmodule
