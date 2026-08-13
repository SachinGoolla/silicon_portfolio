// rv32i_lsu.sv — MEM-stage AXI4-Lite master for data memory + MMIO.
//
// Single-outstanding-transaction master (the pipeline only issues one
// memory op at a time, stalling on it — see rv32i_hazard_unit.sv's
// mem_busy_i/stage_en_o). Handles byte/halfword/word loads and stores,
// including WSTRB/byte-lane positioning for stores and sign/zero
// extension for loads.
//
// Formal scope: AXI4-Lite MASTER protocol compliance only (VALID-sticky,
// stable address/data while VALID is asserted and READY is low) — the
// mirror-image property of axi_lite_slave.sv's own formal proof, which
// assumes exactly this discipline from whatever master it's attached to.
// Byte/half/word data-path correctness (WSTRB positioning, sign/zero
// extension) is a functional-test concern, not formalized here — same
// "formal proves protocol, tests prove data-path arithmetic" boundary
// already established for the ALU/decoder in this core.
`timescale 1ns/1ps

module rv32i_lsu (
    input  logic        clk,
    input  logic        rst_n,

    // MEM-stage request
    input  logic         mem_read_i,
    input  logic         mem_write_i,
    input  logic [31:0]  addr_i,
    input  logic [31:0]  wdata_i,
    input  logic [1:0]   width_i,       // 00=byte 01=half 10=word
    input  logic         unsigned_i,
    output logic [31:0]  rdata_o,
    output logic         busy_o,
    output logic         done_o,

    // AXI4-Lite master port
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

    typedef enum logic [2:0] {
        S_IDLE, S_WRITE, S_WRESP, S_READ_ADDR, S_READ_DATA
    } state_e;
    state_e state_q, state_d;

    logic [31:0] addr_q, store_data_q;
    logic [3:0]  wstrb_q;
    logic [1:0]  width_q;
    logic        unsigned_q;
    logic [1:0]  byte_off_q;

    logic aw_done_q, w_done_q;

    // -----------------------------------------------------------------
    // Store data positioning — replicate across lanes, let WSTRB mask
    // (a common, spec-compliant simplification for narrow AXI writes).
    // -----------------------------------------------------------------
    logic [31:0] store_data;
    logic [3:0]  store_strb;
    // Icarus rejects a part-select used directly as a case expression
    // ("constant selects in always_* processes are not currently
    // supported (all bits will be included)") -- an explicit
    // intermediate signal avoids it (same fix as rv32i_ctrl_decode.sv's
    // branch_cmp_grp).
    wire [1:0] addr_byte_sel = addr_i[1:0];
    always_comb begin
        unique case (width_i)
            2'b00: begin  // byte
                store_data = {4{wdata_i[7:0]}};
                unique case (addr_byte_sel)
                    2'b00:   store_strb = 4'b0001;
                    2'b01:   store_strb = 4'b0010;
                    2'b10:   store_strb = 4'b0100;
                    2'b11:   store_strb = 4'b1000;
                    default: store_strb = 4'b0000;
                endcase
            end
            2'b01: begin  // half
                store_data = {2{wdata_i[15:0]}};
                store_strb = addr_i[1] ? 4'b1100 : 4'b0011;
            end
            default: begin  // word
                store_data = wdata_i;
                store_strb = 4'b1111;
            end
        endcase
    end

    // -----------------------------------------------------------------
    // FSM
    // -----------------------------------------------------------------
    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE: begin
                if (mem_write_i)      state_d = S_WRITE;
                else if (mem_read_i)  state_d = S_READ_ADDR;
            end
            S_WRITE:     if ((aw_done_q || awready_i) && (w_done_q || wready_i)) state_d = S_WRESP;
            S_WRESP:     if (bvalid_i)   state_d = S_IDLE;
            S_READ_ADDR: if (arready_i)  state_d = S_READ_DATA;
            S_READ_DATA: if (rvalid_i)   state_d = S_IDLE;
            default:     state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q       <= S_IDLE;
            addr_q        <= 32'd0;
            store_data_q  <= 32'd0;
            wstrb_q       <= 4'd0;
            width_q       <= 2'd0;
            unsigned_q    <= 1'b0;
            byte_off_q    <= 2'd0;
            aw_done_q     <= 1'b0;
            w_done_q      <= 1'b0;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE && (mem_read_i || mem_write_i)) begin
                addr_q       <= addr_i;
                store_data_q <= store_data;
                wstrb_q      <= store_strb;
                width_q      <= width_i;
                unsigned_q   <= unsigned_i;
                byte_off_q   <= addr_i[1:0];
            end
            if (state_q == S_WRITE) begin
                if (awready_i) aw_done_q <= 1'b1;
                if (wready_i)  w_done_q  <= 1'b1;
            end
            if (state_d == S_IDLE) begin
                aw_done_q <= 1'b0;
                w_done_q  <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------
    // AXI4-Lite master port — VALID held until its own READY (independent
    // AW/W tracking so a slave that accepts them on different cycles is
    // handled correctly, matching axi_lite_slave's own independent-skid-
    // buffer discipline on the other side of this exact protocol).
    // -----------------------------------------------------------------
    assign awvalid_o = (state_q == S_WRITE) && !aw_done_q;
    assign awaddr_o   = addr_q;
    assign awprot_o   = 3'b000;

    assign wvalid_o = (state_q == S_WRITE) && !w_done_q;
    assign wdata_o   = store_data_q;
    assign wstrb_o   = wstrb_q;

    assign bready_o = (state_q == S_WRESP);

    assign arvalid_o = (state_q == S_READ_ADDR);
    assign araddr_o   = addr_q;
    assign arprot_o   = 3'b000;

    assign rready_o = (state_q == S_READ_DATA);

    // -----------------------------------------------------------------
    // Load data extraction — byte/half select by address, then sign or
    // zero extend.
    // -----------------------------------------------------------------
    logic [7:0]  load_byte;
    logic [15:0] load_half;
    always_comb begin
        unique case (byte_off_q)
            2'b00:   load_byte = rdata_i[7:0];
            2'b01:   load_byte = rdata_i[15:8];
            2'b10:   load_byte = rdata_i[23:16];
            2'b11:   load_byte = rdata_i[31:24];
            default: load_byte = 8'd0;
        endcase
        load_half = byte_off_q[1] ? rdata_i[31:16] : rdata_i[15:0];
    end

    always_comb begin
        unique case (width_q)
            2'b00:   rdata_o = unsigned_q ? {24'd0, load_byte} : {{24{load_byte[7]}}, load_byte};
            2'b01:   rdata_o = unsigned_q ? {16'd0, load_half} : {{16{load_half[15]}}, load_half};
            default: rdata_o = rdata_i;
        endcase
    end

    assign done_o = (state_q == S_WRESP && bvalid_i) || (state_q == S_READ_DATA && rvalid_i);

    // busy_o must assert COMBINATIONALLY the same cycle a transaction
    // starts (state_q still S_IDLE, mem_read_i/mem_write_i just asserted),
    // not one cycle later once state_q has registered away from S_IDLE.
    // rv32i_core's hazard unit derives its whole-pipeline stall directly
    // from this signal (stage_en_o = !mem_busy_i) -- a registered-only
    // busy_o would let EX/MEM (and everything upstream of it) advance one
    // extra cycle on transaction entry, overwriting the very instruction
    // whose store_data/addr this module is about to latch below, and
    // losing the in-flight instruction's rd_addr/reg_write/result_src
    // needed for its eventual writeback. mem_op_starting closes that race.
    wire mem_op_starting = (state_q == S_IDLE) && (mem_read_i || mem_write_i);
    assign busy_o = (mem_op_starting || (state_q != S_IDLE)) && !done_o;

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = ^{bresp_i, rresp_i};
    /* verilator lint_on UNUSEDSIGNAL */

    // -----------------------------------------------------------------
    // Formal verification — AXI4-Lite master protocol compliance, the
    // mirror-image property of axi_lite_slave.sv's own proof.
    // -----------------------------------------------------------------
`ifdef FORMAL
    initial assume(!rst_n);

    logic awvalid_prev_q, awready_prev_q;
    logic wvalid_prev_q, wready_prev_q;
    logic arvalid_prev_q, arready_prev_q;
    logic [31:0] awaddr_prev_q, araddr_prev_q, wdata_prev_q;
    logic [3:0]  wstrb_prev_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awvalid_prev_q <= 1'b0; awready_prev_q <= 1'b0; awaddr_prev_q <= 32'd0;
            wvalid_prev_q  <= 1'b0; wready_prev_q  <= 1'b0; wdata_prev_q  <= 32'd0; wstrb_prev_q <= 4'd0;
            arvalid_prev_q <= 1'b0; arready_prev_q <= 1'b0; araddr_prev_q <= 32'd0;
        end else begin
            awvalid_prev_q <= awvalid_o; awready_prev_q <= awready_i; awaddr_prev_q <= awaddr_o;
            wvalid_prev_q  <= wvalid_o;  wready_prev_q  <= wready_i;  wdata_prev_q  <= wdata_o; wstrb_prev_q <= wstrb_o;
            arvalid_prev_q <= arvalid_o; arready_prev_q <= arready_i; araddr_prev_q <= araddr_o;
        end
    end

    // Reused from rv32i_imm_gen.sv. Kept even after this checkpoint's
    // real fix (below): equivalent form, no downside.
    `define WEQ(a, b) ((|((a) ^ (b))) == 1'b0)

    always_comb begin
        if (rst_n) begin
            // VALID-sticky: once asserted, stays asserted until READY.
            if (awvalid_prev_q && !awready_prev_q) assert(awvalid_o);
            if (wvalid_prev_q  && !wready_prev_q)  assert(wvalid_o);
            if (arvalid_prev_q && !arready_prev_q) assert(arvalid_o);

            // Payload stability while VALID is asserted and not yet
            // accepted (compared against last cycle's value, since this
            // checks continuity across a cycle boundary).
            if (awvalid_prev_q && !awready_prev_q) assert(`WEQ(awaddr_o, awaddr_prev_q));
            if (wvalid_prev_q  && !wready_prev_q) begin
                assert(`WEQ(wdata_o, wdata_prev_q));
                assert(`WEQ(wstrb_o, wstrb_prev_q));
            end
            if (arvalid_prev_q && !arready_prev_q) assert(`WEQ(araddr_o, araddr_prev_q));

            // busy_o/done_o never both meaningfully wrong: done only in
            // the two terminal-handshake conditions, busy exactly when
            // a transaction is outstanding and not this-cycle-done.
            assert(!(done_o && state_q == S_IDLE));
            assert(!(busy_o && done_o));

            // The race this checkpoint's real fix closes: busy_o must be
            // high THE SAME CYCLE a transaction starts (state_q still
            // S_IDLE, a request just presented), not only once state_q
            // has registered away from S_IDLE next cycle.
            if (state_q == S_IDLE && (mem_read_i || mem_write_i)) assert(busy_o);
        end
    end

    `undef WEQ

    always_comb begin
        cover(state_q == S_WRESP && bvalid_i);
        cover(state_q == S_READ_DATA && rvalid_i);
        cover(awvalid_o && !awready_i);  // VALID held for >1 cycle, reachable
    end
`endif

endmodule
