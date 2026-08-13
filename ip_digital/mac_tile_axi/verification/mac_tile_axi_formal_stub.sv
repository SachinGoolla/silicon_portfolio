// mac_tile_axi_formal_stub.sv -- free (anyseq) stand-ins for axi_lite_slave
// and axi4stream_ctrl, used ONLY by mac_tile_axi's own formal proof (see
// .sby). Both real modules are already signed off standalone by their own
// P2 formal checkpoints. mac_tile_axi's own properties (register-map
// decode correctness, STATUS/RESULT write sequencing) depend only on how
// this module drives/consumes these submodules' ports, matching
// fpu_axi_periph_formal_stub.sv's exact pattern and rationale.
//
// This file substitutes ONLY inside the formal target (see the .sby
// [script]/[files] sections) -- it never touches rtl/, so P1/P3/P4/P6/P7/P8
// all build and verify against the real axi_lite_slave.sv / axi4stream_ctrl.sv.

module axi_lite_slave #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int NUM_REGS   = 16
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

module axi4stream_ctrl #(
    parameter int K       = 4,
    parameter int N       = 4,
    parameter int LATENCY = 1,
    parameter int ACT_W   = 8,
    parameter int PSUM_W  = 32
) (
    input  logic clk,
    input  logic rst_n,
    input  logic                 s_axis_tvalid_i,
    output logic                 s_axis_tready_o,
    input  logic [K*ACT_W-1:0]   s_axis_tdata_i,
    input  logic                 s_axis_tlast_i,
    output logic                 m_axis_tvalid_o,
    input  logic                 m_axis_tready_i,
    output logic [N*PSUM_W-1:0]  m_axis_tdata_o,
    output logic                 m_axis_tlast_o,
    input  logic                 mmio_data_in_valid_i,
    output logic                 mmio_data_in_ready_o,
    input  logic [K*ACT_W-1:0]   mmio_data_in_i,
    input  logic                 mmio_tlast_next_i,
    input  logic                 mmio_result_ack_i,
    output logic                 mmio_result_valid_o,
    output logic [N*PSUM_W-1:0]  mmio_result_data_o,
    output logic                 mmio_result_last_o,
    input  logic                 input_src_mmio_i,
    input  logic [K*N*ACT_W-1:0] weight_i,
    input  logic                 weight_we_i,
    output logic                 weights_loaded_o,
    output logic                 busy_o
);
    (* anyseq *) logic                 f_s_ready, f_m_valid, f_m_tlast;
    (* anyseq *) logic [N*PSUM_W-1:0]  f_m_tdata;
    (* anyseq *) logic                 f_mmio_ready, f_mmio_valid, f_mmio_last;
    (* anyseq *) logic [N*PSUM_W-1:0]  f_mmio_data;
    (* anyseq *) logic                 f_weights_loaded, f_busy;

    assign s_axis_tready_o     = f_s_ready;
    assign m_axis_tvalid_o     = f_m_valid;
    assign m_axis_tdata_o      = f_m_tdata;
    assign m_axis_tlast_o      = f_m_tlast;
    assign mmio_data_in_ready_o = f_mmio_ready;
    assign mmio_result_valid_o  = f_mmio_valid;
    assign mmio_result_data_o   = f_mmio_data;
    assign mmio_result_last_o   = f_mmio_last;
    assign weights_loaded_o     = f_weights_loaded;
    assign busy_o                = f_busy;
endmodule
