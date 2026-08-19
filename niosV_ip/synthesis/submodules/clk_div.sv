// (C) 2001-2025 Altera Corporation. All rights reserved.
// Your use of Altera Corporation's design tools, logic functions and other 
// software and tools, and its AMPP partner logic functions, and any output 
// files from any of the foregoing (including device programming or simulation 
// files), and any associated documentation or information are expressly subject 
// to the terms and conditions of the Altera Program License Subscription 
// Agreement, Altera IP License Agreement, or other applicable 
// license agreement, including, without limitation, that your use is for the 
// sole purpose of programming logic devices manufactured by Altera and sold by 
// Altera or its authorized distributors.  Please refer to the applicable 
// agreement for further details.



`timescale 1 ns / 1 ns

module clk_div 
#( 
    parameter WIDTH = 5, // Width of the register required
    parameter N     = 6  // We will divide by 12 for example in this case
)
(
    input        clk,
    input        reset,
    input [4:0]  divisor,
    input        pol,
    input        enable,
    output logic clk_out,
    output logic falling_edge_trigger,
    output logic rising_edge,
    output logic falling_edge
); 
    logic [WIDTH-1:0] cnt_reg;
    logic [WIDTH-1:0] cnt_nxt;
    logic             clk_track;
    logic             cnt_equal;
    logic             clk_track_d;
    logic             enable_d;
    assign cnt_equal  = (cnt_nxt == divisor);
    
    always @(posedge clk or posedge reset)  begin
        if (reset) begin
            cnt_reg   <= '0;
            clk_track <= pol;
        end
        else if (enable) begin
            if (cnt_equal) begin
                cnt_reg   <= '0;
                clk_track <= ~clk_track;
            end
            else 
                cnt_reg <= cnt_nxt;
        end
        else begin
            //cnt_reg   <= '0;
            cnt_reg   <= divisor - 5'h1;
            clk_track <= pol;
        end
    end // always @ (posedge clk or posedge reset)

    // Edges detection
    always @(posedge clk or posedge reset)  begin
        if (reset) begin
            clk_track_d <= 0;
            enable_d <= '0;
        end
        else begin
            clk_track_d <= clk_track;
            enable_d <= enable;
        end
    end
    logic rising_edge_wire;         
    logic falling_edge_wire;        
    logic falling_edge_trigger_wire;
    logic clk_out_wire;

    always_comb begin
        rising_edge           = ~clk_track_d & clk_track;
        falling_edge          = clk_track_d & ~clk_track;
        falling_edge_trigger  = enable_d ? (clk_track & cnt_equal) : 1'b0;
    end
    assign cnt_nxt = cnt_reg + 1'b1;
    //assign clk_out_wire = enable ? clk_track : pol;
    assign clk_out = enable ? clk_track : pol;
    //assign clk_out = clk_track;
/*
    always_ff @(posedge clk) begin
        clk_out  <= clk_out_wire;
        rising_edge         <= rising_edge_wire;
        falling_edge           <= falling_edge_wire;
        falling_edge_trigger    <=falling_edge_trigger_wire;
    end
*/
endmodule