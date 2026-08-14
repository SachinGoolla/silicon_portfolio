// mac_tile_axi.sv — AXI4-Lite + AXI4-Stream peripheral wrapping a 4x4
// weight-stationary int8 systolic MAC array.
//
// Composition:
//   axi_lite_slave    — AXI4-Lite protocol engine + control/status regfile
//   axi4stream_ctrl    — glue FSM + systolic_array_4x4 + axis_skid
//   this module        — register map decode + CTRL/DATA_IN write-pulse
//                         sequencing, matching fpu_axi_periph.sv's own
//                         ctrl_we_q pattern
//
// Register map (word-addressed, DATA_WIDTH=32, NUM_REGS=16)
//   0x00 CTRL        [0]=LOAD_WEIGHTS [1]=TLAST_NEXT [2]=INPUT_SRC_MMIO
//                     [3]=RESULT_ACK
//   0x04 STATUS      [0]=WEIGHTS_LOADED [1]=BUSY [2]=RESULT_VALID
//                     [3]=RESULT_LAST [4]=INPUT_BUSY      — HW-write-only
//   0x08 WEIGHT_ROW0 4 packed int8 (row 0's stationary weights)
//   0x0C WEIGHT_ROW1
//   0x10 WEIGHT_ROW2
//   0x14 WEIGHT_ROW3
//   0x18 DATA_IN     4 packed int8 (one activation vector, MMIO push)
//   0x1C RESULT0     int32                                — HW-write-only
//   0x20 RESULT1
//   0x24 RESULT2
//   0x28 RESULT3
//   0x2C-0x3C reserved
//
// INPUT_SRC_MMIO is a plain persisted config bit (read directly out of the
// regfile, no HW override) -- set once before streaming begins and held for
// the whole session; selects the external s_axis port vs. the DATA_IN/
// RESULT0-3 MMIO bridge (see axi4stream_ctrl.sv, mutually exclusive by
// construction). LOAD_WEIGHTS and the DATA_IN write are both edge-detected
// one cycle after their commit (ctrl_we_q/data_in_we_q), the same pattern
// fpu_axi_periph.sv's own CTRL write already established, so the regfile
// already reflects the just-committed value when consumed. TLAST_NEXT is
// sticky from the CTRL write that armed it until the DATA_IN write it tags
// consumes it.
//
// RESULT_ACK exists because a new DATA_IN push CANNOT implicitly clear the
// prior MMIO result on its own: mmio_data_in_ready_o is gated on the prior
// result having already been cleared (one-vector-in-flight on the MMIO
// path), so waiting for "the next push" to clear it is a same-cycle
// chicken-and-egg deadlock -- confirmed as a real bug during Phase 2 SoC
// integration (an adversarial review caught it: axi4stream_ctrl.sv's
// original design relied on mmio_accept to clear mmio_result_valid_q, but
// mmio_accept itself requires mmio_data_in_ready_o, which requires
// mmio_result_valid_q already cleared -- the MMIO bridge could accept
// exactly one push, ever, and permanently hang on any second operation).
// Same "axi_lite_slave has no read-side-effect mechanism, so consume is an
// explicit write" pattern as uart_axi_periph's own CTRL.RX_POP.
`timescale 1ns/1ps

module mac_tile_axi #(
    parameter int DATA_WIDTH = 32,
    parameter int ADDR_WIDTH = 8,
    parameter int K          = 4,
    parameter int N          = 4,
    parameter int LATENCY    = 1,
    parameter int ACT_W      = 8,
    parameter int PSUM_W     = 32
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // --- AXI4-Lite control/status port ---
    input  logic                      awvalid_i,
    output logic                      awready_o,
    input  logic [ADDR_WIDTH-1:0]     awaddr_i,
    input  logic [2:0]                awprot_i,

    input  logic                      wvalid_i,
    output logic                      wready_o,
    input  logic [DATA_WIDTH-1:0]     wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0] wstrb_i,

    output logic                      bvalid_o,
    input  logic                      bready_i,
    output logic [1:0]                bresp_o,

    input  logic                      arvalid_i,
    output logic                      arready_o,
    input  logic [ADDR_WIDTH-1:0]     araddr_i,
    input  logic [2:0]                arprot_i,

    output logic                      rvalid_o,
    input  logic                      rready_i,
    output logic [DATA_WIDTH-1:0]     rdata_o,
    output logic [1:0]                rresp_o,

    // --- AXI4-Stream data ports ---
    input  logic                 s_axis_tvalid_i,
    output logic                 s_axis_tready_o,
    input  logic [K*ACT_W-1:0]   s_axis_tdata_i,
    input  logic                 s_axis_tlast_i,

    output logic                 m_axis_tvalid_o,
    input  logic                 m_axis_tready_i,
    output logic [N*PSUM_W-1:0]  m_axis_tdata_o,
    output logic                 m_axis_tlast_o
);

    localparam int NUM_REGS       = 16;
    localparam int IDX_CTRL       = 0;
    localparam int IDX_STATUS     = 1;
    localparam int IDX_WEIGHT_ROW0 = 2;
    localparam int IDX_WEIGHT_ROW1 = 3;
    localparam int IDX_WEIGHT_ROW2 = 4;
    localparam int IDX_WEIGHT_ROW3 = 5;
    localparam int IDX_DATA_IN    = 6;
    localparam int IDX_RESULT0    = 7;
    localparam int IDX_RESULT1    = 8;
    localparam int IDX_RESULT2    = 9;
    localparam int IDX_RESULT3    = 10;

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

    // Registered write-commit pulses -- regfile already reflects the new
    // value on the cycle each is consumed (fpu_axi_periph.sv's own
    // ctrl_we_q pattern, applied to both CTRL and DATA_IN here).
    logic ctrl_we_q, data_in_we_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_we_q    <= 1'b0;
            data_in_we_q <= 1'b0;
        end else begin
            ctrl_we_q    <= reg_we[IDX_CTRL];
            data_in_we_q <= reg_we[IDX_DATA_IN];
        end
    end

    wire load_weights_pulse = ctrl_we_q && regfile[IDX_CTRL*DATA_WIDTH+0];
    wire input_src_mmio     = regfile[IDX_CTRL*DATA_WIDTH+2];  // plain persisted config bit
    wire result_ack_pulse   = ctrl_we_q && regfile[IDX_CTRL*DATA_WIDTH+3];

    // TLAST_NEXT: sticky from the CTRL write that armed it until the
    // DATA_IN write it tags consumes it.
    logic tlast_next_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tlast_next_q <= 1'b0;
        end else if (ctrl_we_q && regfile[IDX_CTRL*DATA_WIDTH+1]) begin
            tlast_next_q <= 1'b1;
        end else if (data_in_we_q) begin
            tlast_next_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------
    // axi4stream_ctrl + the array itself
    // -----------------------------------------------------------------
    logic weights_loaded, busy;
    logic mmio_data_in_ready, mmio_result_valid, mmio_result_last;
    logic [N*PSUM_W-1:0] mmio_result_data;

    axi4stream_ctrl #(
        .K       (K),
        .N       (N),
        .LATENCY (LATENCY),
        .ACT_W   (ACT_W),
        .PSUM_W  (PSUM_W)
    ) u_ctrl (
        .clk                   (clk),
        .rst_n                 (rst_n),

        .s_axis_tvalid_i       (s_axis_tvalid_i),
        .s_axis_tready_o       (s_axis_tready_o),
        .s_axis_tdata_i        (s_axis_tdata_i),
        .s_axis_tlast_i        (s_axis_tlast_i),

        .m_axis_tvalid_o       (m_axis_tvalid_o),
        .m_axis_tready_i       (m_axis_tready_i),
        .m_axis_tdata_o        (m_axis_tdata_o),
        .m_axis_tlast_o        (m_axis_tlast_o),

        .mmio_data_in_valid_i  (data_in_we_q),
        .mmio_data_in_ready_o  (mmio_data_in_ready),
        .mmio_data_in_i        (regfile[IDX_DATA_IN*DATA_WIDTH +: K*ACT_W]),
        .mmio_tlast_next_i     (tlast_next_q),
        .mmio_result_ack_i     (result_ack_pulse),

        .mmio_result_valid_o   (mmio_result_valid),
        .mmio_result_data_o    (mmio_result_data),
        .mmio_result_last_o    (mmio_result_last),

        .input_src_mmio_i      (input_src_mmio),

        .weight_i              ({regfile[IDX_WEIGHT_ROW3*DATA_WIDTH +: K*ACT_W],
                                  regfile[IDX_WEIGHT_ROW2*DATA_WIDTH +: K*ACT_W],
                                  regfile[IDX_WEIGHT_ROW1*DATA_WIDTH +: K*ACT_W],
                                  regfile[IDX_WEIGHT_ROW0*DATA_WIDTH +: K*ACT_W]}),
        .weight_we_i            (load_weights_pulse),
        .weights_loaded_o       (weights_loaded),

        .busy_o                 (busy)
    );

    // -----------------------------------------------------------------
    // HW-write-only status/result registers.
    // -----------------------------------------------------------------
    always_comb begin
        hw_we    = '0;
        hw_wdata = '0;

        hw_we[IDX_STATUS] = 1'b1;
        hw_wdata[IDX_STATUS*DATA_WIDTH +: DATA_WIDTH] = {
            {(DATA_WIDTH-5){1'b0}},
            input_src_mmio && !mmio_data_in_ready,   // [4] INPUT_BUSY (0 when not in MMIO mode)
            mmio_result_last,      // [3] RESULT_LAST
            mmio_result_valid,     // [2] RESULT_VALID
            busy,                  // [1] BUSY
            weights_loaded         // [0] WEIGHTS_LOADED
        };

        if (mmio_result_valid) begin
            hw_we[IDX_RESULT0] = 1'b1;
            hw_wdata[IDX_RESULT0*DATA_WIDTH +: DATA_WIDTH] = mmio_result_data[0*PSUM_W +: PSUM_W];
            hw_we[IDX_RESULT1] = 1'b1;
            hw_wdata[IDX_RESULT1*DATA_WIDTH +: DATA_WIDTH] = mmio_result_data[1*PSUM_W +: PSUM_W];
            hw_we[IDX_RESULT2] = 1'b1;
            hw_wdata[IDX_RESULT2*DATA_WIDTH +: DATA_WIDTH] = mmio_result_data[2*PSUM_W +: PSUM_W];
            hw_we[IDX_RESULT3] = 1'b1;
            hw_wdata[IDX_RESULT3*DATA_WIDTH +: DATA_WIDTH] = mmio_result_data[3*PSUM_W +: PSUM_W];
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // regfile[CTRL upper bits, STATUS/RESULT0-3 snapshot] -- HW-write-only
    // regs are read back over AXI, never through this net; CTRL bits [3:0]
    // are all consumed elsewhere (LOAD_WEIGHTS/TLAST_NEXT/INPUT_SRC_MMIO/
    // RESULT_ACK) -- only bits [31:4] remain reserved.
    logic _unused;
    assign _unused = ^{awprot_i, arprot_i,
                        regfile[IDX_CTRL*DATA_WIDTH+DATA_WIDTH-1:IDX_CTRL*DATA_WIDTH+4],
                        regfile[IDX_STATUS*DATA_WIDTH +: DATA_WIDTH],
                        regfile[IDX_RESULT0*DATA_WIDTH +: DATA_WIDTH],
                        regfile[IDX_RESULT1*DATA_WIDTH +: DATA_WIDTH],
                        regfile[IDX_RESULT2*DATA_WIDTH +: DATA_WIDTH],
                        regfile[IDX_RESULT3*DATA_WIDTH +: DATA_WIDTH]};
    /* verilator lint_on UNUSEDSIGNAL */

`ifdef FORMAL
    initial assume(!rst_n);

    // Non-tautological register-decode properties: literal offset
    // constants, not this file's own IDX_* localparams (same fix pattern
    // rv32i_addr_decoder.sv:454-488 already established -- a property that
    // only re-reads the RTL's own named constant would stay true even if
    // that constant itself were wrong).
    always_comb begin
        if (rst_n && load_weights_pulse) assert(ctrl_we_q && regfile[0*DATA_WIDTH+0]);
    end

    // STATUS is always written every cycle (a continuous HW mirror, not
    // an edge-pulsed register) -- matches RXDATA/STATUS's own continuous-
    // mirror discipline from uart_axi_periph.sv.
    always_comb begin
        if (rst_n) assert(hw_we[1]);  // IDX_STATUS == 1
    end

    // RESULT0-3 are only ever written together, and only when a real MMIO
    // result actually drained.
    always_comb begin
        if (rst_n) begin
            assert(hw_we[7] == hw_we[8]);   // IDX_RESULT0 == IDX_RESULT1
            assert(hw_we[8] == hw_we[9]);   // IDX_RESULT1 == IDX_RESULT2
            assert(hw_we[9] == hw_we[10]);  // IDX_RESULT2 == IDX_RESULT3
            if (hw_we[7]) assert(mmio_result_valid);
        end
    end

    always_comb begin
        cover(rst_n && load_weights_pulse);
        cover(rst_n && data_in_we_q);
        cover(rst_n && mmio_result_valid && hw_we[7]);
        cover(rst_n && input_src_mmio);
        cover(rst_n && !input_src_mmio);
        cover(rst_n && result_ack_pulse);
    end
`endif

endmodule
