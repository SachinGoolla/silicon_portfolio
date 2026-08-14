// tb_mac_cluster.sv — self-checking testbench for mac_cluster, used by
// Pillar 4 (Verilator sim/coverage) and Pillar 8 (GLS).
//
// Drives the single AXI4-Lite control port purely at the PORT level (no
// internal hierarchy peeking) -- mac_cluster's mesh/NI internals are not
// externally visible ports, unlike mac_tile_axi's own s_axis/m_axis, so
// this TB reaches every tile exclusively through the CSR/decoder address
// map documented in mac_cluster.sv's own header comment.
//
// Runs the SAME two-producer-chain scenario as cocotb's own
// test_two_producer_chain (tile0 (0,0) and tile1 (1,0) each forward one
// MAC result into the mesh, addressed to tile3 (1,1); tile2 is loaded with
// weights but never pushed). Golden values below are independently
// computed (see the Python one-liner in the commit that added this file)
// from the SAME W0/A0/W1/A1/W3 cocotb's own suite uses -- kept in sync
// deliberately for cross-check value against a second, independently
// implemented driver (Verilog tasks here vs. Python/cocotb there), not
// copied programmatically from one to the other.
`timescale 1ns/1ps

module tb_mac_cluster;

    localparam int DATA_WIDTH = 32;
    localparam int ADDR_WIDTH = 11;

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic                      awvalid_i, awready_o;
    logic [ADDR_WIDTH-1:0]     awaddr_i;
    logic [2:0]                awprot_i, arprot_i;
    logic                      wvalid_i, wready_o;
    logic [DATA_WIDTH-1:0]     wdata_i;
    logic [(DATA_WIDTH/8)-1:0] wstrb_i;
    logic                      bvalid_o, bready_i;
    /* verilator lint_off UNUSEDSIGNAL */
    // bresp_o/rresp_o: every write/read in this TB is expected to succeed
    // (no deliberate SLVERR probe here); not checked.
    logic [1:0]                bresp_o, rresp_o;
    /* verilator lint_on UNUSEDSIGNAL */
    logic                      arvalid_i, arready_o;
    logic [ADDR_WIDTH-1:0]     araddr_i;
    logic                      rvalid_o, rready_i;
    logic [DATA_WIDTH-1:0]     rdata_o;

    mac_cluster u_dut (
        .clk (clk), .rst_n (rst_n),
        .awvalid_i (awvalid_i), .awready_o (awready_o),
        .awaddr_i (awaddr_i), .awprot_i (awprot_i),
        .wvalid_i (wvalid_i), .wready_o (wready_o),
        .wdata_i (wdata_i), .wstrb_i (wstrb_i),
        .bvalid_o (bvalid_o), .bready_i (bready_i), .bresp_o (bresp_o),
        .arvalid_i (arvalid_i), .arready_o (arready_o),
        .araddr_i (araddr_i), .arprot_i (arprot_i),
        .rvalid_o (rvalid_o), .rready_i (rready_i),
        .rdata_o (rdata_o), .rresp_o (rresp_o)
    );

    initial begin
        $dumpfile("sim_mac_cluster.fst");
        $dumpvars(0, tb_mac_cluster);
    end

    initial begin
        #400_000;
        $error("SIMULATION TIMEOUT");
        $finish;
    end

    // -----------------------------------------------------------------
    // AXI4-Lite manager tasks.
    // -----------------------------------------------------------------
    task automatic axi_write(input [ADDR_WIDTH-1:0] addr, input [31:0] data);
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

    task automatic axi_read(input [ADDR_WIDTH-1:0] addr, output [31:0] data);
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

    // -----------------------------------------------------------------
    // Address map (mac_cluster.sv header comment is the authoritative
    // source): page 0-3 = tiles' own mac_tile_axi CTRL block, page 4 =
    // shared NI-CSR (word offset tile*8+reg).
    // -----------------------------------------------------------------
    function automatic [ADDR_WIDTH-1:0] tile_addr(input int tile, input int offset);
        tile_addr = ADDR_WIDTH'((tile << 8) | offset);
    endfunction

    function automatic [ADDR_WIDTH-1:0] csr_addr(input int tile, input int reg_idx);
        csr_addr = ADDR_WIDTH'((4 << 8) + ((tile * 8 + reg_idx) << 2));
    endfunction

    localparam int TILE_CTRL = 'h00, TILE_STATUS = 'h04;
    localparam int TILE_WEIGHT_ROW0 = 'h08, TILE_WEIGHT_ROW1 = 'h0C,
                    TILE_WEIGHT_ROW2 = 'h10, TILE_WEIGHT_ROW3 = 'h14;
    localparam int NI_CTRL = 0, NI_STATUS = 1, NI_DEST = 2, NI_ENTRY_DATA = 3;
    localparam int NI_EXIT_RESULT0 = 4, NI_EXIT_RESULT1 = 5,
                    NI_EXIT_RESULT2 = 6, NI_EXIT_RESULT3 = 7;
    localparam [31:0] NI_CTRL_ENTRY_PUSH     = 32'h1;
    localparam [31:0] NI_CTRL_TLAST_NEXT     = 32'h2;
    localparam [31:0] NI_CTRL_MESH_EGRESS_EN = 32'h4;
    localparam [31:0] NI_CTRL_EXIT_ACK       = 32'h8;
    // NI_STATUS bit0=ENTRY_BUSY, bit1=EXIT_VALID -- checked via rd_scratch[0]/[1]
    // directly below (bit-select, not a mask-and-compare) to match this
    // repo's own tb_mac_tile_axi.sv convention and avoid a Verilator
    // WIDTHTRUNC warning on an if-condition wider than 1 bit.

    integer errors;
    reg [31:0] rd_scratch;

    task automatic load_tile_weights(input int tile, input [31:0] row0,
                                      input [31:0] row1, input [31:0] row2,
                                      input [31:0] row3);
        begin
            axi_write(tile_addr(tile, TILE_WEIGHT_ROW0), row0);
            axi_write(tile_addr(tile, TILE_WEIGHT_ROW1), row1);
            axi_write(tile_addr(tile, TILE_WEIGHT_ROW2), row2);
            axi_write(tile_addr(tile, TILE_WEIGHT_ROW3), row3);
            axi_write(tile_addr(tile, TILE_CTRL), 32'h1);  // LOAD_WEIGHTS
            for (int i = 0; i < 30; i++) begin
                axi_read(tile_addr(tile, TILE_STATUS), rd_scratch);
                if (rd_scratch[0]) i = 30;
                else @(posedge clk);
            end
            if (!rd_scratch[0]) begin
                $display("TB_MAC_CLUSTER: FAIL -- tile %0d weights never reported loaded", tile);
                errors = errors + 1;
            end
        end
    endtask

    // entry_push_i is edge-pulsed off the NI_CTRL write and latches
    // entry_data_i's value AT THAT MOMENT -- NI_ENTRY_DATA must be written
    // before NI_CTRL's ENTRY_PUSH bit (found the hard way in the cocotb
    // suite's own test-authoring bug; see verification/test_mac_cluster.py
    // ni_push_entry's own comment for the full incident).
    task automatic ni_push_entry(input int tile, input [31:0] act,
                                  input int dest_x, input int dest_y);
        begin
            axi_write(csr_addr(tile, NI_DEST), (dest_y << 1) | dest_x);
            axi_write(csr_addr(tile, NI_ENTRY_DATA), act);
            axi_write(csr_addr(tile, NI_CTRL),
                       NI_CTRL_MESH_EGRESS_EN | NI_CTRL_ENTRY_PUSH | NI_CTRL_TLAST_NEXT);
            for (int i = 0; i < 50; i++) begin
                axi_read(csr_addr(tile, NI_STATUS), rd_scratch);
                if (!rd_scratch[0]) i = 50;  // NI_STATUS_ENTRY_BUSY
                else @(posedge clk);
            end
            if (rd_scratch[0]) begin
                $display("TB_MAC_CLUSTER: FAIL -- tile %0d entry push never completed", tile);
                errors = errors + 1;
            end
        end
    endtask

    // Poll NI_STATUS until EXIT_VALID=1 AND bit3 (EXIT_SEQ) differs from
    // last_seq (pass 0 before a tile's first call, matching exit_seq_q's
    // reset value) -- EXIT_VALID alone is NOT sufficient: exit_valid_q can
    // legitimately go 1(old)->0(exactly one cycle, if a new result is
    // already waiting)->1(new) faster than this TB's multi-cycle AXI read
    // sequence can reliably observe the intermediate 0. Found as a REAL,
    // reproducible race: reading STATUS immediately after issuing an ack
    // can return a stale "still 1" echo of the JUST-consumed result, and
    // proceeding to read RESULT0-3 on that stale trigger can straddle the
    // CSR mirror's advance to the next result mid-read-sequence, returning
    // a torn old/new mix. See REPORT.md and tile_ni.sv's own header
    // comment on exit_seq_q for the full mechanism and trace.
    task automatic ni_poll_and_read_exit(input int tile, input int last_seq,
                                          output [127:0] got, output int seq_out,
                                          output int rejected);
        reg [31:0] r0, r1, r2, r3;
        int seq;
        bit done;
        begin
            rejected = 0;
            done = 0;
            for (int i = 0; i < 200 && !done; i++) begin
                axi_read(csr_addr(tile, NI_STATUS), rd_scratch);
                seq = rd_scratch[3] ? 1 : 0;
                if (rd_scratch[1] && seq != last_seq) begin  // EXIT_VALID && fresh seq
                    done = 1;
                end else begin
                    if (rd_scratch[1]) rejected = rejected + 1;
                    @(posedge clk);
                end
            end
            if (!done) begin
                $display("TB_MAC_CLUSTER: FAIL -- tile %0d exit result never became valid (fresh seq)", tile);
                errors = errors + 1;
                got = 128'hX;
                seq_out = last_seq;
            end else begin
                axi_read(csr_addr(tile, NI_EXIT_RESULT0), r0);
                axi_read(csr_addr(tile, NI_EXIT_RESULT1), r1);
                axi_read(csr_addr(tile, NI_EXIT_RESULT2), r2);
                axi_read(csr_addr(tile, NI_EXIT_RESULT3), r3);
                got = {r3, r2, r1, r0};
                seq_out = seq;
                axi_write(csr_addr(tile, NI_CTRL), NI_CTRL_EXIT_ACK);
            end
        end
    endtask

    reg [127:0] got_a, got_b;
    reg matched_a, matched_b;
    int seq_a, seq_b, rejected_a, rejected_b;

    // Independently computed (Python, not hand-transcribed) from the SAME
    // W0/A0/W1/A1/W3 matrices cocotb's own test_two_producer_chain uses --
    // see that file's header comment for the full activation/weight data
    // and the saturation-coverage rationale.
    localparam [127:0] GOLDEN_Y3A = 128'h00000077FFFFFE9B0000016E0000010E;  // [270, 366, -357, 119]
    localparam [127:0] GOLDEN_Y3B = 128'hFFFFFFA5FFFFFD1F0000025EFFFFFEC3;  // [-317, 606, -737, -91]

    initial begin
        errors = 0;
        awvalid_i = 0; wvalid_i = 0; bready_i = 0;
        arvalid_i = 0; rready_i = 0;

        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // W0 = [[20,5,-3,8],[-15,10,6,-2],[7,-12,15,3],[4,6,-8,11]]
        load_tile_weights(0, 32'h08FD0514, 32'hFE060AF1, 32'h030FF407, 32'h0BF80604);
        // W1 = [[25,-6,4,9],[12,-18,7,-3],[-9,14,-20,5],[6,-8,10,-15]]
        load_tile_weights(1, 32'h0904FA19, 32'hFD07EE0C, 32'h05EC0EF7, 32'hF10AF806);
        // W2_unused = [[1,0,0,1],[0,1,1,0],[1,1,0,0],[0,0,1,1]] -- loaded, never pushed
        load_tile_weights(2, 32'h01000001, 32'h00010100, 32'h00000101, 32'h01010000);
        // W3 = [[2,1,-1,3],[0,-2,4,1],[-1,3,0,-2],[1,0,2,-3]]
        load_tile_weights(3, 32'h03FF0102, 32'h0104FE00, 32'hFE0003FF, 32'hFD020001);

        // Tile 3 stays in its reset-default CPU-exit mode (mesh_egress_en=0).
        ni_push_entry(0, 32'hD83CB064, 1, 1);  // A0=[100,-80,60,-40] -> dest(1,1)
        ni_push_entry(1, 32'h32BA5A9C, 1, 1);  // A1=[-100,90,-70,50] -> dest(1,1)

        ni_poll_and_read_exit(3, 0, got_a, seq_a, rejected_a);
        ni_poll_and_read_exit(3, seq_a, got_b, seq_b, rejected_b);

        $display("TB_MAC_CLUSTER: tile3 exit results (arrival order): 0x%032x, then 0x%032x", got_a, got_b);
        $display("TB_MAC_CLUSTER: exit_seq observed: a=%0d (rejected %0d stale reading(s)), b=%0d (rejected %0d stale reading(s))",
                  seq_a, rejected_a, seq_b, rejected_b);
        if (seq_a == seq_b) begin
            $display("TB_MAC_CLUSTER: MISMATCH -- both exit reads returned the SAME exit_seq value");
            errors = errors + 1;
        end

        matched_a = (got_a === GOLDEN_Y3A) || (got_a === GOLDEN_Y3B);
        matched_b = (got_b === GOLDEN_Y3A) || (got_b === GOLDEN_Y3B);
        if (!matched_a) begin
            $display("TB_MAC_CLUSTER: MISMATCH -- first result matches neither golden value");
            errors = errors + 1;
        end
        if (!matched_b) begin
            $display("TB_MAC_CLUSTER: MISMATCH -- second result matches neither golden value");
            errors = errors + 1;
        end
        if (got_a === got_b) begin
            $display("TB_MAC_CLUSTER: MISMATCH -- both exit results identical, one producer's result never arrived");
            errors = errors + 1;
        end

        if (errors == 0) $display("TB_MAC_CLUSTER: PASS -- all checks matched");
        else begin
            $display("TB_MAC_CLUSTER: FAIL -- %0d error(s)", errors);
            $error("mac_cluster self-check failed");
        end
        $finish;
    end

endmodule
