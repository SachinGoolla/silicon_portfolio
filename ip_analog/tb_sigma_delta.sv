`timescale 1ns/1ps

module tb_sigma_delta;
    logic clk;
    logic rst_n;
    real  v_in;
    real  v_ref;
    logic d_out;

    // Instantiate the RNM Modulator
    sigma_delta_rnm uut (
        .clk(clk),
        .rst_n(rst_n),
        .v_in(v_in),
        .v_ref(v_ref),
        .d_out(d_out)
    );

    // Generate 100MHz oversampling clock
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        // Tell the simulator to dump waveforms for GTKWave
        $dumpfile("sigma_delta.vcd");
        $dumpvars(0, tb_sigma_delta);

        // Initialize
        rst_n = 0;
        v_ref = 1.0; 
        v_in  = 0.0;
        
        #20 rst_n = 1;

        // Sweep the analog voltage from -1.0V to +1.0V over time
        for (int i = -100; i <= 100; i++) begin
            v_in = (i * 1.0) / 100.0; 
            #500; // Hold the voltage steady for a bit
        end

        #1000 $finish;
    end
endmodule
