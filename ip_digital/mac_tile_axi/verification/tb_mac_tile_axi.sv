// tb_mac_tile_axi.sv — self-checking testbench for mac_tile_axi, used by
// Pillar 4 (Verilator sim/coverage) and Pillar 8 (GLS).
//
// Drives the AXI4-Lite control port and the raw AXI4-Stream data ports
// purely at the PORT level (no internal hierarchy peeking) -- unlike
// rv32i_soc's own tb_rv32i_soc.sv, this doesn't need an `ifdef GLS split:
// every signal this TB reads/drives is a module port, which survives
// synthesis unchanged, so the identical check works for both RTL sim and
// GLS without a reduced fallback.
//
// Runs the same identity-probe test cocotb's test_identity_probe covers
// (weights loaded, A=identity streamed, Y should equal each weight row
// exactly) -- golden values below are hand-computed from the same W used
// there, kept in sync deliberately for cross-check value, not copied
// programmatically.
`timescale 1ns/1ps

module tb_mac_tile_axi;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic        awvalid_i, awready_o, wvalid_i, wready_o, bvalid_o, bready_i;
    logic [7:0]  awaddr_i;
    logic [2:0]  awprot_i, arprot_i;
    logic [31:0] wdata_i;
    logic [3:0]  wstrb_i;
    /* verilator lint_off UNUSEDSIGNAL */
    // bresp_o/rresp_o: every write/read in this TB is expected to succeed
    // (no deliberate SLVERR probe here); not checked.
    logic [1:0]  bresp_o, rresp_o;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        arvalid_i, arready_o, rvalid_o, rready_i;
    logic [7:0]  araddr_i;
    logic [31:0] rdata_o;

    logic        s_axis_tvalid_i, s_axis_tready_o, s_axis_tlast_i;
    logic [31:0] s_axis_tdata_i;
    logic        m_axis_tvalid_o, m_axis_tready_i, m_axis_tlast_o;
    logic [127:0] m_axis_tdata_o;

    mac_tile_axi u_dut (
        .clk (clk), .rst_n (rst_n),
        .awvalid_i (awvalid_i), .awready_o (awready_o),
        .awaddr_i (awaddr_i), .awprot_i (awprot_i),
        .wvalid_i (wvalid_i), .wready_o (wready_o),
        .wdata_i (wdata_i), .wstrb_i (wstrb_i),
        .bvalid_o (bvalid_o), .bready_i (bready_i), .bresp_o (bresp_o),
        .arvalid_i (arvalid_i), .arready_o (arready_o),
        .araddr_i (araddr_i), .arprot_i (arprot_i),
        .rvalid_o (rvalid_o), .rready_i (rready_i),
        .rdata_o (rdata_o), .rresp_o (rresp_o),
        .s_axis_tvalid_i (s_axis_tvalid_i), .s_axis_tready_o (s_axis_tready_o),
        .s_axis_tdata_i (s_axis_tdata_i), .s_axis_tlast_i (s_axis_tlast_i),
        .m_axis_tvalid_o (m_axis_tvalid_o), .m_axis_tready_i (m_axis_tready_i),
        .m_axis_tdata_o (m_axis_tdata_o), .m_axis_tlast_o (m_axis_tlast_o)
    );

    initial begin
        $dumpfile("sim_mac_tile_axi.fst");
        $dumpvars(0, tb_mac_tile_axi);
    end

    initial begin
        #200_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

    // -----------------------------------------------------------------
    // AXI4-Lite manager tasks.
    // -----------------------------------------------------------------
    task automatic axi_write(input [7:0] addr, input [31:0] data);
        begin
            awvalid_i = 1; awaddr_i = addr; awprot_i = 0;
            wvalid_i  = 1; wdata_i  = data; wstrb_i  = 4'hF;
            fork
                begin
                    wait (awready_o);
                    @(posedge clk);
                    awvalid_i = 0;
                end
                begin
                    wait (wready_o);
                    @(posedge clk);
                    wvalid_i = 0;
                end
            join
            bready_i = 1;
            wait (bvalid_o);
            @(posedge clk);
            bready_i = 0;
        end
    endtask

    task automatic axi_read(input [7:0] addr, output [31:0] data);
        begin
            arvalid_i = 1; araddr_i = addr; arprot_i = 0; rready_i = 1;
            wait (arready_o);
            @(posedge clk);
            arvalid_i = 0;
            wait (rvalid_o);
            data = rdata_o;
            @(posedge clk);
            rready_i = 0;
        end
    endtask

    integer errors;
    /* verilator lint_off UNUSEDSIGNAL */
    // Only bits [1:0] (WEIGHTS_LOADED/BUSY) are ever checked against this
    // scratch register; the rest of STATUS is read but not polled here.
    reg [31:0] rd_scratch;
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        errors = 0;
        awvalid_i = 0; wvalid_i = 0; bready_i = 0;
        arvalid_i = 0; rready_i = 0;
        s_axis_tvalid_i = 0; s_axis_tdata_i = 0; s_axis_tlast_i = 0;
        m_axis_tready_i = 1;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Load weights: W = [[3,-7,12,-1],[8,0,-4,9],[-2,15,6,-11],[1,-1,100,-100]]
        axi_write(8'h00, 32'h00000000);            // CTRL: external mode, no load yet
        axi_write(8'h08, 32'hFF0CF903);             // WEIGHT_ROW0
        axi_write(8'h0C, 32'h09FC0008);             // WEIGHT_ROW1
        axi_write(8'h10, 32'hF5060FFE);             // WEIGHT_ROW2
        axi_write(8'h14, 32'h9C64FF01);             // WEIGHT_ROW3
        axi_write(8'h00, 32'h00000001);             // CTRL.LOAD_WEIGHTS

        // Poll STATUS.WEIGHTS_LOADED.
        for (int i = 0; i < 20; i++) begin
            axi_read(8'h04, rd_scratch);
            if (rd_scratch[0] && !rd_scratch[1]) i = 20;
            else @(posedge clk);
        end
        if (!rd_scratch[0]) begin
            $display("TB_MAC_TILE_AXI: FAIL -- weights never reported loaded");
            errors = errors + 1;
        end

        // Stream A = identity, collect results concurrently.
        fork
            begin  // driver
                s_axis_tdata_i = 32'h00000001; s_axis_tlast_i = 0; s_axis_tvalid_i = 1;
                do @(posedge clk); while (!s_axis_tready_o);
                s_axis_tdata_i = 32'h00000100; s_axis_tlast_i = 0;
                do @(posedge clk); while (!s_axis_tready_o);
                s_axis_tdata_i = 32'h00010000; s_axis_tlast_i = 0;
                do @(posedge clk); while (!s_axis_tready_o);
                s_axis_tdata_i = 32'h01000000; s_axis_tlast_i = 1;
                do @(posedge clk); while (!s_axis_tready_o);
                s_axis_tvalid_i = 0; s_axis_tlast_i = 0;
            end
            begin  // monitor
                reg [127:0] got [4];
                reg [127:0] golden_y [4];
                integer n;
                golden_y[0] = {32'hFFFFFFFF, 32'h0000000C, 32'hFFFFFFF9, 32'h00000003};
                golden_y[1] = {32'h00000009, 32'hFFFFFFFC, 32'h00000000, 32'h00000008};
                golden_y[2] = {32'hFFFFFFF5, 32'h00000006, 32'h0000000F, 32'hFFFFFFFE};
                golden_y[3] = {32'hFFFFFF9C, 32'h00000064, 32'hFFFFFFFF, 32'h00000001};
                n = 0;
                while (n < 4) begin
                    @(posedge clk);
                    if (m_axis_tvalid_o && m_axis_tready_i) begin
                        got[n] = m_axis_tdata_o;
                        if (got[n] !== golden_y[n]) begin
                            $display("TB_MAC_TILE_AXI: MISMATCH row %0d: got 0x%032x expected 0x%032x",
                                      n, got[n], golden_y[n]);
                            errors = errors + 1;
                        end else begin
                            $display("TB_MAC_TILE_AXI: OK row %0d matched", n);
                        end
                        if (n == 3 && !m_axis_tlast_o) begin
                            $display("TB_MAC_TILE_AXI: MISMATCH -- tlast not set on final row");
                            errors = errors + 1;
                        end
                        n = n + 1;
                    end
                end
            end
        join

        if (errors == 0) $display("TB_MAC_TILE_AXI: PASS -- all checks matched");
        else begin
            $display("TB_MAC_TILE_AXI: FAIL -- %0d error(s)", errors);
            $error("mac_tile_axi self-check failed");
        end
        $finish;
    end

endmodule
