// tb_fpu_axi_periph.sv — self-checking Verilator/Icarus testbench.
//
// Drives the AXI4-Lite register interface (same task style as
// tb_axi_lite_slave.sv) and exercises the FPU compute path through the
// register map. No fork/join — Verilator-compatible.
//
// Tests
//   T1  Reset: STATUS/RESULT read 0
//   T2  FADD  1.0 + 1.0 = 2.0
//   T3  FMUL  2.0 * 3.0 = 6.0
//   T4  FMADD 2.0*3.0+1.0 = 7.0 (exercises OPC)
//   T5  FCVT.S.W int32(3) -> 3.0 (exercises INT_OPA)
//   T6  SLVERR on out-of-range read
//   T7  Back-to-back ops: DONE clears on new START
`timescale 1ns/1ps

`define DATA_WIDTH 32
`define ADDR_WIDTH 8

module tb_fpu_axi_periph;

    logic clk   = 0;
    logic rst_n = 0;

    logic                    awvalid, awready;
    logic [`ADDR_WIDTH-1:0]  awaddr;
    logic [2:0]              awprot;
    logic                    wvalid, wready;
    logic [`DATA_WIDTH-1:0]  wdata;
    logic [3:0]              wstrb;
    logic                    bvalid, bready;
    logic [1:0]              bresp;
    logic                    arvalid, arready;
    logic [`ADDR_WIDTH-1:0]  araddr;
    logic [2:0]              arprot;
    logic                    rvalid, rready;
    logic [`DATA_WIDTH-1:0]  rdata;
    logic [1:0]              rresp;

    fpu_axi_periph dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .awvalid_i (awvalid), .awready_o (awready),
        .awaddr_i  (awaddr),  .awprot_i  (awprot),
        .wvalid_i  (wvalid),  .wready_o  (wready),
        .wdata_i   (wdata),   .wstrb_i   (wstrb),
        .bvalid_o  (bvalid),  .bready_i  (bready),
        .bresp_o   (bresp),
        .arvalid_i (arvalid), .arready_o (arready),
        .araddr_i  (araddr),  .arprot_i  (arprot),
        .rvalid_o  (rvalid),  .rready_i  (rready),
        .rdata_o   (rdata),   .rresp_o   (rresp)
    );

    always #5 clk = ~clk;

    int errors = 0;

    localparam logic [`ADDR_WIDTH-1:0] CTRL       = 8'h00;
    localparam logic [`ADDR_WIDTH-1:0] OPA        = 8'h04;
    localparam logic [`ADDR_WIDTH-1:0] OPB        = 8'h08;
    localparam logic [`ADDR_WIDTH-1:0] OPC        = 8'h0C;
    localparam logic [`ADDR_WIDTH-1:0] INT_OPA    = 8'h10;
    localparam logic [`ADDR_WIDTH-1:0] RESULT     = 8'h14;
    localparam logic [`ADDR_WIDTH-1:0] INT_RESULT = 8'h18;
    localparam logic [`ADDR_WIDTH-1:0] STATUS     = 8'h1C;

    localparam [5:0] OP_FADD      = 6'h00;
    localparam [5:0] OP_FMUL      = 6'h02;
    localparam [5:0] OP_FMADD     = 6'h03;
    localparam [5:0] OP_FCVT_S_W  = 6'h22;

    localparam [31:0] FP_ONE   = 32'h3F80_0000;  // 1.0
    localparam [31:0] FP_TWO   = 32'h4000_0000;  // 2.0
    localparam [31:0] FP_THREE = 32'h4040_0000;  // 3.0
    localparam [31:0] FP_SIX   = 32'h40C0_0000;  // 6.0
    localparam [31:0] FP_SEVEN = 32'h40E0_0000;  // 7.0

    // ----------------------------------------------------------------
    // AXI4-Lite master tasks
    // ----------------------------------------------------------------
    task automatic axi_write(
        input  logic [`ADDR_WIDTH-1:0] addr,
        input  logic [`DATA_WIDTH-1:0] data,
        output logic [1:0]             out_resp
    );
        awvalid = 1; awaddr = addr; awprot = 3'b000;
        wvalid  = 1; wdata  = data; wstrb  = 4'hF;
        begin : aw_w_loop
            logic aw_done, w_done;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (awready && awvalid) begin aw_done = 1; awvalid = 0; end
                if (wready  && wvalid)  begin w_done  = 1; wvalid  = 0; end
            end
        end
        bready = 1;
        while (!bvalid) @(posedge clk);
        out_resp = bresp;
        @(posedge clk);
        bready = 0;
    endtask

    task automatic axi_read(
        input  logic [`ADDR_WIDTH-1:0]  addr,
        output logic [`DATA_WIDTH-1:0]  out_data,
        output logic [1:0]              out_resp
    );
        arvalid = 1; araddr = addr; arprot = 3'b000;
        rready  = 1;
        @(posedge clk);
        while (!(arready && arvalid)) @(posedge clk);
        arvalid = 0;
        while (!rvalid) @(posedge clk);
        out_data = rdata;
        out_resp = rresp;
        @(posedge clk);
        rready = 0;
    endtask

    task automatic wait_done(output logic [`DATA_WIDTH-1:0] status);
        integer polls;
        logic [1:0] resp;
        // Synchronize on BUSY=1 first — the CTRL write's effect (clearing
        // the *previous* op's DONE and asserting BUSY) is not instant, so
        // polling STATUS immediately after the CTRL write can observe a
        // stale DONE=1 left over from the prior operation. Waiting for
        // BUSY=1 confirms this new op has actually started before we look
        // for its completion.
        polls = 0;
        status = 0;
        while (status[0] === 1'b0 && polls <= 40) begin
            axi_read(STATUS, status, resp);
            polls++;
        end
        polls = 0;
        while (status[1] === 1'b0 && polls <= 40) begin
            axi_read(STATUS, status, resp);
            polls++;
        end
        if (status[1] === 1'b0) begin
            $error("wait_done: operation did not complete within 40 polls");
            errors++;
        end
    endtask

    task automatic run_op(
        input  logic [5:0]  op,
        input  logic [31:0] opa, opb, opc, int_opa,
        output logic [31:0] result, int_result,
        output logic [4:0]  fflags
    );
        logic [1:0]  resp;
        logic [31:0] status;
        logic [31:0] ctrl_word;
        ctrl_word = {21'd0, 3'd0, 2'd0, op};  // [31:11]=0 [10:8]=rm=RNE [7:6]=fmt=0 [5:0]=op
        axi_write(OPA, opa, resp);
        axi_write(OPB, opb, resp);
        axi_write(OPC, opc, resp);
        axi_write(INT_OPA, int_opa, resp);
        axi_write(CTRL, ctrl_word, resp);
        if (resp !== 2'b00) begin
            $error("run_op: CTRL write SLVERR"); errors++;
        end
        wait_done(status);
        fflags = status[6:2];
        axi_read(RESULT, result, resp);
        axi_read(INT_RESULT, int_result, resp);
    endtask

    task check_eq(input string tag, input logic [31:0] got, exp);
        if (got !== exp) begin
            $error("%s: expected 0x%08h, got 0x%08h", tag, exp, got);
            errors++;
        end
    endtask

    // ----------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------
    logic [31:0] rd_data, result, int_result, status_v;
    logic [4:0]  fflags;
    logic [1:0]  rd_resp;

    initial begin
        $dumpfile("sim_fpu_axi_periph.fst");
        $dumpvars(0, tb_fpu_axi_periph);

        awvalid = 0; awaddr = '0; awprot = '0;
        wvalid  = 0; wdata  = '0; wstrb  = '0;
        bready  = 0;
        arvalid = 0; araddr = '0; arprot = '0;
        rready  = 0;

        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // --- T1: Reset -------------------------------------------------
        axi_read(STATUS, rd_data, rd_resp);
        check_eq("T1 STATUS", rd_data, 32'h0);
        axi_read(RESULT, rd_data, rd_resp);
        check_eq("T1 RESULT", rd_data, 32'h0);
        $display("T1 PASS: reset state clear");

        // --- T2: FADD 1.0 + 1.0 = 2.0 ------------------------------------
        run_op(OP_FADD, FP_ONE, FP_ONE, 32'd0, 32'd0, result, int_result, fflags);
        check_eq("T2 FADD result", result, FP_TWO);
        if (fflags !== 5'd0) begin $error("T2: unexpected fflags 0x%0h", fflags); errors++; end
        $display("T2 PASS: FADD 1.0+1.0=2.0");

        // --- T3: FMUL 2.0 * 3.0 = 6.0 ------------------------------------
        run_op(OP_FMUL, FP_TWO, FP_THREE, 32'd0, 32'd0, result, int_result, fflags);
        check_eq("T3 FMUL result", result, FP_SIX);
        $display("T3 PASS: FMUL 2.0*3.0=6.0");

        // --- T4: FMADD 2.0*3.0+1.0 = 7.0 (exercises OPC) -----------------
        run_op(OP_FMADD, FP_TWO, FP_THREE, FP_ONE, 32'd0, result, int_result, fflags);
        check_eq("T4 FMADD result", result, FP_SEVEN);
        $display("T4 PASS: FMADD 2.0*3.0+1.0=7.0");

        // --- T5: FCVT.S.W int32(3) -> 3.0 (exercises INT_OPA) ------------
        run_op(OP_FCVT_S_W, 32'd0, 32'd0, 32'd0, 32'd3, result, int_result, fflags);
        check_eq("T5 FCVT.S.W result", result, FP_THREE);
        $display("T5 PASS: FCVT.S.W int(3)=3.0");

        // --- T6: SLVERR on out-of-range read ------------------------------
        axi_read(8'h40, rd_data, rd_resp);
        if (rd_resp !== 2'b10) begin
            $error("T6: expected SLVERR, got %0b", rd_resp); errors++;
        end
        $display("T6 PASS: SLVERR on out-of-range read");

        // --- T7: Back-to-back — DONE clears on new START ------------------
        run_op(OP_FADD, FP_ONE, FP_ONE, 32'd0, 32'd0, result, int_result, fflags);
        check_eq("T7a result", result, FP_TWO);
        run_op(OP_FMUL, FP_TWO, FP_THREE, 32'd0, 32'd0, result, int_result, fflags);
        check_eq("T7b result", result, FP_SIX);
        $display("T7 PASS: back-to-back ops");

        repeat(4) @(posedge clk);

        if (errors == 0) $display("ALL TESTS PASSED");
        else              $error("%0d test(s) FAILED", errors);
        $finish;
    end

    initial begin
        #500_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

endmodule
