module tb_mod1000;
    logic clk;
    logic rst_n;
    logic [9:0] count;

    mod1000 dut (
        .clk(clk),
        .rst_n(rst_n),
        .count(count)
    );

    string vcd_path;
    initial begin
        if ($value$plusargs("vcd=%s", vcd_path)) begin
            $dumpfile(vcd_path);
        end else begin
            $dumpfile("sim.vcd");
        end
        $dumpvars(0, tb_mod1000);
        
        $display("Starting Simulation...");
        clk = 0;
        rst_n = 0;
        
        #12 rst_n = 1;

        #11000; // Let it run past 1000 cycles
        $display("✅ MOD1000 STRESS TEST COMPLETE.");
        $finish;
    end

    always #5 clk = ~clk;

endmodule
