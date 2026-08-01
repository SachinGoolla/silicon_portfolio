// uart_baud.sv — Baud-rate 16× tick generator.
// Counts 0..brdiv and emits a single-cycle baud16_tick when it wraps.
// brdiv = CLK_FREQ / (BAUD_RATE × 16) − 1  (runtime-programmable via BRDIV reg).
// TX uses every 16th tick (bit period = 16 × baud16_tick intervals).
// RX uses individual ticks for oversampling.
module uart_baud (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [15:0] brdiv,
    output logic        baud16_tick
);

    logic [15:0] cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt         <= '0;
            baud16_tick <= 1'b0;
        end else if (cnt == brdiv) begin
            cnt         <= '0;
            baud16_tick <= 1'b1;
        end else begin
            cnt         <= cnt + 1'b1;
            baud16_tick <= 1'b0;
        end
    end

endmodule
