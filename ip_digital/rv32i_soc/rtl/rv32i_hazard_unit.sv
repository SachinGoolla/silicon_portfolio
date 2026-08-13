// rv32i_hazard_unit.sv — forwarding select, load-use stall, control-hazard
// flush, and the global MEM-stage stall for rv32i_core's 5-stage pipeline.
// Pure combinational.
//
// stage_en_o is the SOLE enable for every pipeline register in the core
// (IF/ID, ID/EX, EX/MEM, MEM/WB alike) — asserted low only while mem_busy_i
// (an AXI4-Lite transaction outstanding in MEM). A stage that kept
// advancing during that stall would duplicate or drop an instruction;
// gating every register identically is what prevents it.
//
// Stall/flush interaction: flush_if_id_o/flush_id_ex_o are explicitly
// gated by stage_en_o INSIDE this module (not left as emergent behavior
// of how rv32i_core happens to wire the pipeline registers). A branch
// resolving in EX the same cycle MEM is stalled on AXI must not flush —
// the flush is held pending until the stall clears, and the flush signal
// simply never asserts while stage_en_o is low, so there is nothing
// downstream that needs to remember or re-apply it: once stage_en_o
// returns high, the branch's flush condition (derived combinationally
// from the still-unmoved EX-stage instruction) reasserts on its own.
`timescale 1ns/1ps

module rv32i_hazard_unit (
    // ID stage (IF/ID register) — for load-use detection
    input  logic [4:0] if_id_rs1_addr_i,
    input  logic [4:0] if_id_rs2_addr_i,

    // EX stage (ID/EX register) — for forwarding-select and load-use
    input  logic [4:0] id_ex_rs1_addr_i,
    input  logic [4:0] id_ex_rs2_addr_i,
    input  logic [4:0] id_ex_rd_addr_i,
    input  logic       id_ex_mem_read_i,

    // EX/MEM register — one instruction ahead, for forwarding into EX
    input  logic [4:0] ex_mem_rd_addr_i,
    input  logic       ex_mem_reg_write_i,

    // MEM/WB register — two instructions ahead, for forwarding into EX
    input  logic [4:0] mem_wb_rd_addr_i,
    input  logic       mem_wb_reg_write_i,

    // Control hazard: branch/jump resolved in EX this cycle
    input  logic       ex_branch_taken_i,
    input  logic       ex_jump_i,

    // MEM-stage AXI transaction outstanding
    input  logic       mem_busy_i,

    // EX-stage ALU operand forwarding select: 00=regfile 01=EX/MEM 10=MEM/WB
    output logic [1:0] forward_a_sel_o,
    output logic [1:0] forward_b_sel_o,

    // Load-use hazard: freeze PC + IF/ID, bubble into ID/EX for one cycle
    output logic       stall_pc_o,
    output logic       stall_if_id_o,
    output logic       bubble_id_ex_o,

    // Control-hazard flush (gated by stage_en_o — see header)
    output logic       flush_if_id_o,
    output logic       flush_id_ex_o,

    // Global pipeline-register enable
    output logic       stage_en_o
);

    localparam logic [1:0] FWD_NONE  = 2'b00;
    localparam logic [1:0] FWD_EXMEM = 2'b01;
    localparam logic [1:0] FWD_MEMWB = 2'b10;

    // -----------------------------------------------------------------
    // Forwarding — EX/MEM takes priority over MEM/WB (more recent value)
    // when both target the same nonzero register. Never forwards from a
    // bubble (reg_write=0) or to x0.
    // -----------------------------------------------------------------
    always_comb begin
        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs1_addr_i)
            forward_a_sel_o = FWD_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_ex_rs1_addr_i)
            forward_a_sel_o = FWD_MEMWB;
        else
            forward_a_sel_o = FWD_NONE;

        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs2_addr_i)
            forward_b_sel_o = FWD_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_ex_rs2_addr_i)
            forward_b_sel_o = FWD_MEMWB;
        else
            forward_b_sel_o = FWD_NONE;
    end

    // -----------------------------------------------------------------
    // Load-use hazard — the EX-stage instruction is a load whose result
    // isn't ready until MEM completes; if the ID-stage instruction needs
    // that same register, stall one cycle (bubble into ID/EX).
    // -----------------------------------------------------------------
    wire load_use_hazard =
        id_ex_mem_read_i && id_ex_rd_addr_i != 5'd0 &&
        ((id_ex_rd_addr_i == if_id_rs1_addr_i) || (id_ex_rd_addr_i == if_id_rs2_addr_i));

    assign stall_pc_o    = load_use_hazard;
    assign stall_if_id_o = load_use_hazard;
    assign bubble_id_ex_o = load_use_hazard;

    // -----------------------------------------------------------------
    // Global stall (MEM-stage AXI transaction) and gated flush.
    // -----------------------------------------------------------------
    assign stage_en_o = !mem_busy_i;

    wire raw_flush = ex_branch_taken_i || ex_jump_i;
    assign flush_if_id_o = raw_flush && stage_en_o;
    assign flush_id_ex_o = raw_flush && stage_en_o;

    // -----------------------------------------------------------------
    // Formal verification
    // -----------------------------------------------------------------
`ifdef FORMAL
    always_comb begin
        // Forwarding priority: EX/MEM wins over MEM/WB when both match.
        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs1_addr_i)
            assert(forward_a_sel_o == FWD_EXMEM);
        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs2_addr_i)
            assert(forward_b_sel_o == FWD_EXMEM);

        // Never forward to/from x0, never forward from a non-writing stage.
        assert(!(forward_a_sel_o == FWD_EXMEM && (!ex_mem_reg_write_i || ex_mem_rd_addr_i == 5'd0)));
        assert(!(forward_a_sel_o == FWD_MEMWB && (!mem_wb_reg_write_i || mem_wb_rd_addr_i == 5'd0)));
        assert(!(forward_b_sel_o == FWD_EXMEM && (!ex_mem_reg_write_i || ex_mem_rd_addr_i == 5'd0)));
        assert(!(forward_b_sel_o == FWD_MEMWB && (!mem_wb_reg_write_i || mem_wb_rd_addr_i == 5'd0)));

        // Stall wins over flush: a flush is never asserted on a cycle
        // stage_en_o is low. This is the exact property advisor asked to
        // see proven here, not left as emergent top-level wiring — and
        // it holds by construction (flush_*_o's own assign statements
        // above AND stage_en_o), so this assertion is a check that the
        // gating wasn't accidentally dropped in a future edit, not a
        // speculative property.
        assert(!(flush_if_id_o && !stage_en_o));
        assert(!(flush_id_ex_o && !stage_en_o));

        // Load-use stall only fires when the EX-stage instruction is
        // genuinely a load targeting a register the ID-stage instruction
        // needs.
        if (stall_pc_o) begin
            assert(id_ex_mem_read_i);
            assert(id_ex_rd_addr_i != 5'd0);
            assert((id_ex_rd_addr_i == if_id_rs1_addr_i) || (id_ex_rd_addr_i == if_id_rs2_addr_i));
        end
    end

    always_comb begin
        cover(forward_a_sel_o == FWD_EXMEM);
        cover(forward_a_sel_o == FWD_MEMWB);
        cover(stall_pc_o);
        cover(raw_flush && !stage_en_o);  // the exact interaction case
        cover(flush_if_id_o);
    end
`endif

endmodule
