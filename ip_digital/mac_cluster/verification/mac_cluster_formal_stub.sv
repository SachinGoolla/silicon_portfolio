// mac_cluster_formal_stub.sv -- free (anyseq) stand-ins for axi_lite_slave,
// mac_tile_axi, tile_ni, and mesh_2x2, used ONLY by mac_cluster's own
// formal proof (see .sby). All four real modules are already signed off
// standalone by their own P2 formal checkpoints (mac_tile_axi transitively
// via its own composed proof). mac_cluster's own properties (5-way
// sub-decode correctness, CSR bit-mapping) depend only on how THIS module
// drives/consumes these submodules' ports, matching
// fpu_axi_periph_formal_stub.sv's exact pattern and rationale (also used
// by mac_tile_axi_formal_stub.sv and axi4stream_ctrl_formal_stub.sv
// earlier in this same phase).
//
// This file substitutes ONLY inside the formal target (see the .sby
// [script]/[files] sections) -- it never touches rtl/, so P1/P3/P4/P6/P7/P8
// all build and verify against the real submodules.
`timescale 1ns/1ps

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
    (* anyseq *) logic f_awready, f_wready, f_bvalid, f_arready, f_rvalid;
    (* anyseq *) logic [1:0] f_bresp, f_rresp;
    (* anyseq *) logic [DATA_WIDTH-1:0] f_rdata;
    (* anyseq *) logic [NUM_REGS*DATA_WIDTH-1:0] f_regfile;
    (* anyseq *) logic [NUM_REGS-1:0] f_reg_we;

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

module mac_tile_axi #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int K          = 4,
    parameter int N          = 4,
    parameter int LATENCY    = 1,
    parameter int ACT_W      = 8,
    parameter int PSUM_W     = 32
) (
    input  logic clk, rst_n,
    input  logic                      awvalid_i,
    output logic                      awready_o,
    input  logic [ADDR_WIDTH-1:0]     awaddr_i,
    input  logic [2:0]                awprot_i,
    input  logic                      wvalid_i,
    output logic                      wready_o,
    input  logic [DATA_WIDTH-1:0]     wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] wstrb_i,
    output logic                      bvalid_o,
    input  logic                      bready_i,
    output logic [1:0]                bresp_o,
    input  logic                      arvalid_i,
    output logic                      arready_o,
    input  logic [ADDR_WIDTH-1:0]     araddr_i,
    input  logic [2:0]                arprot_i,
    output logic                      rvalid_o,
    input  logic                      rready_i,
    output logic [DATA_WIDTH-1:0]     rdata_o,
    output logic [1:0]                rresp_o,
    input  logic                 s_axis_tvalid_i,
    output logic                 s_axis_tready_o,
    input  logic [K*ACT_W-1:0]   s_axis_tdata_i,
    input  logic                 s_axis_tlast_i,
    output logic                 m_axis_tvalid_o,
    input  logic                 m_axis_tready_i,
    output logic [N*PSUM_W-1:0]  m_axis_tdata_o,
    output logic                 m_axis_tlast_o
);
    (* anyseq *) logic f_awready, f_wready, f_bvalid, f_arready, f_rvalid;
    (* anyseq *) logic [1:0] f_bresp, f_rresp;
    (* anyseq *) logic [DATA_WIDTH-1:0] f_rdata;
    (* anyseq *) logic f_sready, f_mvalid, f_mlast;
    (* anyseq *) logic [N*PSUM_W-1:0] f_mdata;

    assign awready_o = f_awready;
    assign wready_o  = f_wready;
    assign bvalid_o  = f_bvalid;
    assign bresp_o   = f_bresp;
    assign arready_o = f_arready;
    assign rvalid_o  = f_rvalid;
    assign rdata_o   = f_rdata;
    assign rresp_o   = f_rresp;
    assign s_axis_tready_o = f_sready;
    assign m_axis_tvalid_o = f_mvalid;
    assign m_axis_tdata_o  = f_mdata;
    assign m_axis_tlast_o  = f_mlast;
endmodule

module tile_ni #(
    parameter int MESH_DIM      = 2,
    parameter int PAYLOAD_W     = 128,
    parameter int CW            = 1,
    parameter int FLIT_W        = 134,
    parameter int K             = 4,
    parameter int N             = 4,
    parameter int ACT_W         = 8,
    parameter int PSUM_W        = 32,
    parameter int REQUANT_SHIFT = 4,
    parameter int MY_X          = 0,
    parameter int MY_Y          = 0
) (
    input  logic clk, rst_n,
    input  logic [FLIT_W-1:0] mesh_in_flit_i,
    input  logic               mesh_in_valid_i,
    output logic                mesh_in_ready_o,
    output logic [FLIT_W-1:0] mesh_out_flit_o,
    output logic               mesh_out_valid_o,
    input  logic                mesh_out_ready_i,
    output logic                 tile_s_axis_tvalid_o,
    input  logic                 tile_s_axis_tready_i,
    output logic [K*ACT_W-1:0]   tile_s_axis_tdata_o,
    output logic                 tile_s_axis_tlast_o,
    input  logic                 tile_m_axis_tvalid_i,
    output logic                 tile_m_axis_tready_o,
    input  logic [N*PSUM_W-1:0]  tile_m_axis_tdata_i,
    input  logic                 tile_m_axis_tlast_i,
    input  logic                 entry_push_i,
    input  logic                 tlast_next_i,
    input  logic [K*ACT_W-1:0]   entry_data_i,
    input  logic                 mesh_egress_en_i,
    input  logic [CW-1:0]        dest_x_i,
    input  logic [CW-1:0]        dest_y_i,
    input  logic                 exit_ack_i,
    output logic                 entry_busy_o,
    output logic                 exit_valid_o,
    output logic                 exit_last_o,
    output logic [N*PSUM_W-1:0]  exit_result_o,
    output logic                 exit_seq_o
);
    (* anyseq *) logic f_mready, f_svalid, f_slast, f_mtready, f_ebusy, f_evalid, f_elast, f_eseq;
    (* anyseq *) logic [K*ACT_W-1:0] f_sdata;
    (* anyseq *) logic [N*PSUM_W-1:0] f_eresult;

    assign mesh_in_ready_o      = f_mready;
    assign tile_s_axis_tvalid_o = f_svalid;
    assign tile_s_axis_tdata_o  = f_sdata;
    assign tile_s_axis_tlast_o  = f_slast;
    assign tile_m_axis_tready_o = f_mtready;
    assign mesh_out_flit_o      = '0;
    assign mesh_out_valid_o     = 1'b0;
    assign entry_busy_o  = f_ebusy;
    assign exit_valid_o  = f_evalid;
    assign exit_last_o   = f_elast;
    assign exit_result_o = f_eresult;
    assign exit_seq_o    = f_eseq;
endmodule

module mesh_2x2 #(
    parameter int MESH_DIM  = 2,
    parameter int PAYLOAD_W = 128,
    parameter int CW        = 1,
    parameter int FLIT_W    = 134
) (
    input  logic clk, rst_n,
    input  logic [4*FLIT_W-1:0] local_in_flit_i,
    input  logic [3:0]          local_in_valid_i,
    output logic [3:0]          local_in_ready_o,
    output logic [4*FLIT_W-1:0] local_out_flit_o,
    output logic [3:0]          local_out_valid_o,
    input  logic [3:0]          local_out_ready_i
);
    (* anyseq *) logic [3:0] f_iready;
    assign local_in_ready_o  = f_iready;
    assign local_out_flit_o  = '0;
    assign local_out_valid_o = 4'b0;
endmodule
