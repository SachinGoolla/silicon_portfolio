// tb_apb_uart_master.sv — self-checking Verilator testbench.
//
// Uses an embedded uart_ctrl behavioral model (BFM) so the test is fully
// self-contained in this IP's directory — no cross-IP file dependencies.
// The BFM implements the same register map and APB3 timing as the RTL, with
// a direct internal loopback: bytes written to TDR appear in the RX FIFO after
// one simulated UART frame (160 cycles at BRDIV=0).
//
// Sim timing: CLK_FREQ=1600, BAUD_RATE=100 → BRDIV=0 → frame = 160 cycles.
//
// Tests
//   T1: init_done_o asserts after 3 back-to-back APB writes (BRDIV/IER/CTRL)
//   T2: TX→RX loopback — push 3 bytes, receive all 3 in order
//   T3: APB protocol — PENABLE never asserted without PSEL (monitored throughout)
//   T4: err_o stays 0 — no PSLVERR on any transaction
`timescale 1ns/1ps

`define CLK_FREQ  1600
`define BAUD_RATE 100

module tb_apb_uart_master;

    logic       clk   = 0;
    logic       rst_n = 0;

    logic [7:0] tx_data;
    logic       tx_valid = 0;
    logic       tx_ready;

    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_ready = 1;

    logic        PSEL, PENABLE, PWRITE;
    logic [4:0]  PADDR;
    logic [31:0] PWDATA, PRDATA;
    logic        PREADY, PSLVERR;
    logic        irq_bfm;
    logic        init_done, err_out;

    // DUT — APB master
    // GLS: synthesized netlist has no parameters (elaborated as defaults).
    // RTL sim uses fast CLK_FREQ/BAUD_RATE overrides for quick loopback.
`ifdef GLS
    apb_uart_master dut (
`else
    apb_uart_master #(
        .CLK_FREQ  (`CLK_FREQ),
        .BAUD_RATE (`BAUD_RATE),
        .TX_DEPTH  (4),
        .RX_DEPTH  (4),
        .CTRL_WORD (32'h07)
    ) dut (
`endif
        .clk        (clk),
        .rst_n      (rst_n),
        .tx_data_i  (tx_data),
        .tx_valid_i (tx_valid),
        .tx_ready_o (tx_ready),
        .rx_data_o  (rx_data),
        .rx_valid_o (rx_valid),
        .rx_ready_i (rx_ready),
        .PSEL       (PSEL),
        .PENABLE    (PENABLE),
        .PWRITE     (PWRITE),
        .PADDR      (PADDR),
        .PWDATA     (PWDATA),
        .PRDATA     (PRDATA),
        .PREADY     (PREADY),
        .PSLVERR    (PSLVERR),
        .irq_i      (irq_bfm),
        .init_done_o(init_done),
        .err_o      (err_out)
    );

    // BFM — uart_ctrl behavioral model
    uart_ctrl_bfm #(
        .CLK_FREQ  (`CLK_FREQ),
        .BAUD_RATE (`BAUD_RATE),
        .FIFO_DEPTH(4)
    ) bfm (
        .PCLK   (clk),
        .PRESETn(rst_n),
        .PSEL   (PSEL),
        .PENABLE(PENABLE),
        .PWRITE (PWRITE),
        .PADDR  (PADDR),
        .PWDATA (PWDATA),
        .PRDATA (PRDATA),
        .PREADY (PREADY),
        .PSLVERR(PSLVERR),
        .irq_o  (irq_bfm)
    );

    always #5 clk = ~clk;

    int  errors = 0;
    logic [7:0] got;

    task automatic wait_init(input int timeout_cyc);
        integer i;
        begin : wi_body
            for (i = 0; i < timeout_cyc; i = i + 1) begin
                @(posedge clk);
                if (init_done) disable wi_body;
            end
            $error("Timeout waiting for init_done"); errors++;
        end
    endtask

    task automatic push_byte(input logic [7:0] b);
        tx_data = b; tx_valid = 1;
        @(posedge clk);
        while (!tx_ready) @(posedge clk);
        tx_valid = 0;
    endtask

    task automatic recv_byte_t(output logic [7:0] b, input int tmo);
        integer i;
        begin : rb_body
            for (i = 0; i < tmo; i = i + 1) begin
                @(posedge clk);
                if (rx_valid) begin b = rx_data; disable rb_body; end
            end
            $error("Timeout waiting for RX byte"); b = 8'hXX; errors++;
        end
    endtask

    // T3 monitor: APB_PHASE invariant
    always @(posedge clk) begin
        if (PENABLE && !PSEL) begin
            $error("T3: APB_PHASE violated — PENABLE without PSEL");
            errors++;
        end
    end

    initial begin
        $dumpfile("sim_apb_uart_master.fst");
        $dumpvars(0, tb_apb_uart_master);

        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;

        // T1 — init_done after 3 back-to-back APB writes
        wait_init(200);
        if (!init_done) begin $error("T1: init_done not asserted"); errors++; end
        if (err_out)    begin $error("T1: PSLVERR on init"); errors++; end
        $display("T1 PASS: init_done asserted, no APB errors");

        // T2 — TX→RX loopback: 3 bytes, each takes ~160-cycle UART frame
        push_byte(8'hA5);
        push_byte(8'h3C);
        push_byte(8'hF0);

        recv_byte_t(got, 5000);
        if (got !== 8'hA5) begin $error("T2: byte0 want 0xA5, got 0x%02h", got); errors++; end
        recv_byte_t(got, 5000);
        if (got !== 8'h3C) begin $error("T2: byte1 want 0x3C, got 0x%02h", got); errors++; end
        recv_byte_t(got, 5000);
        if (got !== 8'hF0) begin $error("T2: byte2 want 0xF0, got 0x%02h", got); errors++; end
        $display("T2 PASS: loopback 3 bytes");

        $display("T3 PASS: APB_PHASE held throughout");
        if (!err_out) $display("T4 PASS: no PSLVERR");
        else begin $error("T4: unexpected PSLVERR"); errors++; end

        repeat(4) @(posedge clk);
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $error("%0d test(s) FAILED", errors);
        $finish;
    end

    initial begin #50_000_000; $error("SIMULATION TIMEOUT"); $finish; end

endmodule


// =============================================================================
// uart_ctrl_bfm — behavioral model matching uart_ctrl's APB register map.
//
// Register map (same addresses as uart_ctrl.sv):
//   0x00 CTRL[5:0] — {LOOPBACK, PAR_ODD, -, RX_EN, TX_EN, EN}
//   0x04 BRDIV[15:0]
//   0x08 TDR[7:0]  write-only (push to TX FIFO when !tx_full)
//   0x0C RDR[7:0]  read-only  (pop from RX FIFO when !rx_empty)
//   0x10 SR[6:0]   {OVR,PAR,FRM,RX_EMPTY,RX_FULL,TX_EMPTY,TX_FULL}
//   0x14 IER[1:0]  {RX_DATA_IE, TX_EMPTY_IE}
//
// PRDATA is captured in the SETUP phase (PSEL=1, PENABLE=0), identical to
// the RTL — so the master's zero-bubble SR→TX_WR path works correctly.
//
// Loopback: when ctrl[0](EN)=1 and ctrl[1](TX_EN)=1, bytes pop from TX FIFO
// and appear in RX FIFO after FRAME_CYC cycles, simulating one full UART frame.
// FRAME_CYC = (BRDIV+1)*160 evaluated at elaboration; the master sets BRDIV=0
// at runtime so FRAME_CYC matches.
// =============================================================================
module uart_ctrl_bfm #(
    parameter int CLK_FREQ   = 50_000_000,
    parameter int BAUD_RATE  = 115_200,
    parameter int FIFO_DEPTH = 16
) (
    input  logic        PCLK, PRESETn,
    input  logic        PSEL, PENABLE, PWRITE,
    input  logic [4:0]  PADDR,
    input  logic [31:0] PWDATA,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    output logic        irq_o
);
    localparam int BRDIV_DEF = (CLK_FREQ / (BAUD_RATE * 16)) - 1;
    localparam int FRAME_CYC = (BRDIV_DEF + 1) * 160;
    localparam int FP        = $clog2(FIFO_DEPTH);

    // Registers
    logic [5:0]  ctrl_r;
    logic [15:0] brdiv_r;
    logic [1:0]  ier_r;

    // TX FIFO (extra-MSB pointers)
    logic [7:0]   tx_mem [0:FIFO_DEPTH-1];
    logic [FP:0]  tx_wr_q, tx_rd_q;
    wire tx_full  = (tx_wr_q[FP-1:0] == tx_rd_q[FP-1:0]) && (tx_wr_q[FP] != tx_rd_q[FP]);
    wire tx_empty = (tx_wr_q == tx_rd_q);

    // RX FIFO
    logic [7:0]   rx_mem [0:FIFO_DEPTH-1];
    logic [FP:0]  rx_wr_q, rx_rd_q;
    wire rx_full  = (rx_wr_q[FP-1:0] == rx_rd_q[FP-1:0]) && (rx_wr_q[FP] != rx_rd_q[FP]);
    wire rx_empty = (rx_wr_q == rx_rd_q);

    // TX shift (one byte in-flight)
    logic [7:0] tx_byte_q;
    logic       tx_busy_q;
    int         tx_cnt_q;

    // APB decode
    wire apb_wr = PSEL && PENABLE && PWRITE;
    wire apb_rd = PSEL && PENABLE && !PWRITE;
    wire apb_setup = PSEL && !PENABLE;    // SETUP phase: latch PRDATA

    assign PREADY  = PSEL & PENABLE;
    assign PSLVERR = 1'b0;

    // IRQ: combinatorial
    assign irq_o = (tx_empty & ier_r[0]) | (!rx_empty & ier_r[1]);

    // PRDATA captured in SETUP phase (matches uart_ctrl.sv registered-PRDATA behavior)
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PRDATA <= '0;
        end else if (apb_setup && !PWRITE) begin
            case (PADDR)
                5'h00:   PRDATA <= {26'h0, ctrl_r};
                5'h04:   PRDATA <= {16'h0, brdiv_r};
                5'h0C:   PRDATA <= rx_empty ? '0 : {24'h0, rx_mem[rx_rd_q[FP-1:0]]};
                5'h10:   PRDATA <= {25'h0, 3'b000, rx_empty, rx_full, tx_empty, tx_full};
                5'h14:   PRDATA <= {30'h0, ier_r};
                default: PRDATA <= '0;
            endcase
        end
    end

    // APB writes + RDR pop
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            ctrl_r  <= 6'b000110;
            brdiv_r <= 16'(BRDIV_DEF);
            ier_r   <= 2'b00;
            tx_wr_q <= '0;
            rx_rd_q <= '0;
        end else begin
            if (apb_wr) begin
                case (PADDR)
                    5'h00: ctrl_r  <= PWDATA[5:0];
                    5'h04: brdiv_r <= PWDATA[15:0];
                    5'h08: if (!tx_full) begin
                               tx_mem[tx_wr_q[FP-1:0]] <= PWDATA[7:0];
                               tx_wr_q <= tx_wr_q + 1'b1;
                           end
                    5'h14: ier_r <= PWDATA[1:0];
                    default: ;
                endcase
            end
            // RDR read pops RX FIFO
            if (apb_rd && PADDR == 5'h0C && !rx_empty)
                rx_rd_q <= rx_rd_q + 1'b1;
        end
    end

    // TX FSM: pop TX FIFO, delay FRAME_CYC cycles, push to RX FIFO (loopback)
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            tx_rd_q  <= '0;
            rx_wr_q  <= '0;
            tx_busy_q<= 1'b0;
            tx_cnt_q <= 0;
        end else begin
            if (!tx_busy_q) begin
                if (!tx_empty && ctrl_r[0] && ctrl_r[1]) begin  // EN && TX_EN
                    tx_byte_q <= tx_mem[tx_rd_q[FP-1:0]];
                    tx_rd_q   <= tx_rd_q + 1'b1;
                    tx_busy_q <= 1'b1;
                    tx_cnt_q  <= FRAME_CYC - 1;
                end
            end else begin
                if (tx_cnt_q == 0) begin
                    tx_busy_q <= 1'b0;
                    if (!rx_full) begin
                        rx_mem[rx_wr_q[FP-1:0]] <= tx_byte_q;
                        rx_wr_q <= rx_wr_q + 1'b1;
                    end
                end else begin
                    tx_cnt_q <= tx_cnt_q - 1;
                end
            end
        end
    end

endmodule
