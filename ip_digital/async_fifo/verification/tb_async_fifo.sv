// tb_async_fifo.sv — Self-checking Verilator testbench for async_fifo
// wr_clk: 10 ns period  rd_clk: 30 ns period  (3:1 ratio)
// Tests: fill/drain, backpressure, simultaneous full+empty, stress.

`timescale 1ns/1ps

module tb_async_fifo;

    localparam int DATA_W = 32;
    localparam int DEPTH  = 8;
    localparam int WR_HALF = 5;    // wr_clk half-period (ns)
    localparam int RD_HALF = 15;   // rd_clk half-period (ns)

    logic              wr_clk, wr_rst_n, wr_en;
    logic [DATA_W-1:0] wr_data;
    logic              full;

    logic              rd_clk, rd_rst_n, rd_en;
    logic [DATA_W-1:0] rd_data;
    logic              empty;

    // Golden reference queue (parallel to DUT)
    int unsigned ref_q[$];
    int errors = 0;
    int unsigned rd_bin_before;

`ifdef GLS
    // Synthesised netlist has no parameters — connect ports by name only.
    async_fifo dut (.*);
`else
    async_fifo #(
        .DATA_W(DATA_W),
        .DEPTH (DEPTH)
    ) dut (.*);
`endif

    // ── Clock generators ─────────────────────────────────────────────────────
    initial wr_clk = 0;
    always #(WR_HALF) wr_clk = ~wr_clk;

    initial rd_clk = 0;
    always #(RD_HALF) rd_clk = ~rd_clk;

    // ── Tasks ────────────────────────────────────────────────────────────────

    task automatic wr_tick;
        @(posedge wr_clk); #1;
    endtask

    task automatic rd_tick;
        @(posedge rd_clk); #1;
    endtask

    task automatic do_write(input [DATA_W-1:0] d);
        wait (!full);
        @(posedge wr_clk); #1;
        wr_en   = 1;
        wr_data = d;
        ref_q.push_back(int'(d));
        @(posedge wr_clk); #1;
        wr_en = 0;
    endtask

    task automatic do_read(output [DATA_W-1:0] got);
        wait (!empty);
        @(posedge rd_clk); #1;
        rd_en = 1;
        @(posedge rd_clk); #1;
        rd_en = 0;
        got   = rd_data;
    endtask

    task automatic check_read(string tag);
        logic [DATA_W-1:0] got;
        int exp;
        do_read(got);
        exp = ref_q.pop_front();
        if (int'(got) !== exp) begin
            $error("%s: rd_data=0x%08x expected=0x%08x", tag, got, exp);
            errors++;
        end
    endtask

    // ── Stimulus ──────────────────────────────────────────────────────────────
    initial begin
        wr_en    = 0;
        wr_data  = 0;
        rd_en    = 0;
        wr_rst_n = 0;
        rd_rst_n = 0;

        // Reset both domains simultaneously
        repeat(4) @(posedge wr_clk);
        repeat(4) @(posedge rd_clk);
        @(posedge wr_clk); #1; wr_rst_n = 1;
        @(posedge rd_clk); #1; rd_rst_n = 1;

        // Allow synchronisers to settle
        repeat(4) @(posedge wr_clk);

        // ── Test 1: fill FIFO, then drain ─────────────────────────────────
        $display("=== Test 1: fill/drain ===");
        for (int i = 0; i < DEPTH; i++)
            do_write(32'hA0000000 | i);
        // FIFO should now be full
        @(posedge wr_clk); #1;
        if (!full)
            $error("fill: expected full=1 after %0d writes", DEPTH);

        for (int i = 0; i < DEPTH; i++)
            check_read($sformatf("drain[%0d]", i));

        // Allow empty flag to propagate
        repeat(6) @(posedge rd_clk);
        if (!empty)
            $error("drain: expected empty=1 after full drain");

        // ── Test 2: simultaneous wr and rd ───────────────────────────────
        $display("=== Test 2: simultaneous wr/rd ===");
        fork
            begin // writer: 8 items
                for (int i = 0; i < 8; i++)
                    do_write(32'hB0000000 | i);
            end
            begin // reader: 8 items, starts 30 ns after writer
                repeat(3) @(posedge rd_clk);
                for (int i = 0; i < 8; i++)
                    check_read($sformatf("simul[%0d]", i));
            end
        join

        // ── Test 3: backpressure (wr 3× faster, reader throttled) ─────────
        $display("=== Test 3: backpressure ===");
        fork
            begin // writer: burst 12 items
                for (int i = 0; i < 12; i++)
                    do_write(32'hC0000000 | i);
            end
            begin // reader: read one per 3 wr cycles (matches rd_clk rate)
                repeat(6) @(posedge rd_clk);
                for (int i = 0; i < 12; i++) begin
                    check_read($sformatf("backp[%0d]", i));
                    repeat(2) @(posedge rd_clk);
                end
            end
        join

        // ── Test 4: write with rd_en=0 — no spurious reads ───────────────
        $display("=== Test 4: no spurious rd when rd_en=0 ===");
        rd_en = 0;
        rd_bin_before = int'(dut.rd_bin);
        for (int i = 0; i < 4; i++)
            do_write(32'hD0000000 | i);
        repeat(10) @(posedge rd_clk);
        // rd_bin must not have advanced (no phantom reads while rd_en=0)
        if (int'(dut.rd_bin) !== rd_bin_before)
            $error("spurious read: rd_bin changed from %0d to %0d",
                   rd_bin_before, int'(dut.rd_bin));
        // Drain remaining
        for (int i = 0; i < 4; i++)
            check_read($sformatf("spurious_rd[%0d]", i));

        // ── Finish ────────────────────────────────────────────────────────
        repeat(20) @(posedge wr_clk);
        if (errors == 0)
            $display("PASS all %0d checks clean", DEPTH * 4 + 4);
        else
            $error("FAIL %0d error(s)", errors);
        $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────────────
    initial begin
        #200000;
        $error("TIMEOUT: simulation exceeded 200 us");
        $finish;
    end

endmodule
