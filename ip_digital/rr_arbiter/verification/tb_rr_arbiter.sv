// =============================================================================
// tb_rr_arbiter.sv  --  Verilator / Icarus Testbench (Pillar 4 -- Simulation)
// =============================================================================
//
// Self-checking testbench.  Uses $error for failures so SimLogParser (P4)
// catches them and sets status=FAIL.
//
// NOTE: DUT is instantiated WITHOUT parameter override so the testbench works
// for both RTL sim (N_REQ defaults to 4) and GLS (synthesized netlist has no
// module-level parameters).
//
// Tests:
//   1. Basic round-robin   -- all 4 reqs active; verify rotating grant
//   2. Mask suppression    -- req[1] masked; verify it is never granted
//   3. Burst lock          -- grant frozen N cycles until last_i
//   4. Priority wrap       -- req[3] and req[0] only; verify wrap
//   5. All-masked          -- all masked; verify no grant
// =============================================================================

`timescale 1ns/1ps

module tb_rr_arbiter;

    localparam int N    = 4;
    localparam int HALF = 5;

    logic        clk;
    logic        rst_n;
    logic [N-1:0] req_i;
    logic [N-1:0] mask_i;
    logic        burst_lock_i;
    logic        last_i;
    logic [N-1:0] grant_o;
    logic        gnt_valid_o;

    // Instantiate without #() so GLS netlist (no parameters) works too
    rr_arbiter dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .req_i        (req_i),
        .mask_i       (mask_i),
        .burst_lock_i (burst_lock_i),
        .last_i       (last_i),
        .grant_o      (grant_o),
        .gnt_valid_o  (gnt_valid_o)
    );

    initial clk = 0;
    always #(HALF) clk = ~clk;

    initial begin
        #5000;
        $error("TIMEOUT: simulation ran past 5000 ns");
        $finish;
    end

    initial begin
        $dumpfile("rr_arbiter.vcd");
        $dumpvars(0, tb_rr_arbiter);
    end

    // ---- tasks ---------------------------------------------------------------

    task automatic do_reset;
        rst_n        = 0;
        req_i        = '0;
        mask_i       = '0;
        burst_lock_i = 0;
        last_i       = 0;
        repeat(3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // ---- Test 1: round-robin -------------------------------------------------

    task automatic test_round_robin;
        logic [N-1:0] seen;
        int           cycles;
        $display("  TEST 1: basic round-robin");
        do_reset();
        req_i  = 4'b1111;
        mask_i = 4'b0000;
        seen   = '0;
        cycles = 0;
        while (seen !== 4'b1111 && cycles < N*4) begin
            @(posedge clk);
            if (|(grant_o & (grant_o - 1'b1)))
                $error("FAIL rr: grant 0b%04b not one-hot0", grant_o);
            seen  |= grant_o;
            cycles++;
        end
        if (seen !== 4'b1111)
            $error("FAIL rr: not all granted (seen=0b%04b)", seen);
        else
            $display("    PASS: all 4 requesters granted in %0d cycles", cycles);
        req_i = '0;
        repeat(2) @(posedge clk);
    endtask

    // ---- Test 2: mask --------------------------------------------------------

    task automatic test_mask;
        logic [N-1:0] seen;
        $display("  TEST 2: mask -- req[1] must never be granted");
        do_reset();
        req_i  = 4'b1111;
        mask_i = 4'b0010;
        seen   = '0;
        repeat (N*4) begin
            @(posedge clk);
            if (|(grant_o & 4'b0010))
                $error("FAIL mask: req[1] granted while masked (0b%04b)", grant_o);
            seen |= grant_o;
        end
        if (|(seen & 4'b0010))
            $error("FAIL mask: req[1] appeared in seen mask");
        else
            $display("    PASS: req[1] never granted");
        req_i  = '0;
        mask_i = '0;
        repeat(2) @(posedge clk);
    endtask

    // ---- Test 3: burst lock --------------------------------------------------

    task automatic test_burst;
        logic [N-1:0] first_grant;
        $display("  TEST 3: burst lock -- grant frozen 4 cycles");
        do_reset();
        req_i        = 4'b0100;
        mask_i       = 4'b0000;
        burst_lock_i = 0;
        last_i       = 0;
        @(posedge clk);
        @(posedge clk);
        first_grant = grant_o;
        if (!first_grant[2])
            $error("FAIL burst setup: expected grant[2], got 0b%04b", grant_o);

        burst_lock_i = 1;
        req_i        = 4'b1111;
        repeat (4) begin
            @(posedge clk);
            if (grant_o !== first_grant)
                $error("FAIL burst: grant changed (0b%04b -> 0b%04b)",
                       first_grant, grant_o);
        end

        last_i = 1;
        @(posedge clk);
        last_i       = 0;
        burst_lock_i = 0;
        @(posedge clk);
        $display("    PASS: burst held, released (post=%0b)", grant_o);
        req_i = '0;
        repeat(2) @(posedge clk);
    endtask

    // ---- Test 4: wrap --------------------------------------------------------

    task automatic test_wrap;
        $display("  TEST 4: priority wrap -- req[3] and req[0] only");
        do_reset();
        req_i  = 4'b1001;
        mask_i = 4'b0000;
        repeat (8) begin
            @(posedge clk);
            if (|(grant_o & 4'b0110))
                $error("FAIL wrap: inactive req granted (0b%04b)", grant_o);
        end
        $display("    PASS: only req[0]/req[3] ever granted");
        req_i = '0;
        repeat(2) @(posedge clk);
    endtask

    // ---- Test 5: all masked --------------------------------------------------

    task automatic test_all_masked;
        $display("  TEST 5: all-masked -- no grant expected");
        do_reset();
        req_i  = 4'b1111;
        mask_i = 4'b1111;
        repeat (8) begin
            @(posedge clk);
            if (grant_o !== '0)
                $error("FAIL masked: grant asserted (0b%04b)", grant_o);
        end
        $display("    PASS: no grant while all masked");
        req_i  = '0;
        mask_i = '0;
        repeat(2) @(posedge clk);
    endtask

    // ---- top -----------------------------------------------------------------

    initial begin
        $display("====== rr_arbiter self-check ======");
        test_round_robin();
        test_mask();
        test_burst();
        test_wrap();
        test_all_masked();
        $display("====== ALL TESTS COMPLETE ======");
        $finish;
    end

endmodule
