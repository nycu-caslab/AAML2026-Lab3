`timescale 1ns/10ps
//============================================================================//
// AIC2021 Project1 - TPU Design                                              //
// file: global_buffer.v                                                      //
// description: global buffer read write behavior module                      //
// authors: kaikai (deekai9139@gmail.com)                                     //
//          suhan  (jjs93126@gmail.com)                                       //
//============================================================================//
module global_buffer #(parameter ADDR_BITS=8, parameter DATA_BITS=8)(clk, rst_n, wr_en, rd_en, index, data_in, data_out);

  input clk;
  input rst_n;
  input wr_en;
  input rd_en;
  input      [ADDR_BITS-1:0] index;
  input      [DATA_BITS-1:0]       data_in;
  output reg [DATA_BITS-1:0]       data_out;

  integer i;

  parameter DEPTH = 2**ADDR_BITS;

  reg [DATA_BITS-1:0] gbuff [DEPTH-1:0];

  always @ (negedge clk or negedge rst_n) begin
    if(!rst_n)begin
      for(i=0; i<(DEPTH); i=i+1)
        gbuff[i] <= 'd0;
    end
    else begin
      if(wr_en) begin
        gbuff[index] <= data_in;
      end
      else if(rd_en) begin
        data_out <= gbuff[index];
      end
    end
  end

endmodule


module input_buffer #(parameter ADDR_BITS=16)(clk, rst_n, rd_en, index, data_out);

  input clk;
  input rst_n;
  input rd_en;
  input [ADDR_BITS-1:0] index;
  output reg [31:0] data_out;

  integer i;
  parameter DEPTH = 2**ADDR_BITS;
  reg [7:0] gbuff [DEPTH-1:0];

  always @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (i=0; i<DEPTH; i=i+1)
        gbuff[i] <= 8'd0;
      data_out <= 32'd0;
    end else if (rd_en) begin
      data_out <= {gbuff[index], gbuff[index + 1], gbuff[index + 2], gbuff[index + 3]};
    end
  end

endmodule
