// rv32i_regfile.sv — RV32I integer register file.
//
// 32 x 32-bit registers, x0 hardwired to 0. Two combinational read ports
// (rs1/rs2, for ID-stage operand fetch), one synchronous write port (rd,
// for WB-stage writeback).
//
// x1-x31 are NOT reset to a known value. This is spec-accurate, not a
// simplification: the RV32I ISA only fixes x0 = 0 architecturally; every
// other register's power-on value is undefined, and any correct program
// initializes a register before its first read. It also happens to be
// what made this module's formal proof tractable: an async-reset `for`
// loop over 31 registers pathologically hung z3 in the presat check
// (confirmed by a minimal repro — the identical model with the reset
// removed proves in under a second; adding it back reproduces the hang
// every time). Dropping the reset is the spec-correct design, not a
// workaround dressed up as one — verified by isolating the actual cause
// rather than assuming k-induction depth or property complexity was
// the problem.
//
// Write-first: a write and a read to the SAME address in the SAME cycle
// returns the NEW (being-written) value on the read port, not the old
// register contents. This is a deliberate design choice, not an
// afterthought — it eliminates the WB-to-ID same-cycle hazard class
// entirely at the regfile boundary, so rv32i_hazard_unit only has to
// reason about EX/MEM and MEM/WB forwarding into EX, not a third
// WB-into-ID forwarding path.
`timescale 1ns/1ps

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

    logic [31:0] regs_q [1:31];  // x0 is not stored — always reads 0

    // Write-first bypass, per address.
    wire rs1_bypass = rd_we_i && (rd_addr_i != 5'd0) && (rd_addr_i == rs1_addr_i);
    wire rs2_bypass = rd_we_i && (rd_addr_i != 5'd0) && (rd_addr_i == rs2_addr_i);

    assign rs1_data_o = (rs1_addr_i == 5'd0) ? 32'd0 :
                         rs1_bypass           ? rd_data_i :
                                                 regs_q[rs1_addr_i];
    assign rs2_data_o = (rs2_addr_i == 5'd0) ? 32'd0 :
                         rs2_bypass           ? rd_data_i :
                                                 regs_q[rs2_addr_i];

    always_ff @(posedge clk) begin
        if (rd_we_i && (rd_addr_i != 5'd0)) begin
            regs_q[rd_addr_i] <= rd_data_i;
        end
    end

    // -----------------------------------------------------------------
    // Formal verification. No `initial assume(!rst_n)` basecase idiom —
    // this module has no reset (see header comment), so there is no
    // basecase to constrain against.
    // -----------------------------------------------------------------
`ifdef FORMAL
    always_comb begin
        // x0 always reads 0, on both ports, regardless of any write.
        assert(rs1_addr_i != 5'd0 || rs1_data_o == 32'd0);
        assert(rs2_addr_i != 5'd0 || rs2_data_o == 32'd0);

        // Write-first: a same-cycle write to a nonzero register is
        // visible immediately on a same-address read.
        if (rd_we_i && rd_addr_i != 5'd0) begin
            if (rs1_addr_i == rd_addr_i) assert(rs1_data_o == rd_data_i);
            if (rs2_addr_i == rd_addr_i) assert(rs2_data_o == rd_data_i);
        end

        // A read to an address NOT being written this cycle is
        // unaffected by the write (i.e., the bypass mux picked the
        // stored-register path, not the write-first path). Structural
        // property on the mux select, not on regs_q's stored value
        // (which formal treats as free/uninterpreted array state).
        if (rs1_addr_i != 5'd0 && rs1_addr_i != rd_addr_i)
            assert(rs1_data_o == regs_q[rs1_addr_i]);
        if (rs2_addr_i != 5'd0 && rs2_addr_i != rd_addr_i)
            assert(rs2_data_o == regs_q[rs2_addr_i]);
    end

    always_comb begin
        cover(rd_we_i && rd_addr_i != 5'd0);
        cover(rs1_addr_i == rd_addr_i && rd_we_i);
    end
`endif

endmodule
