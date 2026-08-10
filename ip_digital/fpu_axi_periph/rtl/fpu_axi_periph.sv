// fpu_axi_periph.sv — AXI4-Lite peripheral wrapping fpu_top behind a
// software-programmable register file.
//
// Composition (single clock domain, v1):
//   axi_lite_slave  — AXI4-Lite protocol engine + register file
//   fpu_top         — IEEE-754 FP32 compute core (valid/ready streaming)
//   this module     — register map + start/done glue FSM
//
// Register map (word-addressed, DATA_WIDTH=32)
//   0x00 CTRL        [5:0]=op [7:6]=fmt [10:8]=rm  — any write pulses START
//   0x04 OPA         FP operand A (src_a_i)
//   0x08 OPB         FP operand B (src_b_i)
//   0x0C OPC         FP operand C (src_c_i, FMA addend)
//   0x10 INT_OPA     Integer operand (int_src_i, FCVT.S.W / FMV.W.X)
//   0x14 RESULT      FP result (result_o)            — HW-write-only
//   0x18 INT_RESULT  Integer result (int_result_o)    — HW-write-only
//   0x1C STATUS      [0]=BUSY [1]=DONE [6:2]=FFLAGS   — HW-write-only
//
// Sequencing: software writes OPA/OPB/OPC/INT_OPA first, then writes CTRL
// last to launch — the CTRL write's reg_we_o pulse is registered one cycle
// (ctrl_we_q) so regfile_o already reflects the just-committed CTRL value
// when it is latched; OPA/OPB/OPC/INT_OPA were committed in earlier, already
// -settled AXI transactions so no extra delay is needed for them.
//
// BUSY is asserted for the full outstanding-operation window (from START
// until fpu_top posts a result) rather than passing through fpu_top's own
// busy_o, which only covers iterative div/sqrt — a truer "operation in
// flight" indicator for a polling software driver. DONE holds until the
// next START (no read-to-clear); STATUS is a plain snapshot register.
`timescale 1ns/1ps

module fpu_axi_periph #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int FLEN       = 32,
    parameter int XLEN       = 32
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // --- AW: Write Address ---
    input  logic                      awvalid_i,
    output logic                      awready_o,
    input  logic [ADDR_WIDTH-1:0]     awaddr_i,
    input  logic [2:0]                awprot_i,

    // --- W: Write Data ---
    input  logic                      wvalid_i,
    output logic                      wready_o,
    input  logic [DATA_WIDTH-1:0]     wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] wstrb_i,

    // --- B: Write Response ---
    output logic                      bvalid_o,
    input  logic                      bready_i,
    output logic [1:0]                bresp_o,

    // --- AR: Read Address ---
    input  logic                      arvalid_i,
    output logic                      arready_o,
    input  logic [ADDR_WIDTH-1:0]     araddr_i,
    input  logic [2:0]                arprot_i,

    // --- R: Read Data ---
    output logic                      rvalid_o,
    input  logic                      rready_i,
    output logic [DATA_WIDTH-1:0]     rdata_o,
    output logic [1:0]                rresp_o
);

    localparam int NUM_REGS      = 8;
    localparam int IDX_CTRL      = 0;
    localparam int IDX_OPA       = 1;
    localparam int IDX_OPB       = 2;
    localparam int IDX_OPC       = 3;
    localparam int IDX_INT_OPA   = 4;
    localparam int IDX_RESULT    = 5;
    localparam int IDX_INT_RES   = 6;
    localparam int IDX_STATUS    = 7;

    // -----------------------------------------------------------------
    // AXI4-Lite register file
    // -----------------------------------------------------------------
    logic [NUM_REGS*DATA_WIDTH-1:0] regfile;
    logic [NUM_REGS-1:0]            reg_we;
    logic [NUM_REGS*DATA_WIDTH-1:0] hw_wdata;
    logic [NUM_REGS-1:0]            hw_we;

    axi_lite_slave #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (ADDR_WIDTH),
        .NUM_REGS   (NUM_REGS)
    ) u_regs (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid_i  (awvalid_i), .awready_o (awready_o),
        .awaddr_i   (awaddr_i),  .awprot_i  (awprot_i),
        .wvalid_i   (wvalid_i),  .wready_o  (wready_o),
        .wdata_i    (wdata_i),   .wstrb_i   (wstrb_i),
        .bvalid_o   (bvalid_o),  .bready_i  (bready_i),
        .bresp_o    (bresp_o),
        .arvalid_i  (arvalid_i), .arready_o (arready_o),
        .araddr_i   (araddr_i),  .arprot_i  (arprot_i),
        .rvalid_o   (rvalid_o),  .rready_i  (rready_i),
        .rdata_o    (rdata_o),   .rresp_o   (rresp_o),
        .regfile_o  (regfile),   .reg_we_o  (reg_we),
        .hw_wdata_i (hw_wdata),  .hw_we_i   (hw_we)
    );

    // -----------------------------------------------------------------
    // fpu_top compute core
    // -----------------------------------------------------------------
    logic                  fpu_valid_i, fpu_ready_o;
    logic [5:0]             fpu_op;
    logic [1:0]              fpu_fmt;
    logic [2:0]              fpu_rm;
    logic [FLEN-1:0]        fpu_src_a, fpu_src_b, fpu_src_c;
    logic [XLEN-1:0]        fpu_int_src;
    logic [FLEN-1:0]        fpu_result;
    logic [XLEN-1:0]        fpu_int_result;
    logic                    fpu_valid_o, fpu_busy_o;
    logic [4:0]              fpu_fflags;

    fpu_top #(
        .FLEN (FLEN),
        .XLEN (XLEN)
    ) u_fpu (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_i      (fpu_valid_i),
        .ready_o      (fpu_ready_o),
        .op_i         (fpu_op),
        .fmt_i        (fpu_fmt),
        .rm_i         (fpu_rm),
        .src_a_i      (fpu_src_a),
        .src_b_i      (fpu_src_b),
        .src_c_i      (fpu_src_c),
        .int_src_i    (fpu_int_src),
        .ready_i      (1'b1),
        .result_o     (fpu_result),
        .int_result_o (fpu_int_result),
        .valid_o      (fpu_valid_o),
        .busy_o       (fpu_busy_o),
        .fflags_o     (fpu_fflags)
    );

    // -----------------------------------------------------------------
    // Start/done glue FSM
    // -----------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_WAIT} state_e;
    state_e state_q, state_d;

    // CTRL-write pulse, registered so regfile already reflects the new
    // CTRL value on the cycle it is consumed (see header comment).
    logic ctrl_we_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) ctrl_we_q <= 1'b0;
        else        ctrl_we_q <= reg_we[IDX_CTRL];

    logic [5:0]       op_q;
    logic [1:0]       fmt_q;
    logic [2:0]       rm_q;
    logic [FLEN-1:0]  opa_q, opb_q, opc_q;
    logic [XLEN-1:0]  int_opa_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
        end else begin
            state_q <= state_d;
            if (state_q == S_IDLE && ctrl_we_q) begin
                op_q      <= regfile[IDX_CTRL*DATA_WIDTH +: 6];
                fmt_q     <= regfile[IDX_CTRL*DATA_WIDTH+6 +: 2];
                rm_q      <= regfile[IDX_CTRL*DATA_WIDTH+8 +: 3];
                opa_q     <= regfile[IDX_OPA*DATA_WIDTH +: FLEN];
                opb_q     <= regfile[IDX_OPB*DATA_WIDTH +: FLEN];
                opc_q     <= regfile[IDX_OPC*DATA_WIDTH +: FLEN];
                int_opa_q <= regfile[IDX_INT_OPA*DATA_WIDTH +: XLEN];
            end
        end
    end

    always_comb begin
        state_d = state_q;
        unique case (state_q)
            S_IDLE:  if (ctrl_we_q)              state_d = S_ISSUE;
            S_ISSUE: if (fpu_valid_i && fpu_ready_o) state_d = S_WAIT;
            S_WAIT:  if (fpu_valid_o)             state_d = S_IDLE;
            default:                              state_d = S_IDLE;
        endcase
    end

    assign fpu_valid_i = (state_q == S_ISSUE);
    assign fpu_op      = op_q;
    assign fpu_fmt     = fmt_q;
    assign fpu_rm      = rm_q;
    assign fpu_src_a   = opa_q;
    assign fpu_src_b   = opb_q;
    assign fpu_src_c   = opc_q;
    assign fpu_int_src = int_opa_q;

    always_comb begin
        hw_we    = '0;
        hw_wdata = '0;
        unique case (state_q)
            S_IDLE: if (ctrl_we_q) begin
                hw_we[IDX_STATUS] = 1'b1;
                hw_wdata[IDX_STATUS*DATA_WIDTH +: DATA_WIDTH] =
                    {{(DATA_WIDTH-7){1'b0}}, 5'd0, 1'b0, 1'b1};  // fflags=0 done=0 busy=1
            end
            S_WAIT: if (fpu_valid_o) begin
                hw_we[IDX_RESULT]  = 1'b1;
                hw_wdata[IDX_RESULT*DATA_WIDTH +: DATA_WIDTH]  = {{(DATA_WIDTH-FLEN){1'b0}}, fpu_result};
                hw_we[IDX_INT_RES] = 1'b1;
                hw_wdata[IDX_INT_RES*DATA_WIDTH +: DATA_WIDTH] = {{(DATA_WIDTH-XLEN){1'b0}}, fpu_int_result};
                hw_we[IDX_STATUS]  = 1'b1;
                hw_wdata[IDX_STATUS*DATA_WIDTH +: DATA_WIDTH] =
                    {{(DATA_WIDTH-7){1'b0}}, fpu_fflags, 1'b1, 1'b0};  // done=1 busy=0
            end
            default: ;
        endcase
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // regfile[255:160] = RESULT/INT_RESULT/STATUS snapshot (indices 5-7) —
    // those are HW-write-only and read back over AXI, never through this
    // net. regfile[31:11] = CTRL's reserved/unused upper bits.
    logic _unused;
    assign _unused = ^{fpu_busy_o, awprot_i, arprot_i,
                        regfile[NUM_REGS*DATA_WIDTH-1:IDX_RESULT*DATA_WIDTH],
                        regfile[DATA_WIDTH-1:11]};
    /* verilator lint_on UNUSEDSIGNAL */

    // -----------------------------------------------------------------
    // Formal verification — start/done glue FSM safety properties.
    // u_regs (axi_lite_slave) and u_fpu (fpu_top) are blackboxed for this
    // proof (see fpu_axi_periph.sby) — both are already signed off by
    // their own standalone P2 formal; this checks only the new glue logic.
    // -----------------------------------------------------------------
`ifdef FORMAL
    // Force BMC's basecase through an actual reset before anything is
    // checked. The previous `initial f_reset_seen = 1'b0;` sole-gate flop
    // relied on a plain register's `initial` value being honored for its
    // own power-on state, which this Yosys build does not reliably do
    // (confirmed with a minimal repro elsewhere in this portfolio — see
    // project memory feedback_formal_sby / CLAUDE.md "Formal verification
    // idioms"). `initial assume(!rst_n);` is the confirmed-working idiom.
    initial assume(!rst_n);

    always_comb begin
        if (rst_n) begin
            // A STATUS write always encodes BUSY xor DONE (start vs. complete).
            if (hw_we[IDX_STATUS])
                assert(hw_wdata[IDX_STATUS*DATA_WIDTH] !=
                       hw_wdata[IDX_STATUS*DATA_WIDTH+1]);
            // RESULT/INT_RESULT are only ever written on completion.
            if (hw_we[IDX_RESULT] || hw_we[IDX_INT_RES])
                assert(state_q == S_WAIT);
            // The FPU is only issued to while actively in S_ISSUE.
            if (state_q == S_ISSUE) assert(fpu_valid_i);
            else                    assert(!fpu_valid_i);
        end
    end

    always_comb begin
        cover(rst_n && state_q == S_ISSUE);
        cover(rst_n && state_q == S_WAIT);
        cover(rst_n && hw_we[IDX_RESULT]);
    end
`endif

endmodule
