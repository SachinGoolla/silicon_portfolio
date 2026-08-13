// axi4stream_ctrl_formal_stub.sv -- free (anyseq) stand-ins for
// systolic_array_4x4 and axis_skid, used ONLY by axi4stream_ctrl's own
// formal proof (see .sby). Both real modules are already signed off
// standalone by their own P2 formal checkpoints (checkpoints 3 and 4).
// axi4stream_ctrl's own properties (accept-side mutual exclusion,
// weight-load-dropped-while-busy, busy-derived-from-occupancy,
// one-vector-at-a-time on the MMIO path) depend only on how this module
// drives/consumes these submodules' ports, not on their internal
// correctness -- matches fpu_axi_periph_formal_stub.sv's exact pattern
// and rationale.
//
// This file substitutes ONLY inside the formal target (see the .sby
// [script]/[files] sections) -- it never touches rtl/, so P1/P3/P4/P6/P7/P8
// all build and verify against the real systolic_array_4x4.sv / axis_skid.sv.

module systolic_array_4x4 #(
    parameter int K        = 4,
    parameter int N        = 4,
    parameter int LATENCY  = 1,
    parameter int ACT_W    = 8,
    parameter int PSUM_W   = 32,
    parameter bit USE_FP32 = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic pipeline_en_i,
    input  logic [K*ACT_W-1:0]    act_in_i,
    output logic [N*PSUM_W-1:0]   psum_out_o,
    input  logic [K*N*ACT_W-1:0]  weight_i,
    input  logic                  weight_we_i
);
    (* anyseq *) logic [N*PSUM_W-1:0] f_psum_out;
    assign psum_out_o = f_psum_out;
endmodule

module axis_skid #(
    parameter int WIDTH = 32
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic               s_valid_i,
    output logic               s_ready_o,
    input  logic [WIDTH-1:0]  s_data_i,
    output logic               m_valid_o,
    input  logic                m_ready_i,
    output logic [WIDTH-1:0]  m_data_o
);
    (* anyseq *) logic               f_s_ready, f_m_valid;
    (* anyseq *) logic [WIDTH-1:0]  f_m_data;
    assign s_ready_o = f_s_ready;
    assign m_valid_o = f_m_valid;
    assign m_data_o  = f_m_data;
endmodule
