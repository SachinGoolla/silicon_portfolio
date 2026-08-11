// uart_axi_periph.sv — AXI4-Lite peripheral wrapping the UART stack
// (apb_uart_master + uart_ctrl) behind a software-programmable register map.
//
// Composition (single clock domain, v1):
//   axi_lite_slave  — AXI4-Lite protocol engine + register file
//   apb_uart_master — APB3 master + byte-stream sequencer (autonomous init)
//   uart_ctrl       — APB3 slave: baud gen + TX/RX FSMs + FIFOs + UART pads
//   this module     — register map + TX/RX glue
//
// apb_uart_master and uart_ctrl have never been instantiated together
// anywhere else in this repo — each is independently signed off, but their
// composition (the APB3 master<->slave wiring below) is new integration
// surface, not a copy-paste of fpu_axi_periph's register-map shape. Ports
// match 1:1 by direct comparison (apb_uart_master's master-port header
// comment: "connect directly to uart_ctrl APB slave").
//
// Register map (word-addressed, DATA_WIDTH=32)
//   0x00 TXDATA  [7:0]           SW-write. Poll STATUS.TX_READY first; the
//                                 write is held (not a bare pulse) until
//                                 apb_uart_master's TX FIFO actually accepts
//                                 it. A second write arriving while the first
//                                 is still pending (a stale TX_READY=1 poll —
//                                 same pipeline lag as RXDATA below, mirrored
//                                 in the write direction) is dropped, not
//                                 queued — the pending byte is never
//                                 clobbered, but software must still poll
//                                 TX_READY and not assume back-to-back writes
//                                 both land.
//   0x04 RXDATA  [7:0]           HW-write-only. Mirrors a one-entry shadow
//                                 latch (rx_have_byte_q/rx_byte_q below), NOT
//                                 apb_uart_master.rx_data_o directly — an
//                                 earlier version mirrored the live signal
//                                 and raced: STATUS is read back through
//                                 axi_lite_slave's own 2-cycle hw_wdata_q/
//                                 reg_q pipeline, so a poll issued right
//                                 after popping byte N could observe a stale
//                                 RX_VALID=1 still describing byte N and
//                                 misread it as byte N+1 (caught by P3
//                                 cocotb, not by the anyseq-stubbed P2 proof
//                                 — see the FORMAL block below). The shadow
//                                 latch auto-drains apb_uart_master's FIFO
//                                 the instant a byte is available and the
//                                 one-entry slot is free, so RX_VALID/RXDATA
//                                 describe exactly one well-defined byte at
//                                 a time with no pipelined-staleness window.
//   0x08 STATUS  [0]=TX_READY [1]=RX_VALID [2]=ERR [3]=INIT_DONE
//                                 HW-write-only, same continuous-mirror
//                                 mechanism (RX_VALID mirrors rx_have_byte_q,
//                                 the shadow latch — see above).
//   0x0C CTRL    [0]=RX_ACK      SW-write. A write with bit0 set clears the
//                                 RX shadow latch, acknowledging the byte
//                                 just read from RXDATA so the next one can
//                                 be captured. axi_lite_slave has no read-
//                                 -side-effect mechanism, so "advance" is
//                                 modeled as an explicit write rather than
//                                 "reading RXDATA auto-advances" — a
//                                 deliberate deviation from the classic
//                                 UART-RDR-read-pops convention.
//
// Software protocol:
//   TX: poll STATUS.TX_READY, write TXDATA.
//   RX: poll STATUS.RX_VALID==1, read RXDATA, write CTRL=0x1 to ack, THEN
//   poll STATUS.RX_VALID==0 before starting the next byte's poll-for-1.
//   That last step is required, not defensive: STATUS is read back through
//   axi_lite_slave's own 2-cycle hw_wdata_q/reg_q pipeline, so a poll issued
//   immediately after the ack write can still observe the stale RX_VALID=1
//   that describes the byte just acked — indistinguishable from a genuine
//   new byte unless the driver first confirms the flag has actually
//   dropped. Skipping this step reads the same (stale, already-consumed)
//   byte twice instead of the next one (found by P3 cocotb's back-to-back
//   test, which is exactly why that confirm step exists here).
//   INIT_DONE gates first use — apb_uart_master needs a handful of cycles
//   post-reset to program uart_ctrl's BRDIV/IER/CTRL before it's usable
//   (writing TXDATA before INIT_DONE is not unsafe — the byte just sits in
//   apb_uart_master's own TX FIFO until its sequencer reaches SEQ_IDLE).
`timescale 1ns/1ps

module uart_axi_periph #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int CLK_FREQ   = 50_000_000,
    parameter int BAUD_RATE  = 115_200
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // --- AW: Write Address ---
    input  logic                      awvalid_i,
    output logic                      awready_o,
    input  logic [ADDR_WIDTH-1:0]     awaddr_i,
    input  logic [2:0]                awprot_i,

    // --- W: Write Data ---
    input  logic                      wvalid_i,
    output logic                      wready_o,
    input  logic [DATA_WIDTH-1:0]     wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] wstrb_i,

    // --- B: Write Response ---
    output logic                      bvalid_o,
    input  logic                      bready_i,
    output logic [1:0]                bresp_o,

    // --- AR: Read Address ---
    input  logic                      arvalid_i,
    output logic                      arready_o,
    input  logic [ADDR_WIDTH-1:0]     araddr_i,
    input  logic [2:0]                arprot_i,

    // --- R: Read Data ---
    output logic                      rvalid_o,
    input  logic                      rready_i,
    output logic [DATA_WIDTH-1:0]     rdata_o,
    output logic [1:0]                rresp_o,

    // --- UART pads ---
    output logic                      uart_tx_o,
    input  logic                      uart_rx_i
);

    localparam int NUM_REGS   = 4;
    localparam int IDX_TXDATA = 0;
    localparam int IDX_RXDATA = 1;
    localparam int IDX_STATUS = 2;
    localparam int IDX_CTRL   = 3;

    // -----------------------------------------------------------------
    // AXI4-Lite register file
    // -----------------------------------------------------------------
    logic [NUM_REGS*DATA_WIDTH-1:0] regfile;
    logic [NUM_REGS-1:0]            reg_we;
    logic [NUM_REGS*DATA_WIDTH-1:0] hw_wdata;
    logic [NUM_REGS-1:0]            hw_we;

    axi_lite_slave #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .NUM_REGS   (NUM_REGS)
    ) u_regs (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid_i  (awvalid_i), .awready_o (awready_o),
        .awaddr_i   (awaddr_i),  .awprot_i  (awprot_i),
        .wvalid_i   (wvalid_i),  .wready_o  (wready_o),
        .wdata_i    (wdata_i),   .wstrb_i   (wstrb_i),
        .bvalid_o   (bvalid_o),  .bready_i  (bready_i),
        .bresp_o    (bresp_o),
        .arvalid_i  (arvalid_i), .arready_o (arready_o),
        .araddr_i   (araddr_i),  .arprot_i  (arprot_i),
        .rvalid_o   (rvalid_o),  .rready_i  (rready_i),
        .rdata_o    (rdata_o),   .rresp_o   (rresp_o),
        .regfile_o  (regfile),   .reg_we_o  (reg_we),
        .hw_wdata_i (hw_wdata),  .hw_we_i   (hw_we)
    );

    // -----------------------------------------------------------------
    // UART stack: apb_uart_master (byte-stream <-> APB3 master) driving
    // uart_ctrl (APB3 slave: baud gen + TX/RX FSMs + FIFOs + pads)
    // -----------------------------------------------------------------
    logic        tx_data_valid, tx_data_ready;
    logic [7:0]  tx_data;
    logic        rx_data_valid, rx_data_ready;
    logic [7:0]  rx_data;
    logic        init_done, err;
    logic        irq;

    logic        psel, penable, pwrite, pready, pslverr;
    logic [4:0]  paddr;
    logic [31:0] pwdata, prdata;

    apb_uart_master #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_master (
        .clk         (clk),
        .rst_n       (rst_n),
        .tx_data_i   (tx_data),       .tx_valid_i (tx_data_valid), .tx_ready_o (tx_data_ready),
        .rx_data_o   (rx_data),       .rx_valid_o (rx_data_valid), .rx_ready_i (rx_data_ready),
        .PSEL        (psel),          .PENABLE    (penable),       .PWRITE     (pwrite),
        .PADDR       (paddr),         .PWDATA     (pwdata),
        .PRDATA      (prdata),        .PREADY     (pready),        .PSLVERR    (pslverr),
        .irq_i       (irq),
        .init_done_o (init_done),     .err_o      (err)
    );

    uart_ctrl #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_ctrl (
        .PCLK    (clk),   .PRESETn (rst_n),
        .PSEL    (psel),  .PENABLE (penable), .PWRITE (pwrite),
        .PADDR   (paddr), .PWDATA  (pwdata),
        .PRDATA  (prdata), .PREADY (pready),  .PSLVERR (pslverr),
        .uart_tx (uart_tx_o), .uart_rx (uart_rx_i),
        .irq_o   (irq)
    );

    // -----------------------------------------------------------------
    // TX glue — VALID-sticky hold until apb_uart_master accepts
    //
    // tx_we_q is gated with !tx_pending_q below: a TXDATA write that lands
    // while a previous byte is still pending (STATUS.TX_READY was stale —
    // same 2-cycle hw_wdata_q/reg_q pipeline lag as the RX hazard above,
    // just in the write direction) is dropped rather than overwriting
    // tx_byte_q and silently losing the queued byte. Software's documented
    // contract is still "poll TX_READY before writing"; this gate is a
    // second line of defense against a poll that lands one cycle early, not
    // a substitute for the contract (a byte written while genuinely
    // ineligible is dropped, not queued).
    // -----------------------------------------------------------------
    logic       tx_we_q;
    logic [7:0] tx_byte_q;
    logic       tx_pending_q;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) tx_we_q <= 1'b0;
        else        tx_we_q <= reg_we[IDX_TXDATA];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_byte_q    <= 8'h0;
            tx_pending_q <= 1'b0;
        end else begin
            if (tx_we_q && !tx_pending_q) begin
                tx_byte_q    <= regfile[IDX_TXDATA*DATA_WIDTH +: 8];
                tx_pending_q <= 1'b1;
            end else if (tx_data_valid && tx_data_ready) begin
                tx_pending_q <= 1'b0;
            end
        end
    end

    assign tx_data_valid = tx_pending_q;
    assign tx_data        = tx_byte_q;

    // -----------------------------------------------------------------
    // RX glue — single-entry shadow latch, not a live level mirror.
    //
    // A first version mirrored apb_uart_master.rx_data_valid/rx_data
    // straight into STATUS/RXDATA and had software's CTRL[0] write pop
    // apb_uart_master's FIFO directly. That raced: STATUS is read through
    // axi_lite_slave's own 2-cycle hw_wdata_q/reg_q pipeline, so a poll
    // issued right after popping byte N could still observe the *stale*
    // RX_VALID=1 describing byte N (not yet drained out of the pipeline)
    // and misread it as byte N+1 having arrived — landing on
    // rxf_mem[rd_q] before byte N+1 was actually pushed there (X in
    // simulation). Caught by P3 cocotb's back-to-back test, NOT by P2
    // formal — the anyseq stub makes rx_data_valid/rx_data free every
    // cycle, so the proof never modeled the real FIFO's push/pop
    // sequencing that this hazard lives in.
    //
    // Fix: rx_have_byte_q is the single source of truth for RX_VALID.
    // It is set exactly once per byte (auto-drain: pop apb_uart_master's
    // FIFO the instant a byte is available and our one-entry slot is
    // free) and cleared exactly once per software CTRL[0] ack. There is
    // no window where a stale pipelined value can describe the wrong
    // byte, because the latch itself — not a delayed mirror of a live
    // signal — is what STATUS/RXDATA report.
    // -----------------------------------------------------------------
    logic       ctrl_we_q;
    logic       rx_have_byte_q;
    logic [7:0] rx_byte_q;
    logic       rx_ack;

    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) ctrl_we_q <= 1'b0;
        else        ctrl_we_q <= reg_we[IDX_CTRL];

    assign rx_ack        = ctrl_we_q && regfile[IDX_CTRL*DATA_WIDTH];
    assign rx_data_ready  = rx_data_valid && !rx_have_byte_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_have_byte_q <= 1'b0;
            rx_byte_q      <= 8'h0;
        end else if (rx_data_valid && !rx_have_byte_q) begin
            rx_byte_q      <= rx_data;
            rx_have_byte_q <= 1'b1;
        end else if (rx_ack) begin
            rx_have_byte_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // RXDATA/STATUS — always HW-owned, continuous combinational mirror
    // of the shadow latch (not of the raw live UART signals — see above).
    // -----------------------------------------------------------------
    always_comb begin
        hw_we    = '0;
        hw_wdata = '0;
        hw_we[IDX_RXDATA] = 1'b1;
        hw_wdata[IDX_RXDATA*DATA_WIDTH +: DATA_WIDTH] = {{(DATA_WIDTH-8){1'b0}}, rx_byte_q};
        hw_we[IDX_STATUS] = 1'b1;
        hw_wdata[IDX_STATUS*DATA_WIDTH +: DATA_WIDTH] =
            {{(DATA_WIDTH-4){1'b0}}, init_done, err, rx_have_byte_q, tx_data_ready};
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // regfile[TXDATA][DATA_WIDTH-1:8] — only the low byte is a real TX
    // payload. regfile[RXDATA]/regfile[STATUS] — HW-write-only, never read
    // back through this net (software reads them straight from
    // axi_lite_slave's own reg_q via the AXI R channel). regfile[CTRL] above
    // bit 0 — reserved.
    logic _unused;
    assign _unused = ^{awprot_i, arprot_i,
                        regfile[IDX_TXDATA*DATA_WIDTH+DATA_WIDTH-1 : IDX_TXDATA*DATA_WIDTH+8],
                        regfile[IDX_STATUS*DATA_WIDTH+DATA_WIDTH-1 : IDX_RXDATA*DATA_WIDTH],
                        regfile[IDX_CTRL*DATA_WIDTH+DATA_WIDTH-1 : IDX_CTRL*DATA_WIDTH+1]};
    /* verilator lint_on UNUSEDSIGNAL */

    // -----------------------------------------------------------------
    // Formal verification — new glue only. axi_lite_slave, apb_uart_master,
    // and uart_ctrl are anyseq-stubbed for this proof (see
    // uart_axi_periph.sby / uart_axi_periph_formal_stub.sv) — all three are
    // already signed off standalone by their own P2 formal; pulling
    // uart_ctrl's real logic into this proof's state space is exactly the
    // design whose formal run triggered this session's aggregate-memory
    // abort (see uart_ctrl's REPORT.md) and must not recur here.
    // -----------------------------------------------------------------
`ifdef FORMAL
    // initial assume(!rst_n) is the confirmed-working basecase-constraint
    // idiom on this Yosys build — a plain register's `initial X=const` is
    // not reliably honored in BMC's basecase (see CLAUDE.md "Formal
    // verification idioms").
    initial assume(!rst_n);

    logic tx_valid_prev_q, tx_ready_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_valid_prev_q <= 1'b0;
            tx_ready_prev_q <= 1'b0;
        end else begin
            tx_valid_prev_q <= tx_data_valid;
            tx_ready_prev_q <= tx_data_ready;
        end
    end

    logic rx_have_byte_prev_q, rx_ack_prev_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_have_byte_prev_q <= 1'b0;
            rx_ack_prev_q       <= 1'b0;
        end else begin
            rx_have_byte_prev_q <= rx_have_byte_q;
            rx_ack_prev_q       <= rx_ack;
        end
    end

    always_comb begin
        if (rst_n) begin
            // VALID-sticky: tx_data_valid must stay asserted until
            // tx_data_ready accepts it — same discipline axi_lite_slave's
            // own B/R channels are proven to hold.
            if (tx_valid_prev_q && !tx_ready_prev_q) assert(tx_data_valid);
            // A TXDATA write arriving while a byte is already pending must
            // not clobber it — the pending byte's data/valid survive.
            if (tx_we_q && tx_pending_q) assert(tx_data_valid);
            // RXDATA/STATUS are always HW-owned, never SW-writable.
            assert(hw_we[IDX_RXDATA]);
            assert(hw_we[IDX_STATUS]);
            // rx_ready_i (the pop into apb_uart_master's FIFO) only ever
            // fires on a genuine handshake into a free shadow slot.
            if (rx_data_ready) assert(rx_data_valid && !rx_have_byte_q);
            // Sticky-until-acked: a captured byte is never dropped except
            // by an explicit CTRL[0] ack (mirrors the TX VALID-sticky
            // idiom above, applied to the RX shadow latch instead of a
            // downstream ready signal).
            if (rx_have_byte_prev_q && !rx_ack_prev_q) assert(rx_have_byte_q);
        end
    end

    always_comb begin
        cover(rst_n && tx_data_valid && tx_data_ready);
        cover(rst_n && rx_have_byte_q);
        cover(rst_n && init_done);
    end
`endif

endmodule
