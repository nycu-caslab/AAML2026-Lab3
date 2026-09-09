module TPU #(
    parameter A_WIDTH = 8,
    parameter B_WIDTH = 8,
    parameter PSUM_WIDTH = 32
)(
    input                         clk,
    input                         rst_n,

    // A one-cycle pulse on in_valid starts a new GEMV operation.
    input                         in_valid,
    input      [7:0]              K,
    input      [7:0]              M,
    input      [7:0]              N,
    output reg                    busy,

    // Matrix A BRAM interface: four packed INT8 values per word.
    output                        A_ram_en,
    output                        A_wr_en,
    output     [15:0]             A_index,
    output     [A_WIDTH*4-1:0]    A_data_in,
    input      [A_WIDTH*4-1:0]    A_data_out,

    // Matrix B BRAM interface: four packed INT8 values per word.
    output                        B_ram_en,
    output                        B_wr_en,
    output     [15:0]             B_index,
    output     [B_WIDTH*4-1:0]    B_data_in,
    input      [B_WIDTH*4-1:0]    B_data_out,

    // Matrix C BRAM interface: four packed INT32 values per word.
    output                        C_ram_en,
    output                        C_wr_en,
    output     [15:0]             C_index,
    output     [127:0]            C_data_in,
    input      [127:0]            C_data_out
);

// Implement your TPU design here.

endmodule
