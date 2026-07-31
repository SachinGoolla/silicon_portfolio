`timescale 1ns/1ps

module sigma_delta_rnm (
    input  logic clk,
    input  logic rst_n,
    input  real  v_in,       
    input  real  v_ref,      
    output logic d_out       
);

    real v_dac;              
    real error_signal;       
    real int_out;            
    real int_prev;           

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_prev <= 0.0;
            int_out  <= 0.0;
            d_out    <= 1'b0;
        end else begin
            v_dac = (d_out == 1'b1) ? v_ref : -v_ref;
            error_signal = v_in - v_dac;
            int_out = int_prev + error_signal;

            if (int_out >= 0.0) d_out <= 1'b1;
            else                d_out <= 1'b0;

            int_prev = int_out;
        end
    end
endmodule
