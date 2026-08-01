// tb_axi_lite_slave.sv — self-checking Verilator testbench.
//
// Drives an AXI4-Lite master model against the DUT register file.
// All transactions use tasks; no fork/join (Verilator-compatible).
//
// Tests
//   T1  Reset: all registers read as 0 after reset
//   T2  Basic write + read-back
//   T3  WSTRB partial write: byte-lane masking
//   T4  SLVERR on out-of-bounds write
//   T5  SLVERR on out-of-bounds read
//   T6  W before AW: reverse channel ordering (legal per AXI4-Lite spec)
//   T7  Simultaneous read and write to different registers
//   T8  B back-pressure: BREADY held low; BVALID must stay asserted
//
// Timing: CLK period = 10 ns; DUT parameters at defaults.
`timescale 1ns/1ps

`define DATA_WIDTH 32
`define ADDR_WIDTH 12
`define NUM_REGS   16
`define STRB_W     4   // DATA_WIDTH/8

module tb_axi_lite_slave;

    logic clk   = 0;
    logic rst_n = 0;

    // AXI4-Lite signals
    logic                    awvalid, awready;
    logic [`ADDR_WIDTH-1:0]  awaddr;
    logic [2:0]              awprot;
    logic                    wvalid, wready;
    logic [`DATA_WIDTH-1:0]  wdata;
    logic [`STRB_W-1:0]      wstrb;
    logic                    bvalid, bready;
    logic [1:0]              bresp;
    logic                    arvalid, arready;
    logic [`ADDR_WIDTH-1:0]  araddr;
    logic [2:0]              arprot;
    logic                    rvalid, rready;
    logic [`DATA_WIDTH-1:0]  rdata;
    logic [1:0]              rresp;
    logic [`NUM_REGS*`DATA_WIDTH-1:0] regfile;
    logic [`NUM_REGS-1:0]    reg_we;

`ifdef GLS
    axi_lite_slave dut (
`else
    axi_lite_slave #(
        .DATA_WIDTH(`DATA_WIDTH),
        .ADDR_WIDTH(`ADDR_WIDTH),
        .NUM_REGS  (`NUM_REGS)
    ) dut (
`endif
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
        .rdata_o   (rdata),   .rresp_o   (rresp),
        .regfile_o (regfile), .reg_we_o  (reg_we)
    );

    always #5 clk = ~clk;

    int errors = 0;

    // ----------------------------------------------------------------
    // AXI4-Lite master tasks
    // ----------------------------------------------------------------

    // Blocking write: drives AW+W simultaneously, waits for B response.
    // Returns bresp in out_resp.
    task automatic axi_write(
        input  logic [`ADDR_WIDTH-1:0] addr,
        input  logic [`DATA_WIDTH-1:0] data,
        input  logic [`STRB_W-1:0]     strb,
        output logic [1:0]             out_resp
    );
        // Phase 1: drive AW and W until both accepted
        awvalid = 1; awaddr = addr; awprot = 3'b000;
        wvalid  = 1; wdata  = data; wstrb  = strb;
        begin : aw_w_loop
            logic aw_done, w_done;
            aw_done = 0; w_done = 0;
            while (!(aw_done && w_done)) begin
                @(posedge clk);
                if (awready && awvalid) begin aw_done = 1; awvalid = 0; end
                if (wready  && wvalid)  begin w_done  = 1; wvalid  = 0; end
            end
        end

        // Phase 2: wait for B response
        bready = 1;
        while (!bvalid) @(posedge clk);
        out_resp = bresp;
        @(posedge clk);
        bready = 0;
    endtask

    // Blocking read: drives AR, waits for R response.
    // Returns rdata and rresp.
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

    // ----------------------------------------------------------------
    // Test helpers
    // ----------------------------------------------------------------
    task check_eq(input string tag,
                  input logic [`DATA_WIDTH-1:0] got, exp);
        if (got !== exp) begin
            $error("%s: expected 0x%08h, got 0x%08h", tag, exp, got);
            errors++;
        end
    endtask

    task check_resp(input string tag, input logic [1:0] got, exp);
        if (got !== exp) begin
            $error("%s: resp expected 0x%0h, got 0x%0h", tag, exp, got);
            errors++;
        end
    endtask

    // ----------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------
    logic [`DATA_WIDTH-1:0] rd_data;
    logic [1:0]             rd_resp, wr_resp;

    initial begin
        $dumpfile("sim_axi_lite_slave.fst");
        $dumpvars(0, tb_axi_lite_slave);

        // Idle all masters
        awvalid = 0; awaddr = '0; awprot = '0;
        wvalid  = 0; wdata  = '0; wstrb  = '0;
        bready  = 0;
        arvalid = 0; araddr = '0; arprot = '0;
        rready  = 0;

        // Reset
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        // --- T1: Reset — all registers read as 0 ---------------------
        begin : t1
            integer i;
            logic [`DATA_WIDTH-1:0] d;
            logic [1:0] r;
            for (i = 0; i < `NUM_REGS; i++) begin
                axi_read(`ADDR_WIDTH'(i*4), d, r);
                if (d !== '0 || r !== 2'b00) begin
                    $error("T1: reg[%0d] not zero after reset (d=0x%08h, r=%0b)", i, d, r);
                    errors++;
                end
            end
        end
        $display("T1 PASS: all registers zero after reset");

        // --- T2: Basic write + read-back ----------------------------
        axi_write(12'h004, 32'hDEAD_BEEF, 4'hF, wr_resp);
        check_resp("T2 write resp", wr_resp, 2'b00);
        axi_read (12'h004, rd_data, rd_resp);
        check_eq  ("T2 readback", rd_data, 32'hDEAD_BEEF);
        check_resp("T2 read resp", rd_resp, 2'b00);
        $display("T2 PASS: write/read 0xDEAD_BEEF to reg[1]");

        // --- T3: WSTRB partial write --------------------------------
        // First fill reg[2] with 0xFFFFFFFF
        axi_write(12'h008, 32'hFFFF_FFFF, 4'hF, wr_resp);
        // Write 0xAA to byte 3 only (WSTRB=0x8)
        axi_write(12'h008, 32'hAA00_0000, 4'h8, wr_resp);
        axi_read (12'h008, rd_data, rd_resp);
        check_eq  ("T3 wstrb", rd_data, 32'hAAFF_FFFF);  // byte3=AA, bytes0-2=FF
        $display("T3 PASS: WSTRB byte-lane masking");

        // --- T4: SLVERR on out-of-bounds write ----------------------
        // NUM_REGS=16, word size=4 bytes → OOB = 0x040 (12-bit)
        axi_write(12'h040, 32'hBAD1_CAFE, 4'hF, wr_resp);
        check_resp("T4 oob write", wr_resp, 2'b10);    // SLVERR=0x2
        $display("T4 PASS: SLVERR on out-of-bounds write");

        // --- T5: SLVERR on out-of-bounds read -----------------------
        axi_read(12'h040, rd_data, rd_resp);
        check_resp("T5 oob read", rd_resp, 2'b10);
        $display("T5 PASS: SLVERR on out-of-bounds read");

        // --- T6: W before AW (reversed channel ordering) ------------
        // Registered outputs update on @(posedge clk), so polling while(!wready) after
        // W capture deadlocks: w_pend_q=1 and commit=0 (no AW) → wready=0.
        // Use fixed 1-cycle sends — both buffers are empty at start of T6.
        wvalid = 1; wdata = 32'h1234_5678; wstrb = 4'hF;
        @(posedge clk);   // W captured (wready=1 since w_pend_q=0)
        wvalid = 0;
        // AW one cycle later; awready=1 since aw_pend_q=0
        awvalid = 1; awaddr = 12'h010; awprot = 3'b000;
        @(posedge clk);   // AW captured; both pending → commit fires next posedge
        awvalid = 0;
        // B response
        bready = 1;
        while (!bvalid) @(posedge clk);   // exits after commit posedge
        check_resp("T6 W-before-AW resp", bresp, 2'b00);
        @(posedge clk);   // B consumed (bvalid=1 && bready=1 → bvalid<=0)
        bready = 0;
        // Read back reg[4] (addr=0x010 → idx 4)
        axi_read(12'h010, rd_data, rd_resp);
        check_eq("T6 W-before-AW data", rd_data, 32'h1234_5678);
        $display("T6 PASS: W-before-AW ordering");

        // --- T7: Simultaneous read+write to different registers -----
        // AW+W both driven together (commit fires when both captured).
        // bready=0 so B stays asserted; we overlap AR with pending B.
        awvalid = 1; awaddr = 12'h00C; awprot = '0;
        wvalid  = 1; wdata  = 32'hC0FF_EE00; wstrb = 4'hF;
        bready  = 0;
        begin : t7_aw_w
            logic aw_done7, w_done7;
            aw_done7 = 0; w_done7 = 0;
            while (!(aw_done7 && w_done7)) begin
                @(posedge clk);
                if (awready && awvalid) begin aw_done7 = 1; awvalid = 0; end
                if (wready  && wvalid)  begin w_done7  = 1; wvalid  = 0; end
            end
        end
        // After loop: aw_pend_q=1, w_pend_q=1, commit=1 (bvalid=0).
        // Issue AR now (rvalid=0 → arready=1); hold rready=0 so R accumulates.
        arvalid = 1; araddr = 12'h008; arprot = '0; rready = 0;
        @(posedge clk);   // commit fires: bvalid<=1; AR accepted → rvalid<=1
        arvalid = 0;      // AR was captured at this posedge
        // Collect B (bvalid=1 after the posedge above)
        bready = 1;
        while (!bvalid) @(posedge clk);   // exits immediately (bvalid=1 already)
        wr_resp = bresp;
        @(posedge clk);   // B handshake: bvalid=1, bready=1 → bvalid<=0
        bready = 0;
        // Collect R (rvalid=1, rready was 0 so R was not consumed)
        rready = 1;
        while (!rvalid) @(posedge clk);   // rvalid=1 → exits immediately
        rd_data = rdata; rd_resp = rresp;
        @(posedge clk);   // R handshake: rvalid=1, rready=1 → rvalid<=0
        rready = 0;
        check_resp("T7 wr_resp", wr_resp, 2'b00);
        check_eq  ("T7 rd_data (reg[2]=0xAAFFFFFF)", rd_data, 32'hAAFF_FFFF);
        $display("T7 PASS: simultaneous pending B + AR");

        // --- T8: B back-pressure — BVALID must hold ----------------
        // Initiate a write with bready=0, verify bvalid stays for 5 cycles
        awvalid = 1; awaddr = 12'h000; awprot = '0;
        wvalid  = 1; wdata  = 32'hA5A5_A5A5; wstrb = 4'hF;
        bready  = 0;
        begin : t8_aw_w
            logic aw_d8, w_d8;
            aw_d8 = 0; w_d8 = 0;
            while (!(aw_d8 && w_d8)) begin
                @(posedge clk);
                if (awready && awvalid) begin aw_d8 = 1; awvalid = 0; end
                if (wready  && wvalid)  begin w_d8  = 1; wvalid  = 0; end
            end
        end
        // Wait until bvalid asserts
        while (!bvalid) @(posedge clk);
        // Hold for 5 cycles with bready=0; bvalid must remain asserted
        begin : t8_hold
            integer k;
            for (k = 0; k < 5; k++) begin
                @(posedge clk);
                if (!bvalid) begin
                    $error("T8: bvalid dropped with bready=0 at hold cycle %0d", k);
                    errors++;
                end
            end
        end
        bready = 1;
        @(posedge clk);
        bready = 0;
        $display("T8 PASS: BVALID sticky with BREADY=0");

        repeat(4) @(posedge clk);

        if (errors == 0) $display("ALL TESTS PASSED");
        else             $error("%0d test(s) FAILED", errors);
        $finish;
    end

    initial begin
        #500_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

endmodule
