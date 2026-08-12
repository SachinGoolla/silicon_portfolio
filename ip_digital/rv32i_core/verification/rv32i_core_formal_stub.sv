// rv32i_core_formal_stub.sv — free (anyseq) stand-ins for rv32i_regfile,
// rv32i_alu, rv32i_hazard_unit, rv32i_lsu, used ONLY by rv32i_core's own
// top-level formal proof (rv32i_core.sby). All four already have their
// own standalone proofs; this proof checks only NEW composition risk
// (does rv32i_core.sv wire stage_en/flush/stall correctly).
//
// rv32i_decoder (and its real children rv32i_imm_gen/rv32i_ctrl_decode)
// is deliberately NOT stubbed here, unlike the other four: this proof's
// PC-alignment property depends on B-type/J-type immediates genuinely
// having bit 0 clear, a guarantee rv32i_imm_gen.sv's own proof provides
// and an anyseq-free imm_o would silently discard (a free 32-bit value
// has no reason to be word-aligned). Keep the decoder's real cone in the
// proof; stub only the modules the alignment property doesn't transit.

module rv32i_regfile (
    input  logic        clk,
    input  logic [4:0]  rs1_addr_i,
    output logic [31:0] rs1_data_o,
    input  logic [4:0]  rs2_addr_i,
    output logic [31:0] rs2_data_o,
    input  logic [4:0]  rd_addr_i,
    input  logic [31:0] rd_data_i,
    input  logic        rd_we_i
);
    (* anyseq *) logic [31:0] f_rs1, f_rs2;
    assign rs1_data_o = f_rs1;
    assign rs2_data_o = f_rs2;
endmodule

module rv32i_alu (
    input  logic [31:0] a_i,
    input  logic [31:0] b_i,
    input  logic [3:0]  alu_op_i,
    output logic [31:0] result_o,
    output logic        zero_o
);
    (* anyseq *) logic [31:0] f_result;
    (* anyseq *) logic        f_zero;
    assign result_o = f_result;
    assign zero_o   = f_zero;
endmodule

module rv32i_hazard_unit (
    input  logic [4:0] if_id_rs1_addr_i,
    input  logic [4:0] if_id_rs2_addr_i,
    input  logic [4:0] id_ex_rs1_addr_i,
    input  logic [4:0] id_ex_rs2_addr_i,
    input  logic [4:0] id_ex_rd_addr_i,
    input  logic       id_ex_mem_read_i,
    input  logic [4:0] ex_mem_rd_addr_i,
    input  logic       ex_mem_reg_write_i,
    input  logic [4:0] mem_wb_rd_addr_i,
    input  logic       mem_wb_reg_write_i,
    input  logic       ex_branch_taken_i,
    input  logic       ex_jump_i,
    input  logic       mem_busy_i,
    output logic [1:0] forward_a_sel_o,
    output logic [1:0] forward_b_sel_o,
    output logic       stall_pc_o,
    output logic       stall_if_id_o,
    output logic       bubble_id_ex_o,
    output logic       flush_if_id_o,
    output logic       flush_id_ex_o,
    output logic       stage_en_o
);
    (* anyseq *) logic [1:0] f_fwd_a, f_fwd_b;
    (* anyseq *) logic f_stall_pc, f_stall_if_id, f_bubble_id_ex;
    (* anyseq *) logic f_flush_if_id, f_flush_id_ex, f_stage_en;

    assign forward_a_sel_o = f_fwd_a;
    assign forward_b_sel_o = f_fwd_b;
    assign stall_pc_o      = f_stall_pc;
    assign stall_if_id_o   = f_stall_if_id;
    assign bubble_id_ex_o  = f_bubble_id_ex;
    assign flush_if_id_o   = f_flush_if_id;
    assign flush_id_ex_o   = f_flush_id_ex;
    assign stage_en_o      = f_stage_en;
endmodule

module rv32i_lsu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic         mem_read_i,
    input  logic         mem_write_i,
    input  logic [31:0]  addr_i,
    input  logic [31:0]  wdata_i,
    input  logic [1:0]   width_i,
    input  logic         unsigned_i,
    output logic [31:0]  rdata_o,
    output logic         busy_o,
    output logic         done_o,
    output logic         awvalid_o,
    input  logic         awready_i,
    output logic [31:0]  awaddr_o,
    output logic [2:0]   awprot_o,
    output logic         wvalid_o,
    input  logic         wready_i,
    output logic [31:0]  wdata_o,
    output logic [3:0]   wstrb_o,
    input  logic         bvalid_i,
    output logic         bready_o,
    input  logic [1:0]   bresp_i,
    output logic         arvalid_o,
    input  logic         arready_i,
    output logic [31:0]  araddr_o,
    output logic [2:0]   arprot_o,
    input  logic         rvalid_i,
    output logic         rready_o,
    input  logic [31:0]  rdata_i,
    input  logic [1:0]   rresp_i
);
    (* anyseq *) logic [31:0] f_rdata;
    (* anyseq *) logic f_busy, f_done;
    (* anyseq *) logic f_awvalid, f_wvalid, f_bready, f_arvalid, f_rready;
    (* anyseq *) logic [31:0] f_awaddr, f_wdata, f_araddr;
    (* anyseq *) logic [3:0]  f_wstrb;
    (* anyseq *) logic [2:0]  f_awprot, f_arprot;

    assign rdata_o   = f_rdata;
    assign busy_o    = f_busy;
    assign done_o    = f_done;
    assign awvalid_o = f_awvalid;
    assign awaddr_o  = f_awaddr;
    assign awprot_o  = f_awprot;
    assign wvalid_o  = f_wvalid;
    assign wdata_o   = f_wdata;
    assign wstrb_o   = f_wstrb;
    assign bready_o  = f_bready;
    assign arvalid_o = f_arvalid;
    assign araddr_o  = f_araddr;
    assign arprot_o  = f_arprot;
    assign rready_o  = f_rready;
endmodule
