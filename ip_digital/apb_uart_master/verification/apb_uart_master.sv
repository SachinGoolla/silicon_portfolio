// =============================================================================
// apb_uart_master.sv  —  APB3 Master + Byte-Stream Interface for uart_ctrl
// =============================================================================
//
// CONTEXT:
//   Sits above uart_ctrl on the APB bus.  Exposes a byte-stream interface
//   (AXI4-S valid/ready) to system logic and handles all APB3 bus mechanics
//   and uart_ctrl register programming autonomously, including power-on init.
//
// ARCHITECTURE — two nested FSMs:
//
//   ┌──────────────────────────────────────────────────────────────────────┐
//   │  apb_uart_master                                                     │
//   │                                                                      │
//   │  ┌──────────┐  cmd  ┌──────────────────┐  APB3  ┌───────────────┐  │
//   │  │ Sequencer│──────▶│   APB engine     │───────▶│  uart_ctrl    │  │
//   │  │ (7-state)│◀──────│ IDLE/SETUP/      │◀───────│  APB slave    │  │
//   │  └──────────┘  done │ ACCESS           │        └───────────────┘  │
//   │       │  ▲           └──────────────────┘                           │
//   │   push│  │pop          irq_i ─▲                                     │
//   │       ▼  │                    │                                     │
//   │  ┌──────────┐   ┌──────────────┐                                    │
//   │  │ TX FIFO  │   │  RX FIFO     │                                    │
//   │  │(TX_DEPTH)│   │ (RX_DEPTH)   │                                    │
//   │  └──────────┘   └──────────────┘                                    │
//   │       ▲                  │                                           │
//   └───────┼──────────────────┼────────────────────────────────────────  ┘
//         tx_stream          rx_stream
//         (valid/ready)      (valid/ready)
//
// APB ENGINE — zero-bubble back-to-back:
//   IDLE   → SETUP  when cmd_valid                  (PSEL rises)
//   SETUP  → ACCESS one cycle later                 (PENABLE rises)
//   ACCESS → SETUP  when PREADY && cmd_valid_next   (zero-bubble!)
//          → IDLE   when PREADY && !cmd_valid_next
//
//   cmd is driven from seq_NEXT (combinational).  The instant apb_done fires,
//   seq_next holds the next state and its cmd — the APB engine latches it
//   directly, skipping the IDLE cycle.  Result: back-to-back init writes
//   (BRDIV→IER→CTRL) cost 2 cycles each, not 3.  Same for SR_RD→TX_WR.
//
// SEQUENCER:
//   INIT_BRDIV → INIT_IER → INIT_CTRL (three back-to-back APB writes)
//   → IDLE → SR_RD → TX_WR  (one byte per TX_EMPTY IRQ)
//                  → RX_RD  (one byte per RX_DATA IRQ)
//                  → IDLE   (nothing to do)
//
// INIT sequence programs uart_ctrl before asserting init_done_o:
//   BRDIV ← CLK_FREQ / (BAUD_RATE × 16) − 1
//   IER   ← RX_DATA_IE only (TX_EMPTY_IE intentionally disabled; see IRQ HANDLING)
//   CTRL  ← TX_EN | RX_EN | EN  (or CTRL_WORD parameter override)
//
// IRQ HANDLING:
//   IER is initialised with RX_DATA_IE only (TX_EMPTY_IE=0).  This keeps
//   irq_i deasserted during TX transit time, so a simple irq_i level check
//   in IDLE is sufficient — no edge detection needed, no busy-loop possible.
//   TX dispatch is driven by !txf_empty; RX dispatch is driven by irq_i.
//
// TIMING:
//   All APB outputs (PSEL, PENABLE, PADDR, PWRITE, PWDATA) are registered.
//   Critical path: apb_q FF → PENABLE output (≈ 1 FF delay).
//   The seq_next → cmd → APB latch path closes comfortably at 100 MHz sky130.
//
// =============================================================================

`timescale 1ns/1ps

module apb_uart_master #(
    parameter int          CLK_FREQ  = 50_000_000,  // system clock [Hz]
    parameter int          BAUD_RATE = 115_200,      // target baud rate [bps]
    parameter int          TX_DEPTH  = 8,            // internal TX FIFO depth (power-of-2)
    parameter int          RX_DEPTH  = 8,            // internal RX FIFO depth (power-of-2)
    parameter logic [31:0] CTRL_WORD = 32'h07        // CTRL init: TX_EN|RX_EN|EN; set bit5 for loopback
) (
    input  logic        clk,
    input  logic        rst_n,

    // ── TX byte-stream (AXI4-S valid/ready) ───────────────────────────────
    input  logic [7:0]  tx_data_i,
    input  logic        tx_valid_i,
    output logic        tx_ready_o,

    // ── RX byte-stream ─────────────────────────────────────────────────────
    output logic [7:0]  rx_data_o,
    output logic        rx_valid_o,
    input  logic        rx_ready_i,

    // ── APB3 master port (connect directly to uart_ctrl APB slave) ─────────
    output logic        PSEL,
    output logic        PENABLE,
    output logic        PWRITE,
    output logic [4:0]  PADDR,
    output logic [31:0] PWDATA,
    input  logic [31:0] PRDATA,
    input  logic        PREADY,
    input  logic        PSLVERR,

    // ── uart_ctrl IRQ ───────────────────────────────────────────────────────
    input  logic        irq_i,

    // ── Status ──────────────────────────────────────────────────────────────
    output logic        init_done_o,  // asserts after CTRL write; sticky
    output logic        err_o         // sticky: PSLVERR seen on any transaction
);

    // ── uart_ctrl register map ─────────────────────────────────────────────
    localparam logic [4:0] A_CTRL  = 5'h00;
    localparam logic [4:0] A_BRDIV = 5'h04;
    localparam logic [4:0] A_TDR   = 5'h08;
    localparam logic [4:0] A_RDR   = 5'h0C;
    localparam logic [4:0] A_SR    = 5'h10;
    localparam logic [4:0] A_IER   = 5'h14;

    // SR bit indices — untyped so Verilator accepts them as constant bit-select indices
    localparam SR_TX_FULL  = 0;
    localparam SR_RX_EMPTY = 3;

    localparam int BRDIV_VAL = (CLK_FREQ / (BAUD_RATE * 16)) - 1;

    // =========================================================================
    // TX FIFO  —  extra-MSB full/empty (identical pattern to uart_fifo.sv)
    // =========================================================================
    localparam int TXP = $clog2(TX_DEPTH);

    logic [7:0]   txf_mem [0:TX_DEPTH-1];
    logic [TXP:0] txf_wr_q, txf_rd_q;

    wire txf_full  = (txf_wr_q[TXP-1:0] == txf_rd_q[TXP-1:0]) && (txf_wr_q[TXP] != txf_rd_q[TXP]);
    wire txf_empty = (txf_wr_q == txf_rd_q);
    wire [7:0] txf_head = txf_mem[txf_rd_q[TXP-1:0]];

    assign tx_ready_o = !txf_full;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) txf_wr_q <= '0;
        else if (tx_valid_i && !txf_full) begin
            txf_mem[txf_wr_q[TXP-1:0]] <= tx_data_i;
            txf_wr_q <= txf_wr_q + 1'b1;
        end
    end

    // =========================================================================
    // RX FIFO
    // =========================================================================
    localparam int RXP = $clog2(RX_DEPTH);

    logic [7:0]   rxf_mem [0:RX_DEPTH-1];
    logic [RXP:0] rxf_wr_q, rxf_rd_q;

    wire rxf_full  = (rxf_wr_q[RXP-1:0] == rxf_rd_q[RXP-1:0]) && (rxf_wr_q[RXP] != rxf_rd_q[RXP]);
    wire rxf_empty = (rxf_wr_q == rxf_rd_q);

    assign rx_data_o  = rxf_mem[rxf_rd_q[RXP-1:0]];
    assign rx_valid_o = !rxf_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rxf_rd_q <= '0;
        else if (!rxf_empty && rx_ready_i) rxf_rd_q <= rxf_rd_q + 1'b1;
    end

    // =========================================================================
    // Sequencer FSM
    // =========================================================================
    typedef enum logic [2:0] {
        SEQ_INIT_BRDIV = 3'd0,
        SEQ_INIT_IER   = 3'd1,
        SEQ_INIT_CTRL  = 3'd2,
        SEQ_IDLE       = 3'd3,
        SEQ_SR_RD      = 3'd4,
        SEQ_TX_WR      = 3'd5,
        SEQ_RX_RD      = 3'd6
    } seq_st_e;

    seq_st_e seq_q, seq_next;

    // APB completion wire (used in sequencer comb)
    wire apb_done;

    // Sequencer next-state (combinational)
    // TX dispatch: !txf_empty triggers SR_RD (no IRQ needed for TX).
    // RX dispatch: irq_i level triggers SR_RD (IER has only RX_DATA_IE, so
    //              irq_i is 0 during TX transit and rises exactly when a byte lands).
    always_comb begin
        seq_next = seq_q;
        case (seq_q)
            SEQ_INIT_BRDIV: if (apb_done) seq_next = SEQ_INIT_IER;
            SEQ_INIT_IER:   if (apb_done) seq_next = SEQ_INIT_CTRL;
            SEQ_INIT_CTRL:  if (apb_done) seq_next = SEQ_IDLE;
            SEQ_IDLE:       if (irq_i || !txf_empty) seq_next = SEQ_SR_RD;
            SEQ_SR_RD: begin
                if (apb_done) begin
                    if      (!PRDATA[SR_TX_FULL] && !txf_empty) seq_next = SEQ_TX_WR;
                    else if (!PRDATA[SR_RX_EMPTY])              seq_next = SEQ_RX_RD;
                    else                                         seq_next = SEQ_IDLE;
                end
            end
            SEQ_TX_WR: if (apb_done) seq_next = SEQ_IDLE;
            // After each RX byte, re-check SR immediately (zero-bubble SR_RD)
            // so consecutive bytes drain without waiting for a new irq_rise.
            SEQ_RX_RD: if (apb_done) seq_next = SEQ_SR_RD;
            default:   seq_next = SEQ_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) seq_q <= SEQ_INIT_BRDIV;
        else        seq_q <= seq_next;
    end

    // init_done: sticky after CTRL write
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) init_done_o <= 1'b0;
        else if (seq_q == SEQ_INIT_CTRL && apb_done) init_done_o <= 1'b1;
    end

    // TX FIFO pop: advance rd_ptr after TDR write completes
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) txf_rd_q <= '0;
        else if (seq_q == SEQ_TX_WR && apb_done) txf_rd_q <= txf_rd_q + 1'b1;
    end

    // RX FIFO push: capture RDR byte when read completes; drop if full (overflow protection)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rxf_wr_q <= '0;
        else if (seq_q == SEQ_RX_RD && apb_done && !rxf_full) begin
            rxf_mem[rxf_wr_q[RXP-1:0]] <= PRDATA[7:0];
            rxf_wr_q <= rxf_wr_q + 1'b1;
        end
    end

    // =========================================================================
    // cmd MUX — driven from seq_NEXT for zero-bubble back-to-back transfers.
    // When apb_done fires, seq_next already reflects the upcoming transaction;
    // the APB engine latches it directly without passing through IDLE.
    // =========================================================================
    logic        cmd_valid, cmd_wr;
    logic [4:0]  cmd_addr;
    logic [31:0] cmd_wdata;

    always_comb begin
        cmd_valid = 1'b0; cmd_wr = 1'b0; cmd_addr = '0; cmd_wdata = '0;
        case (seq_next)
            SEQ_INIT_BRDIV: begin cmd_valid = 1'b1; cmd_wr = 1'b1; cmd_addr = A_BRDIV; cmd_wdata = 32'(BRDIV_VAL); end
            SEQ_INIT_IER:   begin cmd_valid = 1'b1; cmd_wr = 1'b1; cmd_addr = A_IER;   cmd_wdata = 32'h02; end
            SEQ_INIT_CTRL:  begin cmd_valid = 1'b1; cmd_wr = 1'b1; cmd_addr = A_CTRL;  cmd_wdata = CTRL_WORD; end
            SEQ_SR_RD:      begin cmd_valid = 1'b1; cmd_wr = 1'b0; cmd_addr = A_SR; end
            SEQ_TX_WR:      begin cmd_valid = 1'b1; cmd_wr = 1'b1; cmd_addr = A_TDR;   cmd_wdata = {24'h0, txf_head}; end
            SEQ_RX_RD:      begin cmd_valid = 1'b1; cmd_wr = 1'b0; cmd_addr = A_RDR; end
            default: ; // SEQ_IDLE: cmd_valid stays 0
        endcase
    end

    // =========================================================================
    // APB Engine — IDLE / SETUP / ACCESS
    // =========================================================================
    typedef enum logic [1:0] {
        APB_IDLE   = 2'd0,
        APB_SETUP  = 2'd1,
        APB_ACCESS = 2'd2
    } apb_st_e;

    apb_st_e apb_q;

    assign apb_done = (apb_q == APB_ACCESS) && PREADY;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            apb_q   <= APB_IDLE;
            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b0;
            PADDR   <= '0;
            PWDATA  <= '0;
            err_o   <= 1'b0;
        end else begin
            case (apb_q)
                APB_IDLE: begin
                    if (cmd_valid) begin
                        // Latch command; drive SETUP phase
                        PSEL    <= 1'b1;
                        PENABLE <= 1'b0;
                        PWRITE  <= cmd_wr;
                        PADDR   <= cmd_addr;
                        PWDATA  <= cmd_wdata;
                        apb_q   <= APB_SETUP;
                    end
                end

                APB_SETUP: begin
                    PENABLE <= 1'b1;   // assert ENABLE; slave samples this cycle
                    apb_q   <= APB_ACCESS;
                end

                APB_ACCESS: begin
                    if (PREADY) begin
                        if (PSLVERR) err_o <= 1'b1;
                        // cmd reflects seq_next (updated combinationally on apb_done).
                        // If next command already known, go straight to SETUP — zero bubble.
                        if (cmd_valid) begin
                            PSEL    <= 1'b1;
                            PENABLE <= 1'b0;
                            PWRITE  <= cmd_wr;
                            PADDR   <= cmd_addr;
                            PWDATA  <= cmd_wdata;
                            apb_q   <= APB_SETUP;
                        end else begin
                            PSEL    <= 1'b0;
                            PENABLE <= 1'b0;
                            apb_q   <= APB_IDLE;
                        end
                    end
                end

                default: apb_q <= APB_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Formal verification properties
    // =========================================================================
    `ifdef FORMAL
        // F1 — APB phase ordering: PENABLE requires PSEL
        APB_PHASE: assert property (
            @(posedge clk) disable iff (!rst_n)
            PENABLE |-> PSEL
        );

        // F2 — APB3 address and write-enable stable through the ACCESS phase
        APB_STABLE_ADDR: assert property (
            @(posedge clk) disable iff (!rst_n)
            (apb_q == APB_ACCESS) |-> (PADDR == $past(PADDR))
        );

        APB_STABLE_WRITE: assert property (
            @(posedge clk) disable iff (!rst_n)
            (apb_q == APB_ACCESS) |-> (PWRITE == $past(PWRITE))
        );

        // F3 — Only legal uart_ctrl addresses ever asserted on PADDR
        APB_LEGAL_ADDR: assert property (
            @(posedge clk) disable iff (!rst_n)
            PSEL |-> (PADDR inside {A_CTRL, A_BRDIV, A_TDR, A_RDR, A_SR, A_IER})
        );

        // F4 — init_done_o is sticky: once asserted, never de-asserts
        INIT_STICKY: assert property (
            @(posedge clk) disable iff (!rst_n)
            $rose(init_done_o) |=> init_done_o
        );

        // F5 — TDR write only when TX FIFO has a byte (no spurious writes)
        TX_WR_VALID: assert property (
            @(posedge clk) disable iff (!rst_n)
            (seq_q == SEQ_TX_WR) |-> !txf_empty
        );

        // Reachability covers
        COV_INIT_DONE: cover property (@(posedge clk)  init_done_o);
        COV_TX_WR:     cover property (@(posedge clk) (seq_q == SEQ_TX_WR));
        COV_RX_RD:     cover property (@(posedge clk) (seq_q == SEQ_RX_RD));
        COV_ZBB:       cover property (@(posedge clk) (apb_q == APB_ACCESS && PREADY && cmd_valid));
    `endif

endmodule
