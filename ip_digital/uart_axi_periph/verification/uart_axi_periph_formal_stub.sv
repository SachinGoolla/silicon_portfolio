// uart_axi_periph_formal_stub.sv — free (anyseq) stand-ins for
// axi_lite_slave, apb_uart_master, and uart_ctrl, used ONLY by
// uart_axi_periph's formal proof (see .sby).
//
// All three real IPs are already signed off standalone by their own P2
// formal (register-file VALID-sticky invariants; APB3 sequencer safety;
// TX/RX FSM legality). Pulling uart_ctrl's real logic (326 cells, 5 RTL
// files) into this proof's state space is exactly the design whose formal
// run triggered this session's aggregate multi-process memory abort (see
// uart_ctrl's REPORT.md) — must not recur here. A plain `blackbox` module
// is rejected by the SMT2 backend ("is a blackbox/whitebox module" —
// write_smt2 needs real logic to reason about, not an opaque cell).
// `anyseq` is Yosys's actual supported mechanism (confirmed working on
// fpu_axi_periph_formal_stub.sv): each output below is unconstrained and
// re-chosen freely every cycle, so the glue proof explores every possible
// submodule response without paying for their internal state.
//
// This file substitutes ONLY inside the formal target (see the .sby
// [script]/[files] sections) — it never touches rtl/, so P1/P3/P4/P6/P7/P8
// all build and verify against the real axi_lite_slave.sv / apb_uart_master.sv
// / uart_ctrl.sv.

module axi_lite_slave #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int NUM_REGS   = 4
) (
    input  logic                            clk,
    input  logic                            rst_n,
    input  logic                            awvalid_i,
    output logic                            awready_o,
    input  logic [ADDR_WIDTH-1:0]           awaddr_i,
    input  logic [2:0]                      awprot_i,
    input  logic                            wvalid_i,
    output logic                            wready_o,
    input  logic [DATA_WIDTH-1:0]           wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0]       wstrb_i,
    output logic                            bvalid_o,
    input  logic                            bready_i,
    output logic [1:0]                      bresp_o,
    input  logic                            arvalid_i,
    output logic                            arready_o,
    input  logic [ADDR_WIDTH-1:0]           araddr_i,
    input  logic [2:0]                      arprot_i,
    output logic                            rvalid_o,
    input  logic                            rready_i,
    output logic [DATA_WIDTH-1:0]           rdata_o,
    output logic [1:0]                      rresp_o,
    output logic [NUM_REGS*DATA_WIDTH-1:0]  regfile_o,
    output logic [NUM_REGS-1:0]             reg_we_o,
    input  logic [NUM_REGS*DATA_WIDTH-1:0]  hw_wdata_i,
    input  logic [NUM_REGS-1:0]             hw_we_i
);
    (* anyseq *) logic                            f_awready, f_wready, f_bvalid, f_arready, f_rvalid;
    (* anyseq *) logic [1:0]                       f_bresp, f_rresp;
    (* anyseq *) logic [DATA_WIDTH-1:0]            f_rdata;
    (* anyseq *) logic [NUM_REGS*DATA_WIDTH-1:0]   f_regfile;
    (* anyseq *) logic [NUM_REGS-1:0]              f_reg_we;

    assign awready_o = f_awready;
    assign wready_o  = f_wready;
    assign bvalid_o  = f_bvalid;
    assign bresp_o   = f_bresp;
    assign arready_o = f_arready;
    assign rvalid_o  = f_rvalid;
    assign rdata_o   = f_rdata;
    assign rresp_o   = f_rresp;
    assign regfile_o = f_regfile;
    assign reg_we_o  = f_reg_we;
endmodule

module apb_uart_master #(
    parameter int          CLK_FREQ  = 50_000_000,
    parameter int          BAUD_RATE = 115_200,
    parameter int          TX_DEPTH  = 8,
    parameter int          RX_DEPTH  = 8,
    parameter logic [31:0] CTRL_WORD = 32'h07
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [7:0]  tx_data_i,
    input  logic        tx_valid_i,
    output logic        tx_ready_o,
    output logic [7:0]  rx_data_o,
    output logic        rx_valid_o,
    input  logic        rx_ready_i,
    output logic        PSEL,
    output logic        PENABLE,
    output logic        PWRITE,
    output logic [4:0]  PADDR,
    output logic [31:0] PWDATA,
    input  logic [31:0] PRDATA,
    input  logic        PREADY,
    input  logic        PSLVERR,
    input  logic        irq_i,
    output logic        init_done_o,
    output logic        err_o
);
    (* anyseq *) logic        f_tx_ready, f_rx_valid;
    (* anyseq *) logic [7:0]  f_rx_data;
    (* anyseq *) logic        f_psel, f_penable, f_pwrite;
    (* anyseq *) logic [4:0]  f_paddr;
    (* anyseq *) logic [31:0] f_pwdata;
    (* anyseq *) logic        f_init_done, f_err;

    assign tx_ready_o  = f_tx_ready;
    assign rx_data_o   = f_rx_data;
    assign rx_valid_o  = f_rx_valid;
    assign PSEL        = f_psel;
    assign PENABLE     = f_penable;
    assign PWRITE      = f_pwrite;
    assign PADDR       = f_paddr;
    assign PWDATA       = f_pwdata;
    assign init_done_o = f_init_done;
    assign err_o       = f_err;
endmodule

module uart_ctrl #(
    parameter int CLK_FREQ   = 50_000_000,
    parameter int BAUD_RATE  = 115_200,
    parameter int FIFO_DEPTH = 16,
    parameter bit PARITY_EN  = 1'b0
) (
    input  logic        PCLK,
    input  logic        PRESETn,
    input  logic        PSEL,
    input  logic        PENABLE,
    input  logic        PWRITE,
    input  logic [4:0]  PADDR,
    input  logic [31:0] PWDATA,
    output logic [31:0] PRDATA,
    output logic        PREADY,
    output logic        PSLVERR,
    output logic        uart_tx,
    input  logic        uart_rx,
    output logic        irq_o
);
    (* anyseq *) logic [31:0] f_prdata;
    (* anyseq *) logic        f_pready, f_pslverr, f_uart_tx, f_irq;

    assign PRDATA  = f_prdata;
    assign PREADY  = f_pready;
    assign PSLVERR = f_pslverr;
    assign uart_tx = f_uart_tx;
    assign irq_o   = f_irq;
endmodule
