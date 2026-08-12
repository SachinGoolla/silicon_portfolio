// axi_lite_mem_bfm.sv — small AXI4-Lite slave memory model for rv32i_core's
// standalone testbenches. Not a real peripheral (that composition is
// rv32i_soc's job, later) — just enough RAM + protocol behavior to
// exercise rv32i_lsu.sv as a real bus master, including a genuine
// multi-cycle stall (READY held low for a couple of cycles after VALID,
// not purely combinational back-to-back) so the whole-pipeline freeze
// path (rv32i_hazard_unit's stage_en, gated by this module's own latency)
// gets exercised for more than the FSM's own minimum 3-cycle overhead.
`timescale 1ns/1ps

module axi_lite_mem_bfm #(
    parameter int MEM_WORDS = 128
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic         awvalid_i,
    output logic         awready_o,
    input  logic [31:0]  awaddr_i,
    input  logic [2:0]   awprot_i,

    input  logic         wvalid_i,
    output logic         wready_o,
    input  logic [31:0]  wdata_i,
    input  logic [3:0]   wstrb_i,

    output logic         bvalid_o,
    input  logic         bready_i,
    output logic [1:0]   bresp_o,

    input  logic         arvalid_i,
    output logic         arready_o,
    input  logic [31:0]  araddr_i,
    input  logic [2:0]   arprot_i,

    output logic         rvalid_o,
    input  logic         rready_i,
    output logic [31:0]  rdata_o,
    output logic [1:0]   rresp_o
);

    logic [31:0] mem [0:MEM_WORDS-1];

    // This is the TB-side memory MODEL's own backing store, not DUT
    // state -- zero-initializing it is a normal simulation convenience
    // (a benign default a real testbench loads), not a claim about real
    // RAM's power-on value the way rv32i_regfile.sv's own header comment
    // deliberately avoids for the CPU's actual register file.
    integer init_i;
    initial begin
        for (init_i = 0; init_i < MEM_WORDS; init_i = init_i + 1) mem[init_i] = 32'd0;
    end

    // -----------------------------------------------------------------
    // Write channel: independent AW/W acceptance (matching rv32i_lsu's
    // own independent-tracking discipline), each held for 2 cycles of
    // artificial latency before READY asserts, then the write commits
    // and B responds one cycle later.
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {W_IDLE, W_DELAY, W_RESP} wstate_e;
    wstate_e wstate_q;
    logic [1:0] wdelay_q;
    logic       aw_seen_q, w_seen_q;
    logic [31:0] awaddr_q;
    logic [31:0] wdata_q;
    logic [3:0]  wstrb_q;

    assign awready_o = (wstate_q == W_DELAY) && !aw_seen_q && (wdelay_q == 2'd0);
    assign wready_o   = (wstate_q == W_DELAY) && !w_seen_q  && (wdelay_q == 2'd0);
    assign bvalid_o   = (wstate_q == W_RESP);
    assign bresp_o    = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wstate_q  <= W_IDLE;
            wdelay_q  <= 2'd0;
            aw_seen_q <= 1'b0;
            w_seen_q  <= 1'b0;
            awaddr_q  <= 32'd0;
            wdata_q   <= 32'd0;
            wstrb_q   <= 4'd0;
        end else begin
            unique case (wstate_q)
                W_IDLE: begin
                    if (awvalid_i || wvalid_i) begin
                        wstate_q  <= W_DELAY;
                        wdelay_q  <= 2'd2;
                        aw_seen_q <= 1'b0;
                        w_seen_q  <= 1'b0;
                    end
                end
                W_DELAY: begin
                    if (wdelay_q != 2'd0) begin
                        wdelay_q <= wdelay_q - 2'd1;
                    end else begin
                        if (awvalid_i && !aw_seen_q) begin
                            aw_seen_q <= 1'b1;
                            awaddr_q  <= awaddr_i;
                        end
                        if (wvalid_i && !w_seen_q) begin
                            w_seen_q <= 1'b1;
                            wdata_q  <= wdata_i;
                            wstrb_q  <= wstrb_i;
                        end
                        if ((aw_seen_q || awvalid_i) && (w_seen_q || wvalid_i)) begin
                            wstate_q <= W_RESP;
                        end
                    end
                end
                W_RESP: begin
                    if (bready_i) wstate_q <= W_IDLE;
                end
                default: wstate_q <= W_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] commit_addr = (wstate_q == W_DELAY && wdelay_q == 2'd0)
                              ? (aw_seen_q ? awaddr_q : awaddr_i) : awaddr_q;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] commit_data = (wstate_q == W_DELAY && wdelay_q == 2'd0)
                              ? (w_seen_q ? wdata_q : wdata_i) : wdata_q;
    wire [3:0]  commit_strb = (wstate_q == W_DELAY && wdelay_q == 2'd0)
                              ? (w_seen_q ? wstrb_q : wstrb_i) : wstrb_q;
    wire        commit_fire = (wstate_q == W_DELAY) && (wdelay_q == 2'd0) &&
                               (aw_seen_q || awvalid_i) && (w_seen_q || wvalid_i);

    always_ff @(posedge clk) begin
        if (commit_fire) begin
            if (commit_strb[0]) mem[commit_addr[$clog2(MEM_WORDS)+1:2]][7:0]   <= commit_data[7:0];
            if (commit_strb[1]) mem[commit_addr[$clog2(MEM_WORDS)+1:2]][15:8]  <= commit_data[15:8];
            if (commit_strb[2]) mem[commit_addr[$clog2(MEM_WORDS)+1:2]][23:16] <= commit_data[23:16];
            if (commit_strb[3]) mem[commit_addr[$clog2(MEM_WORDS)+1:2]][31:24] <= commit_data[31:24];
        end
    end

    // -----------------------------------------------------------------
    // Read channel: same 2-cycle artificial latency before ARREADY,
    // then RVALID one cycle later with the read data.
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {R_IDLE, R_DELAY, R_DATA} rstate_e;
    rstate_e rstate_q;
    logic [1:0] rdelay_q;
    logic [31:0] rdata_q;

    assign arready_o = (rstate_q == R_DELAY) && (rdelay_q == 2'd0);
    assign rvalid_o   = (rstate_q == R_DATA);
    assign rdata_o    = rdata_q;
    assign rresp_o    = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate_q <= R_IDLE;
            rdelay_q <= 2'd0;
            rdata_q  <= 32'd0;
        end else begin
            unique case (rstate_q)
                R_IDLE: begin
                    if (arvalid_i) begin
                        rstate_q <= R_DELAY;
                        rdelay_q <= 2'd2;
                    end
                end
                R_DELAY: begin
                    if (rdelay_q != 2'd0) begin
                        rdelay_q <= rdelay_q - 2'd1;
                    end else begin
                        // araddr_i, not a latched copy: ARVALID is
                        // sticky (proven by rv32i_lsu.sby), so the
                        // address is guaranteed stable through this
                        // whole R_IDLE->R_DELAY span -- reading it live
                        // at the handshake cycle is correct AXI
                        // semantics, no separate latch needed.
                        rdata_q  <= mem[araddr_i[$clog2(MEM_WORDS)+1:2]];
                        rstate_q <= R_DATA;
                    end
                end
                R_DATA: begin
                    if (rready_i) rstate_q <= R_IDLE;
                end
                default: rstate_q <= R_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused;
    assign _unused = ^{awprot_i, arprot_i, araddr_i};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
