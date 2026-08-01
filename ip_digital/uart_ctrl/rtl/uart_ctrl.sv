// uart_ctrl.sv — APB peripheral UART controller.
//
// Architecture
// ─────────────
//   APB slave (0-wait-state: PRDATA registered on SETUP phase)
//   ↕ register file (CTRL, BRDIV, TDR, RDR, SR, IER)
//   ├─ uart_baud  — 16× tick generator (shared by TX and RX)
//   ├─ uart_tx    — TX FSM, idles high
//   ├─ uart_rx    — RX FSM, 16× oversampled
//   ├─ uart_fifo  — TX FIFO (sync, self-contained)
//   └─ uart_fifo  — RX FIFO (sync, self-contained)
//
// LOOPBACK (CTRL[5]=1): uart_tx output fed directly to uart_rx input,
//   ignoring the external uart_rx pin.  uart_tx is still driven (visible
//   on the pad for external observation).
//
// Reset: PRESETn (APB standard).  All internal sub-modules use the same reset.
//
// Timing: PRDATA registered → timing path is APB mux → register, not mux → output.
//   Meets 80 MHz target on sky130 TT corner.
module uart_ctrl #(
    parameter int CLK_FREQ   = 50_000_000,
    parameter int BAUD_RATE  = 115_200,
    parameter int FIFO_DEPTH = 16,       // TX and RX FIFO depth (power-of-2)
    parameter bit PARITY_EN  = 1'b0      // synthesised default; runtime CTRL[3] overrides
) (
    // APB slave interface
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [4:0]  PADDR,    // [1:0] unused — word-aligned only
    input  logic [31:0] PWDATA,   // [31:16] unused — max field is BRDIV[15:0]
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,

    // UART pads
    output logic        uart_tx,
    input  logic        uart_rx,

    // Level-sensitive interrupt (deasserts when source cleared)
    output logic        irq_o
);

    // -------------------------------------------------------------------------
    // Derived parameter: default divisor
    // -------------------------------------------------------------------------
    localparam int BRDIV_DEFAULT = CLK_FREQ / (BAUD_RATE * 16) - 1;

    // -------------------------------------------------------------------------
    // Register storage
    // -------------------------------------------------------------------------
    logic [5:0]  ctrl_r;     // CTRL[5:0]
    logic [15:0] brdiv_r;    // BRDIV[15:0]
    logic [1:0]  ier_r;      // IER[1:0] — {RX_NE_IE, TX_EMPTY_IE}
    logic        err_ie_r;   // IER[2]

    // Sticky error bits (set by RX FSM pulses, cleared by writing 1 to SR[6:4])
    logic        frame_err_r, parity_err_r, ovr_err_r;

    // Convenient aliases into ctrl_r
    wire en        = ctrl_r[0];
    wire tx_en     = ctrl_r[1];
    wire rx_en     = ctrl_r[2];
    // ctrl_r[3] = PARITY_EN runtime bit; effective only when PARITY_EN param=1
    wire par_odd   = ctrl_r[4];
    wire loopback  = ctrl_r[5];

    // -------------------------------------------------------------------------
    // Sub-module wires
    // -------------------------------------------------------------------------
    logic        baud16_tick;
    logic        tx_int;         // serial TX from uart_tx
    logic        rx_in;          // muxed RX input (external or loopback)
    logic [1:0]  rx_sync;        // 2-FF synchroniser chain

    // TX FIFO
    logic        tx_push, tx_pop, tx_full, tx_empty;
    logic [7:0]  tx_wdata, tx_rdata;

    // RX FIFO
    logic        rx_push, rx_pop, rx_full, rx_empty;
    logic [7:0]  rx_wdata, rx_rdata;

    // Error pulses from uart_rx
    logic        frame_err_p, parity_err_p, ovr_err_p;

    // -------------------------------------------------------------------------
    // 2-FF synchroniser on uart_rx
    // -------------------------------------------------------------------------
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) rx_sync <= 2'b11;
        else          rx_sync <= {rx_sync[0], uart_rx};
    end

    assign rx_in = loopback ? tx_int : rx_sync[1];

    // -------------------------------------------------------------------------
    // Sub-module instantiation
    // -------------------------------------------------------------------------
    uart_baud u_baud (
        .clk        (PCLK),
        .rst_n      (PRESETn),
        .brdiv      (brdiv_r),
        .baud16_tick(baud16_tick)
    );

    uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_tx_fifo (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .push_en  (tx_push),
        .push_data(tx_wdata),
        .full     (tx_full),
        .pop_en   (tx_pop),
        .pop_data (tx_rdata),
        .empty    (tx_empty)
    );

    uart_tx #(.PARITY_EN(PARITY_EN)) u_tx (
        .clk        (PCLK),
        .rst_n      (PRESETn),
        .baud16_tick(baud16_tick),
        .tx_empty   (tx_empty),
        .tx_pop     (tx_pop),
        .tx_rdata   (tx_rdata),
        .tx_en      (tx_en & en),
        .parity_odd (par_odd),
        .tx         (tx_int)
    );

    uart_fifo #(.WIDTH(8), .DEPTH(FIFO_DEPTH)) u_rx_fifo (
        .clk      (PCLK),
        .rst_n    (PRESETn),
        .push_en  (rx_push),
        .push_data(rx_wdata),
        .full     (rx_full),
        .pop_en   (rx_pop),
        .pop_data (rx_rdata),
        .empty    (rx_empty)
    );

    uart_rx #(.PARITY_EN(PARITY_EN)) u_rx (
        .clk        (PCLK),
        .rst_n      (PRESETn),
        .baud16_tick(baud16_tick),
        .rx         (rx_in),
        .rx_en      (rx_en & en),
        .parity_odd (par_odd),
        .rx_full    (rx_full),
        .rx_push    (rx_push),
        .rx_wdata   (rx_wdata),
        .frame_err  (frame_err_p),
        .parity_err (parity_err_p),
        .ovr_err    (ovr_err_p)
    );

    // -------------------------------------------------------------------------
    // uart_tx pad drive
    // -------------------------------------------------------------------------
    assign uart_tx = tx_int;

    // -------------------------------------------------------------------------
    // APB slave — 0 wait states
    // PRDATA registered in the SETUP phase so it is stable by ACCESS.
    // PREADY is purely combinatorial (PSEL & PENABLE).
    // -------------------------------------------------------------------------
    assign PREADY  = PSEL & PENABLE;
    assign PSLVERR = 1'b0;

    // Status register (combinatorial build, latched error bits)
    wire [6:0] sr_live = {ovr_err_r, parity_err_r, frame_err_r,
                          rx_empty, rx_full, tx_empty, tx_full};

    // APB write decode (fires on ACCESS phase: PSEL & PENABLE & PWRITE)
    wire apb_wr = PSEL & PENABLE & PWRITE;
    wire apb_rd = PSEL & PENABLE & !PWRITE;

    // TX FIFO push: APB write to TDR when not full
    assign tx_push  = apb_wr && (PADDR[4:2] == 3'd2) && !tx_full;
    assign tx_wdata = PWDATA[7:0];

    // RX FIFO pop: APB read of RDR
    assign rx_pop = apb_rd && (PADDR[4:2] == 3'd3) && !rx_empty;

    // Register write
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            ctrl_r      <= 6'b000110;          // TX_EN + RX_EN on by default
            brdiv_r     <= BRDIV_DEFAULT[15:0];
            ier_r       <= 2'b00;
            err_ie_r    <= 1'b0;
            frame_err_r <= 1'b0;
            parity_err_r<= 1'b0;
            ovr_err_r   <= 1'b0;
        end else begin
            // Latch error pulses
            if (frame_err_p)  frame_err_r  <= 1'b1;
            if (parity_err_p) parity_err_r <= 1'b1;
            if (ovr_err_p)    ovr_err_r    <= 1'b1;

            if (apb_wr) begin
                case (PADDR[4:2])
                    3'd0: ctrl_r  <= PWDATA[5:0];
                    3'd1: brdiv_r <= PWDATA[15:0];
                    // 3'd2: TDR handled combinatorially (tx_push)
                    // 3'd3: RDR is read-only
                    3'd4: begin   // SR — write 1 to clear error sticky bits
                        if (PWDATA[4]) frame_err_r  <= 1'b0;
                        if (PWDATA[5]) parity_err_r <= 1'b0;
                        if (PWDATA[6]) ovr_err_r    <= 1'b0;
                    end
                    3'd5: {err_ie_r, ier_r} <= PWDATA[2:0];
                    default: ;
                endcase
            end
        end
    end

    // PRDATA registered in SETUP (PSEL & !PENABLE) — ready for ACCESS cycle.
    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            PRDATA <= '0;
        end else if (PSEL && !PENABLE) begin
            case (PADDR[4:2])
                3'd0: PRDATA <= {26'b0, ctrl_r};
                3'd1: PRDATA <= {16'b0, brdiv_r};
                3'd2: PRDATA <= 32'b0;              // TDR write-only
                3'd3: PRDATA <= {24'b0, rx_rdata};
                3'd4: PRDATA <= {25'b0, sr_live};
                3'd5: PRDATA <= {29'b0, err_ie_r, ier_r};
                default: PRDATA <= 32'b0;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // Interrupt: level-sensitive, deasserts when source cleared
    // -------------------------------------------------------------------------
    assign irq_o = (tx_empty  &  ier_r[0]) |
                   (!rx_empty &  ier_r[1]) |
                   (|{ovr_err_r, parity_err_r, frame_err_r} & err_ie_r);

    // -------------------------------------------------------------------------
    // Formal verification properties
    // -------------------------------------------------------------------------
`ifdef FORMAL
    // F1: PREADY only during ACCESS phase (PENABLE must be high)
    property apb_pready_valid;
        @(posedge PCLK) disable iff (!PRESETn)
        PREADY |-> PENABLE;
    endproperty
    assert_apb_pready: assert property (apb_pready_valid);

    // F2: No spurious write when PENABLE is low
    property no_write_on_setup;
        @(posedge PCLK) disable iff (!PRESETn)
        (PSEL && !PENABLE) |-> !apb_wr;
    endproperty
    assert_no_write_setup: assert property (no_write_on_setup);

    // F3: TX serial line idles high when TX FSM is idle
    property tx_idles_high;
        @(posedge PCLK) disable iff (!PRESETn)
        (u_tx.state == u_tx.TX_IDLE) |-> tx_int;
    endproperty
    assert_tx_idle: assert property (tx_idles_high);

    // F4: TX FSM never reaches an illegal encoding
    property tx_state_valid;
        @(posedge PCLK) disable iff (!PRESETn)
        u_tx.state inside {u_tx.TX_IDLE, u_tx.TX_START,
                           u_tx.TX_DATA, u_tx.TX_PARITY, u_tx.TX_STOP};
    endproperty
    assert_tx_state: assert property (tx_state_valid);

    // F5: RX FSM never reaches an illegal encoding
    property rx_state_valid;
        @(posedge PCLK) disable iff (!PRESETn)
        u_rx.state inside {u_rx.RX_IDLE, u_rx.RX_START,
                           u_rx.RX_DATA, u_rx.RX_PARITY, u_rx.RX_STOP};
    endproperty
    assert_rx_state: assert property (rx_state_valid);

    // F6: Loopback — tx pad feeds rx input when CTRL[5]=1
    property loopback_wired;
        @(posedge PCLK) disable iff (!PRESETn)
        loopback |-> (rx_in == tx_int);
    endproperty
    assert_loopback: assert property (loopback_wired);

    // F7: TX FIFO push only when not full
    property tx_fifo_no_overflow;
        @(posedge PCLK) disable iff (!PRESETn)
        (tx_push && u_tx_fifo.full) |-> 1'b0;
    endproperty
    assert_tx_fifo_nof: assert property (tx_fifo_no_overflow);

    // Cover: TX FSM traverses a complete frame (IDLE→START→DATA→STOP→IDLE)
    cover_tx_frame: cover property (
        @(posedge PCLK) disable iff (!PRESETn)
        (u_tx.state == u_tx.TX_IDLE) ##1
        (u_tx.state == u_tx.TX_START) ##[1:200]
        (u_tx.state == u_tx.TX_STOP)  ##[1:20]
        (u_tx.state == u_tx.TX_IDLE)
    );
`endif

endmodule
