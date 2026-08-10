// fpu_axi_periph_formal_stub.sv — free (anyseq) stand-ins for axi_lite_slave
// and fpu_top, used ONLY by fpu_axi_periph's formal proof (see .sby).
//
// Both real IPs are already signed off standalone by their own P2 formal
// (register-file VALID-sticky invariants; FMA/CVT pipeline protocol).
// Pulling the real fpu_top (767 FFs) into this proof does not converge
// within any practical z3 budget — tried directly, timed out at depth 3
// BMC after 175s. A plain `blackbox` module is rejected by the SMT2
// backend ("is a blackbox/whitebox module" — write_smt2 needs real logic
// to reason about, not an opaque cell). `anyseq` is Yosys's actual
// supported mechanism for this: each output below is unconstrained and
// re-chosen freely every cycle, so the glue-FSM proof explores every
// possible submodule response without paying for their internal state.
//
// This file substitutes ONLY inside the formal target (see the .sby
// [script]/[files] sections) — it never touches rtl/, so P1/P3/P4/P6/P7/P8
// all build and verify against the real axi_lite_slave.sv / fpu_top.sv.

module axi_lite_slave #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int NUM_REGS   = 8
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

module fpu_top #(
    parameter int FLEN          = 32,
    parameter int XLEN          = 32,
    parameter bit FTZ           = 1'b0,
    parameter bit NAN_BOX_CHECK = 1'b1
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              valid_i,
    output logic              ready_o,
    input  logic [5:0]        op_i,
    input  logic [1:0]        fmt_i,
    input  logic [2:0]        rm_i,
    input  logic [FLEN-1:0]   src_a_i,
    input  logic [FLEN-1:0]   src_b_i,
    input  logic [FLEN-1:0]   src_c_i,
    input  logic [XLEN-1:0]   int_src_i,
    input  logic              ready_i,
    output logic [FLEN-1:0]   result_o,
    output logic [XLEN-1:0]   int_result_o,
    output logic              valid_o,
    output logic              busy_o,
    output logic [4:0]        fflags_o
);
    (* anyseq *) logic                f_ready, f_valid, f_busy;
    (* anyseq *) logic [FLEN-1:0]     f_result;
    (* anyseq *) logic [XLEN-1:0]     f_int_result;
    (* anyseq *) logic [4:0]         f_fflags;

    assign ready_o      = f_ready;
    assign result_o     = f_result;
    assign int_result_o = f_int_result;
    assign valid_o      = f_valid;
    assign busy_o       = f_busy;
    assign fflags_o     = f_fflags;
endmodule
