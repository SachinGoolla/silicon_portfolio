// uart_rx.sv — UART Receiver FSM with 16× oversampling.
//
// Timing from falling edge of start bit:
//   tick 0  : edge detected (in RX_IDLE, baud16_tick fires)
//   tick 8  : mid-start-bit check (noise reject: abort if rx high again)
//   tick 24 : sample bit 0  (8 + 1×16)
//   tick 40 : sample bit 1  (8 + 2×16)  ...
//   tick 152: sample stop bit (8 + 9×16 for 8-bit data, no parity)
//
// rx_push is a single-cycle pulse; the caller must not assert when rx_full.
// Errors are single-cycle pulses; the register file latches and holds them.
module uart_rx #(
    parameter bit PARITY_EN = 1'b0
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       baud16_tick,

    input  logic       rx,            // already 2-FF synchronised by caller
    input  logic       rx_en,
    input  logic       parity_odd,

    input  logic       rx_full,
    output logic       rx_push,
    output logic [7:0] rx_wdata,

    output logic       frame_err,
    output logic       parity_err,
    output logic       ovr_err
);

    typedef enum logic [2:0] {
        RX_IDLE   = 3'd0,
        RX_START  = 3'd1,
        RX_DATA   = 3'd2,
        RX_PARITY = 3'd3,
        RX_STOP   = 3'd4
    } rx_state_t;

    rx_state_t  state;
    logic [7:0] shift_r;
    logic [2:0] bit_cnt;
    logic [3:0] tick_cnt;
    logic       rx_q;
    logic       par_bit;

    assign rx_wdata = shift_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= RX_IDLE;
            shift_r   <= '0;
            bit_cnt   <= '0;
            tick_cnt  <= '0;
            rx_q      <= 1'b1;
            par_bit   <= 1'b0;
            rx_push   <= 1'b0;
            frame_err <= 1'b0;
            parity_err<= 1'b0;
            ovr_err   <= 1'b0;
        end else begin
            // Clear all pulse outputs every cycle; set them below when needed.
            rx_push    <= 1'b0;
            frame_err  <= 1'b0;
            parity_err <= 1'b0;
            ovr_err    <= 1'b0;

            rx_q <= rx;

            if (baud16_tick) begin
                case (state)
                    RX_IDLE: begin
                        // Detect falling edge of start bit.
                        if (rx_en && !rx && rx_q) begin
                            tick_cnt <= '0;
                            state    <= RX_START;
                        end
                    end

                    RX_START: begin
                        // Wait until tick 7 from entry (= tick 8 from falling edge).
                        if (tick_cnt == 4'd7) begin
                            if (!rx) begin
                                // Valid start bit: align to mid-bit.
                                tick_cnt <= '0;
                                bit_cnt  <= '0;
                                state    <= RX_DATA;
                            end else begin
                                // Glitch — abort.
                                state <= RX_IDLE;
                            end
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end

                    RX_DATA: begin
                        // Sample at tick 15 of each bit period (mid-bit).
                        if (tick_cnt == 4'd15) begin
                            shift_r  <= {rx, shift_r[7:1]};  // LSB-first shift
                            tick_cnt <= '0;
                            if (bit_cnt == 3'd7) begin
                                bit_cnt <= '0;
                                state   <= PARITY_EN ? RX_PARITY : RX_STOP;
                            end else bit_cnt <= bit_cnt + 1'b1;
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end

                    RX_PARITY: begin
                        if (tick_cnt == 4'd15) begin
                            par_bit  <= rx;
                            tick_cnt <= '0;
                            state    <= RX_STOP;
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end

                    RX_STOP: begin
                        if (tick_cnt == 4'd15) begin
                            tick_cnt <= '0;
                            state    <= RX_IDLE;
                            if (!rx) begin
                                // Stop bit must be 1; framing error.
                                frame_err <= 1'b1;
                            end else if (PARITY_EN &&
                                         (par_bit != (parity_odd ? ~^shift_r : ^shift_r))) begin
                                parity_err <= 1'b1;
                            end else if (rx_full) begin
                                // Frame valid but no room — overrun.
                                ovr_err <= 1'b1;
                            end else begin
                                rx_push <= 1'b1;
                            end
                        end else tick_cnt <= tick_cnt + 1'b1;
                    end

                    default: state <= RX_IDLE;
                endcase
            end
        end
    end

endmodule
