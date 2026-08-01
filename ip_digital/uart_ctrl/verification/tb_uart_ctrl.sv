// tb_uart_ctrl.sv — Verilator/Icarus self-checking testbench for uart_ctrl.
//
// RTL sim: CLK_FREQ=1600, BAUD_RATE=100 → BRDIV=0 (baud16_tick every cycle).
// GLS sim: compiled with -D GLS; synth netlist has no parameters so the
//          instantiation uses `ifdef GLS to omit them.  T2 writes BRDIV=0
//          explicitly so GLS timing matches RTL sim.
//
// Tests
//   T1: APB register read-back (CTRL, BRDIV, IER)
//   T2: Loopback — write 3 bytes, poll TX_EMPTY, verify RDR
//   T3: TX watermark — fill FIFO depth=4, check TX_FULL; drain, check TX_EMPTY
//   T4: IRQ — TX_EMPTY_IE asserts irq_o; IER=0 deasserts it
`timescale 1ns/1ps

`define CLK_FREQ  1600
`define BAUD_RATE 100

module tb_uart_ctrl;

    localparam int FIFO_DEPTH = 4;

    logic        PCLK    = 0;
    logic        PRESETn = 0;
    logic        PSEL    = 0;
    logic        PENABLE = 0;
    logic        PWRITE  = 0;
    logic [4:0]  PADDR   = '0;
    logic [31:0] PWDATA  = '0;
    logic [31:0] PRDATA;
    logic        PREADY;
    logic        PSLVERR;
    logic        uart_tx_out;
    logic        uart_rx_in = 1;
    logic        irq_o;

`ifndef GLS
    // RTL simulation: instantiate with parameters for fast-sim timing
    uart_ctrl #(
        .CLK_FREQ  (`CLK_FREQ),
        .BAUD_RATE (`BAUD_RATE),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .PCLK    (PCLK),
        .PRESETn (PRESETn),
        .PSEL    (PSEL),
        .PENABLE (PENABLE),
        .PWRITE  (PWRITE),
        .PADDR   (PADDR),
        .PWDATA  (PWDATA),
        .PRDATA  (PRDATA),
        .PREADY  (PREADY),
        .PSLVERR (PSLVERR),
        .uart_tx (uart_tx_out),
        .uart_rx (uart_rx_in),
        .irq_o   (irq_o)
    );
`else
    // GLS: synthesized netlist has no parameters
    uart_ctrl dut (
        .PCLK    (PCLK),
        .PRESETn (PRESETn),
        .PSEL    (PSEL),
        .PENABLE (PENABLE),
        .PWRITE  (PWRITE),
        .PADDR   (PADDR),
        .PWDATA  (PWDATA),
        .PRDATA  (PRDATA),
        .PREADY  (PREADY),
        .PSLVERR (PSLVERR),
        .uart_tx (uart_tx_out),
        .uart_rx (uart_rx_in),
        .irq_o   (irq_o)
    );
`endif

    always #5 PCLK = ~PCLK;

    // Declare at module scope — Icarus rejects variable declarations inside begin blocks.
    int          errors = 0;
    logic [31:0] v;     // shared read-back variable for all tests

    // -----------------------------------------------------------------------
    // APB helpers
    // -----------------------------------------------------------------------
    task automatic apb_write(input logic [4:0] addr, input logic [31:0] data);
        @(posedge PCLK);
        PSEL    = 1; PWRITE = 1; PADDR = addr; PWDATA = data; PENABLE = 0;
        @(posedge PCLK);
        PENABLE = 1;
        @(posedge PCLK);
        if (!PREADY) $error("APB write: PREADY not asserted");
        PSEL = 0; PENABLE = 0; PWRITE = 0;
    endtask

    task automatic apb_read(input logic [4:0] addr, output logic [31:0] rdata);
        @(posedge PCLK);
        PSEL    = 1; PWRITE = 0; PADDR = addr; PENABLE = 0;
        @(posedge PCLK);
        PENABLE = 1;
        @(posedge PCLK);
        if (!PREADY) $error("APB read: PREADY not asserted");
        rdata = PRDATA;
        PSEL = 0; PENABLE = 0;
    endtask

    // Poll SR[bit_idx] until set. Uses disable (not return/break) for Icarus GLS compat.
    task automatic wait_sr_bit(input integer bit_idx, input integer timeout_cyc);
        logic [31:0] sr;
        integer i;
        begin : wsr_body
            for (i = 0; i < timeout_cyc; i = i + 1) begin
                apb_read(5'h10, sr);
                if (sr[bit_idx]) disable wsr_body;
            end
            $error("Timeout waiting for SR[%0d]", bit_idx);
            errors++;
        end
    endtask

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim_uart_ctrl.fst");
        $dumpvars(0, tb_uart_ctrl);

        PRESETn = 0;
        repeat(4) @(posedge PCLK);
        PRESETn = 1;
        @(posedge PCLK);

        // T1: Register read-back
        // CTRL reset default: TX_EN|RX_EN=1, EN=0 → bits[1:0] = 2'b10
        apb_read(5'h00, v);
        if (v[1:0] !== 2'b10) begin $error("T1: CTRL default wrong: %0h", v); errors++; end
        apb_write(5'h04, 32'd5);
        apb_read(5'h04, v);
        if (v[15:0] !== 16'd5) begin $error("T1: BRDIV readback wrong: %0h", v); errors++; end
        apb_write(5'h04, 32'd0);   // restore BRDIV=0
        // GLS: synth uses BRDIV_DEFAULT=26; after writing BRDIV=0 the baud counter
        // (cnt) is mid-count and must wrap through 65535→0 before baud16_tick fires.
        // RTL sim uses BRDIV_DEFAULT=0 so cnt=0=brdiv already — no wrap needed.
`ifdef GLS
        repeat(70000) @(posedge PCLK);
`endif
        apb_write(5'h14, 32'h3);
        apb_read(5'h14, v);
        if (v[1:0] !== 2'b11) begin $error("T1: IER readback wrong: %0h", v); errors++; end
        apb_write(5'h14, 32'h0);
        $display("T1 PASS: register read-back");

        // T2: Loopback — 3 bytes TX→RX
        // Writing BRDIV=0 keeps baud16_tick=1 every cycle in both RTL and GLS.
        // Poll TX_EMPTY (SR[1]) instead of fixed delay so timing is independent
        // of BRDIV default (RTL vs GLS netlist may differ).
        apb_write(5'h00, 32'h27);  // LOOPBACK|RX_EN|TX_EN|EN = 0b100111
        apb_write(5'h04, 32'd0);   // BRDIV=0
        apb_write(5'h08, 32'hAB);
        apb_write(5'h08, 32'hCD);
        apb_write(5'h08, 32'hEF);
        wait_sr_bit(1, 20000);       // TX_EMPTY: last byte POPPED from FIFO (TX started)
        repeat(200) @(posedge PCLK); // wait one full frame (160 cycles) + margin for
                                     // last byte to finish TX and propagate to RX FIFO
        apb_read(5'hC, v);
        if (v[7:0] !== 8'hAB) begin $error("T2: byte0 expected 0xAB got 0x%0h", v[7:0]); errors++; end
        apb_read(5'hC, v);
        if (v[7:0] !== 8'hCD) begin $error("T2: byte1 expected 0xCD got 0x%0h", v[7:0]); errors++; end
        apb_read(5'hC, v);
        if (v[7:0] !== 8'hEF) begin $error("T2: byte2 expected 0xEF got 0x%0h", v[7:0]); errors++; end
        $display("T2 PASS: loopback 3 bytes");

        // T3: TX FIFO watermark
        // EN=0 stops TX FSM; fill FIFO to capacity then overflow by 1 (dropped).
        // GLS synthesis uses FIFO_DEPTH=16 (RTL default, no -chparam in synth script).
        apb_write(5'h00, 32'h04);
`ifndef GLS
        apb_write(5'h08, 32'h11);
        apb_write(5'h08, 32'h22);
        apb_write(5'h08, 32'h33);
        apb_write(5'h08, 32'h44);
        apb_write(5'h08, 32'hFF);   // overflow: dropped (FIFO_DEPTH=4)
`else
        apb_write(5'h08, 32'h01); apb_write(5'h08, 32'h02); apb_write(5'h08, 32'h03);
        apb_write(5'h08, 32'h04); apb_write(5'h08, 32'h05); apb_write(5'h08, 32'h06);
        apb_write(5'h08, 32'h07); apb_write(5'h08, 32'h08); apb_write(5'h08, 32'h09);
        apb_write(5'h08, 32'h0A); apb_write(5'h08, 32'h0B); apb_write(5'h08, 32'h0C);
        apb_write(5'h08, 32'h0D); apb_write(5'h08, 32'h0E); apb_write(5'h08, 32'h0F);
        apb_write(5'h08, 32'h10);   // 16th byte — fills FIFO
        apb_write(5'h08, 32'hFF);   // overflow: dropped (FIFO_DEPTH=16)
`endif
        apb_read(5'h10, v);
        if (!v[0]) begin $error("T3: TX_FULL not set after filling FIFO"); errors++; end
        if ( v[1]) begin $error("T3: TX_EMPTY unexpectedly set"); errors++; end
        apb_write(5'h00, 32'h27);
        wait_sr_bit(1, 20000);
        apb_read(5'h10, v);
        if (!v[1]) begin $error("T3: TX_EMPTY not set after drain"); errors++; end
        $display("T3 PASS: TX FIFO watermark");

        // T4: IRQ — TX_EMPTY_IE
        apb_write(5'h14, 32'h1);
        apb_write(5'h08, 32'h5A);
        @(posedge PCLK);
        wait_sr_bit(1, 20000);
        @(posedge PCLK);
        if (!irq_o) begin $error("T4: irq_o not asserted after TX_EMPTY"); errors++; end
        apb_write(5'h14, 32'h0);
        @(posedge PCLK);
        if (irq_o) begin $error("T4: irq_o still asserted after IER cleared"); errors++; end
        $display("T4 PASS: TX_EMPTY IRQ");

        repeat(4) @(posedge PCLK);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $error("%0d test(s) FAILED", errors);
        $finish;
    end

    initial begin
        #10_000_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

endmodule
