// async_fifo.sv — Dual-clock async FIFO (Clifford Cummings 2002 gray-code style)
// DATA_W=32, DEPTH=8 (PTR_W=4), SYNC_STAGES=2.  DEPTH must be a power-of-2 >= 4.

module async_fifo #(
    parameter int DATA_W      = 32,
    parameter int DEPTH       = 8,
    parameter int SYNC_STAGES = 2
) (
    // Write clock domain
    input  logic              wr_clk,
    input  logic              wr_rst_n,
    input  logic              wr_en,
    input  logic [DATA_W-1:0] wr_data,
    output logic              full,

    // Read clock domain
    input  logic              rd_clk,
    input  logic              rd_rst_n,
    input  logic              rd_en,
    output logic [DATA_W-1:0] rd_data,
    output logic              empty
);

    localparam int ADDR_W = $clog2(DEPTH);
    localparam int PTR_W  = ADDR_W + 1;   // extra bit for full/empty disambiguation

    initial begin
        if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "async_fifo: DEPTH must be a power-of-2 >= 4");
        if (SYNC_STAGES < 2)
            $fatal(1, "async_fifo: SYNC_STAGES must be >= 2");
    end

    // ─── Dual-port RAM ───────────────────────────────────────────────────────
    // Written on wr_clk, read asynchronously (output register in rd domain).
    (* keep *) logic [DATA_W-1:0] mem [0:DEPTH-1];

    // ─── Write-domain state ──────────────────────────────────────────────────
    logic [PTR_W-1:0] wr_bin;    // binary write pointer (extra MSB for full)
    logic [PTR_W-1:0] wr_gray;   // gray-coded write pointer (crosses to rd domain)

    // ─── Read-domain state ───────────────────────────────────────────────────
    logic [PTR_W-1:0] rd_bin;    // binary read pointer
    logic [PTR_W-1:0] rd_gray;   // gray-coded read pointer (crosses to wr domain)

    // ─── Two-FF synchronisers ─────────────────────────────────────────────────
    // (* keep *) prevents Yosys from merging or removing synchroniser stages.
    (* keep *) logic [PTR_W-1:0] wg2rd [0:SYNC_STAGES-1]; // wr_gray → rd_clk
    (* keep *) logic [PTR_W-1:0] rg2wr [0:SYNC_STAGES-1]; // rd_gray → wr_clk

    // ─── Binary ↔ Gray helpers ───────────────────────────────────────────────
    function automatic [PTR_W-1:0] b2g(input [PTR_W-1:0] b);
        b2g = b ^ (b >> 1);
    endfunction

    function automatic [PTR_W-1:0] g2b(input [PTR_W-1:0] g);
        integer i;
        g2b[PTR_W-1] = g[PTR_W-1];
        for (i = PTR_W-2; i >= 0; i = i - 1)
            g2b[i] = g2b[i+1] ^ g[i];
    endfunction

    // ─── Write domain ────────────────────────────────────────────────────────
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= '0;
            wr_gray <= '0;
        end else if (wr_en && !full) begin
            mem[wr_bin[ADDR_W-1:0]] <= wr_data;
            wr_bin                  <= wr_bin  + 1'b1;
            wr_gray                 <= b2g(wr_bin + 1'b1);
        end
    end

    // ─── Read domain ─────────────────────────────────────────────────────────
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= '0;
            rd_gray <= '0;
            rd_data <= '0;
        end else if (rd_en && !empty) begin
            rd_data <= mem[rd_bin[ADDR_W-1:0]];
            rd_bin  <= rd_bin  + 1'b1;
            rd_gray <= b2g(rd_bin + 1'b1);
        end
    end

    // ─── Synchroniser: wr_gray → rd_clk ─────────────────────────────────────
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            for (int i = 0; i < SYNC_STAGES; i++) wg2rd[i] <= '0;
        end else begin
            wg2rd[0] <= wr_gray;
            for (int i = 1; i < SYNC_STAGES; i++) wg2rd[i] <= wg2rd[i-1];
        end
    end

    // ─── Synchroniser: rd_gray → wr_clk ─────────────────────────────────────
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            for (int i = 0; i < SYNC_STAGES; i++) rg2wr[i] <= '0;
        end else begin
            rg2wr[0] <= rd_gray;
            for (int i = 1; i < SYNC_STAGES; i++) rg2wr[i] <= rg2wr[i-1];
        end
    end

    // ─── Empty flag (read domain) ────────────────────────────────────────────
    // Empty when rd_gray equals the synchronized (stale) wr_gray.
    assign empty = (rd_gray == wg2rd[SYNC_STAGES-1]);

    // ─── Full flag (write domain) ────────────────────────────────────────────
    // Full when wr_gray equals rg2wr with the top two bits inverted.
    // (Cummings 2002, Fig 6: top two bits inverted distinguishes wrap-around.)
    assign full = (wr_gray == {~rg2wr[SYNC_STAGES-1][PTR_W-1:PTR_W-2],
                                 rg2wr[SYNC_STAGES-1][PTR_W-3:0]});

    // ─── Formal properties ───────────────────────────────────────────────────
    // Uses always @(posedge clk) blocks (Yosys `read -formal` compatible).
    // $past() and cover() are valid inside always blocks in Yosys formal flow.
    `ifdef FORMAL

        reg f_wr_started, f_rd_started;
        initial begin f_wr_started = 0; f_rd_started = 0; end
        always @(posedge wr_clk) f_wr_started <= 1;
        always @(posedge rd_clk) f_rd_started <= 1;

        // ── Write-domain properties ──────────────────────────────────────────
        always @(posedge wr_clk) begin
            if (wr_rst_n && f_wr_started) begin
                // Gray pointer must always match binary (catches b2g bugs)
                assert (wr_gray == b2g(wr_bin));
                // Full flag blocks new writes: wr_bin frozen the cycle after full
                if ($past(full))
                    assert (wr_bin == $past(wr_bin));
            end
        end

        // ── Read-domain properties ───────────────────────────────────────────
        always @(posedge rd_clk) begin
            if (rd_rst_n && f_rd_started) begin
                // Gray pointer must always match binary
                assert (rd_gray == b2g(rd_bin));
                // Empty flag blocks reads: rd_bin frozen the cycle after empty
                if ($past(empty))
                    assert (rd_bin == $past(rd_bin));
            end
        end

        // ── Cover properties ─────────────────────────────────────────────────
        always @(posedge wr_clk)
            if (f_wr_started) cover (full);

        always @(posedge rd_clk)
            if (f_rd_started) cover (!empty);

    `endif

endmodule
