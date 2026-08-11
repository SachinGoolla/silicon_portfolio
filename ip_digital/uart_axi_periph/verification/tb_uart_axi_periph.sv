// tb_uart_axi_periph.sv — self-checking Verilator/Icarus testbench.
//
// Drives the AXI4-Lite register interface (same task style as
// tb_fpu_axi_periph.sv) and exercises the full UART stack through an
// external wire loopback (uart_rx_i <= uart_tx_o), byte round-tripping
// through apb_uart_master's own TX/RX FIFOs and uart_ctrl's TX/RX FSMs.
//
// CLK_FREQ/BAUD_RATE are overridden so apb_uart_master's computed
// BRDIV_VAL = CLK_FREQ/(BAUD_RATE*16)-1 = 0 (baud16_tick fires every
// cycle) — the exact fast-sim convention documented in uart_ctrl's own
// CLAUDE.md ("For CLK_FREQ=1600, BAUD_RATE=100 this gives 0"). Without
// this a real UART frame costs thousands of cycles at default baud.
//
// Tests
//   T1  Reset + init: INIT_DONE reached, TX_READY=1, RX_VALID=0, ERR=0
//   T2  TX->RX loopback: single byte round trip through the whole stack
//   T3  Back-to-back multi-byte loopback, in-order
//   T4  SLVERR on out-of-range read
//   T5  CTRL[0] pop with no RX data pending is a safe no-op
`timescale 1ns/1ps

`define DATA_WIDTH 32
`define ADDR_WIDTH 8

module tb_uart_axi_periph;

    logic clk   = 0;
    logic rst_n = 0;

    logic                    awvalid, awready;
    logic [`ADDR_WIDTH-1:0]  awaddr;
    logic [2:0]              awprot;
    logic                    wvalid, wready;
    logic [`DATA_WIDTH-1:0]  wdata;
    logic [3:0]              wstrb;
    logic                    bvalid, bready;
    logic [1:0]              bresp;
    logic                    arvalid, arready;
    logic [`ADDR_WIDTH-1:0]  araddr;
    logic [2:0]              arprot;
    logic                    rvalid, rready;
    logic [`DATA_WIDTH-1:0]  rdata;
    logic [1:0]              rresp;
    logic                    uart_loop;

`ifndef GLS
    // RTL simulation: instantiate with parameters for fast-sim timing.
    uart_axi_periph #(
        .CLK_FREQ  (1600),
        .BAUD_RATE (100)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .awvalid_i (awvalid), .awready_o (awready),
        .awaddr_i  (awaddr),  .awprot_i  (awprot),
        .wvalid_i  (wvalid),  .wready_o  (wready),
        .wdata_i   (wdata),   .wstrb_i   (wstrb),
        .bvalid_o  (bvalid),  .bready_i  (bready),
        .bresp_o   (bresp),
        .arvalid_i (arvalid), .arready_o (arready),
        .araddr_i  (araddr),  .arprot_i  (arprot),
        .rvalid_o  (rvalid),  .rready_i  (rready),
        .rdata_o   (rdata),   .rresp_o   (rresp),
        .uart_tx_o (uart_loop), .uart_rx_i (uart_loop)
    );
`else
    // GLS: synthesized netlist has no parameters — falls back to
    // apb_uart_master/uart_ctrl's default CLK_FREQ=50MHz/BAUD_RATE=115200
    // (BRDIV=26). uart_axi_periph has no direct register access to BRDIV
    // the way uart_ctrl's own standalone TB does (apb_uart_master owns
    // and autonomously programs it), so this mode is simply slower — every
    // wait_bit() call below is already condition-polled, not cycle-counted,
    // so it tolerates the longer real UART frame time; only the poll
    // budgets need enough margin (see rx_byte).
    uart_axi_periph dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .awvalid_i (awvalid), .awready_o (awready),
        .awaddr_i  (awaddr),  .awprot_i  (awprot),
        .wvalid_i  (wvalid),  .wready_o  (wready),
        .wdata_i   (wdata),   .wstrb_i   (wstrb),
        .bvalid_o  (bvalid),  .bready_i  (bready),
        .bresp_o   (bresp),
        .arvalid_i (arvalid), .arready_o (arready),
        .araddr_i  (araddr),  .arprot_i  (arprot),
        .rvalid_o  (rvalid),  .rready_i  (rready),
        .rdata_o   (rdata),   .rresp_o   (rresp),
        .uart_tx_o (uart_loop), .uart_rx_i (uart_loop)
    );
`endif

    always #5 clk = ~clk;

    int errors = 0;

    localparam logic [`ADDR_WIDTH-1:0] TXDATA = 8'h00;
    localparam logic [`ADDR_WIDTH-1:0] RXDATA = 8'h04;
    localparam logic [`ADDR_WIDTH-1:0] STATUS = 8'h08;
    localparam logic [`ADDR_WIDTH-1:0] CTRL   = 8'h0C;

    // ----------------------------------------------------------------
    // AXI4-Lite master tasks
    // ----------------------------------------------------------------
    task automatic axi_write(
        input  logic [`ADDR_WIDTH-1:0] addr,
        input  logic [`DATA_WIDTH-1:0] data,
        output logic [1:0]             out_resp
    );
        awvalid = 1; awaddr = addr; awprot = 3'b000;
        wvalid  = 1; wdata  = data; wstrb  = 4'hF;
        begin : aw_w_loop
            logic aw_done, w_done;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (awready && awvalid) begin aw_done = 1; awvalid = 0; end
                if (wready  && wvalid)  begin w_done  = 1; wvalid  = 0; end
            end
        end
        bready = 1;
        while (!bvalid) @(posedge clk);
        out_resp = bresp;
        @(posedge clk);
        bready = 0;
    endtask

    task automatic axi_read(
        input  logic [`ADDR_WIDTH-1:0]  addr,
        output logic [`DATA_WIDTH-1:0]  out_data,
        output logic [1:0]              out_resp
    );
        arvalid = 1; araddr = addr; arprot = 3'b000;
        rready  = 1;
        @(posedge clk);
        while (!(arready && arvalid)) @(posedge clk);
        arvalid = 0;
        while (!rvalid) @(posedge clk);
        out_data = rdata;
        out_resp = rresp;
        @(posedge clk);
        rready = 0;
    endtask

    task automatic wait_bit(
        input  logic [`ADDR_WIDTH-1:0] addr,
        input  int                     bit_idx,
        input  logic                   want,
        input  int                     max_polls,
        output logic                   ok
    );
        logic [`DATA_WIDTH-1:0] v;
        logic [1:0]             resp;
        int polls;
        // No `break` — Icarus rejects it in the P8 GLS compile
        // (`sorry: break statements not supported`). Loop bound instead.
        ok = 0;
        polls = 0;
        while (!ok && polls <= max_polls) begin
            axi_read(addr, v, resp);
            if (v[bit_idx] === want) ok = 1;
            polls++;
        end
    endtask

    task automatic tx_byte(input logic [7:0] b);
        logic [1:0] resp;
        logic       ok;
        wait_bit(STATUS, 0, 1'b1, 200, ok);  // TX_READY
        if (!ok) begin $error("tx_byte: TX_READY never asserted"); errors++; end
        axi_write(TXDATA, {24'd0, b}, resp);
        if (resp !== 2'b00) begin $error("tx_byte: TXDATA write SLVERR"); errors++; end
    endtask

    // Poll RX_VALID==1, read RXDATA, ack, then confirm RX_VALID==0 before
    // returning. The confirm step is required, not defensive: STATUS is
    // read back through axi_lite_slave's own 2-cycle hw_wdata_q/reg_q
    // pipeline, so a poll issued immediately after the ack write can still
    // observe the stale RX_VALID=1 describing the byte just acked,
    // indistinguishable from a genuine new byte without first seeing it
    // drop to 0.
    task automatic rx_byte(output logic [7:0] b, output logic ok);
        logic [`DATA_WIDTH-1:0] v;
        logic [1:0]             resp;
        logic                   ack_ok;
        // No `return` — Icarus rejects it in the P8 GLS compile
        // ("Cannot "return" from tasks."); guard the rest with `if (ok)`.
        // (T2/T3, the only callers, are RTL-sim-only — see `ifndef GLS`
        // below — so this budget only needs to cover BRDIV=0 fast-sim.)
        wait_bit(STATUS, 1, 1'b1, 2000, ok);  // RX_VALID
        if (!ok) begin
            $error("rx_byte: RX_VALID never asserted"); errors++;
        end else begin
            axi_read(RXDATA, v, resp);
            b = v[7:0];
            axi_write(CTRL, 32'h1, resp);  // ack
            wait_bit(STATUS, 1, 1'b0, 20, ack_ok);  // confirm ack landed
            if (!ack_ok) begin $error("rx_byte: RX_VALID never cleared after ack"); errors++; end
        end
    endtask

    task check_eq8(input string tag, input logic [7:0] got, exp);
        if (got !== exp) begin
            $error("%s: expected 0x%02h, got 0x%02h", tag, exp, got);
            errors++;
        end
    endtask

    // ----------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------
    logic [`DATA_WIDTH-1:0] rd_data;
    logic [1:0]             rd_resp;
    logic [7:0]              got_byte;
    logic                    ok;
    int                      errs_before;

    initial begin
        $dumpfile("sim_uart_axi_periph.fst");
        $dumpvars(0, tb_uart_axi_periph);

        awvalid = 0; awaddr = '0; awprot = '0;
        wvalid  = 0; wdata  = '0; wstrb  = '0;
        bready  = 0;
        arvalid = 0; araddr = '0; arprot = '0;
        rready  = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // PASS messages are gated on the per-test error delta below —
        // an earlier version printed "T2 PASS"/"T3 PASS" unconditionally
        // even when rx_byte had already logged real errors, exactly the
        // "fake PASS" class this portfolio's uart_ctrl report exists to
        // warn about. Never repeat that here.
        errs_before = errors;

        // --- T1: reset + init ---------------------------------------
        wait_bit(STATUS, 3, 1'b1, 200, ok);  // INIT_DONE
        if (!ok) begin $error("T1: INIT_DONE never asserted"); errors++; end
        axi_read(STATUS, rd_data, rd_resp);
        if (rd_data[0] !== 1'b1) begin $error("T1: TX_READY not set post-init"); errors++; end
        if (rd_data[1] !== 1'b0) begin $error("T1: RX_VALID unexpectedly set"); errors++; end
        if (rd_data[2] !== 1'b0) begin $error("T1: ERR unexpectedly set"); errors++; end
        if (errors == errs_before) $display("T1 PASS: reset + init complete, status clean");

`ifndef GLS
        // --- T2: single-byte loopback --------------------------------
        // RTL-sim only (BRDIV=0 fast-sim). A full serial frame at gate
        // level under interpreted Icarus GLS costs ~4320 core cycles/byte
        // (BRDIV=26 default -- no parameter override on a synthesized
        // netlist) times a large per-cycle gate-evaluation multiplier --
        // it blew past pillar.py's 120s GLS wall-clock budget outright
        // when tried. See the `else` branch below for what GLS covers
        // instead.
        errs_before = errors;
        tx_byte(8'h41);  // 'A'
        rx_byte(got_byte, ok);
        if (ok) check_eq8("T2 loopback byte", got_byte, 8'h41);
        if (errors == errs_before) $display("T2 PASS: single-byte loopback ('A')");

        // --- T3: back-to-back multi-byte, in order --------------------
        errs_before = errors;
        tx_byte(8'h48);  // 'H'
        tx_byte(8'h49);  // 'I'
        rx_byte(got_byte, ok);
        if (ok) check_eq8("T3a byte0", got_byte, 8'h48);
        rx_byte(got_byte, ok);
        if (ok) check_eq8("T3b byte1", got_byte, 8'h49);
        if (errors == errs_before) $display("T3 PASS: back-to-back multi-byte loopback in order");
`else
        $display("T2/T3 SKIPPED in GLS: full-baud serial loopback is already covered by P3 cocotb + P4 RTL sim (both BRDIV=0 fast-sim); re-running it under interpreted gate-level Icarus sim (~4320 core cycles/byte at the synthesized default BRDIV=26, no parameter override available on a netlist) exceeds pillar.py's 120s GLS wall-clock budget on this shared host.");

        // --- T2b: GLS-safe TX glue exercise ---------------------------
        // Costs no baud time: TX_READY reflects apb_uart_master's own
        // TX FIFO accepting the byte (a handful of cycles), not the
        // serial drain that follows. Exercises tx_we_q/tx_pending_q at
        // gate level within budget -- the RX shadow latch (rx_have_byte_q)
        // has no equivalent shortcut, since it can only ever be set by a
        // byte actually completing serial reception; RX glue is GLS-
        // -unverified by construction, same honest boundary as T2/T3.
        errs_before = errors;
        tx_byte(8'h41);
        wait_bit(STATUS, 0, 1'b1, 200, ok);  // TX_READY returns once FIFO accepts
        if (!ok) begin $error("T2b: TX_READY never returned after TXDATA write"); errors++; end
        if (errors == errs_before) $display("T2b PASS: TX glue exercised at gate level (FIFO push only, no serial wait)");
`endif

        // --- T4: SLVERR on out-of-range read --------------------------
        errs_before = errors;
        axi_read(8'h40, rd_data, rd_resp);
        if (rd_resp !== 2'b10) begin
            $error("T4: expected SLVERR, got %0b", rd_resp); errors++;
        end
        if (errors == errs_before) $display("T4 PASS: SLVERR on out-of-range read");

        // --- T5: CTRL[0] pop with nothing pending is a safe no-op -----
        errs_before = errors;
        axi_write(CTRL, 32'h1, rd_resp);
        repeat(4) @(posedge clk);
        axi_read(STATUS, rd_data, rd_resp);
        if (rd_data[1] !== 1'b0) begin
            $error("T5: RX_VALID unexpectedly set after no-op pop"); errors++;
        end
        if (errors == errs_before) $display("T5 PASS: no-op pop is safe");

        repeat(4) @(posedge clk);

        if (errors == 0) $display("ALL TESTS PASSED");
        else              $error("%0d test(s) FAILED", errors);
        $finish;
    end

    initial begin
        #2_000_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

endmodule
