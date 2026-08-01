// uart_tx.sv — UART Transmitter FSM.
// Emits: 1 start bit (0) + 8 data bits (LSB first) + optional even parity + 1 stop bit (1).
// Advances one bit every 16 baud16_tick pulses.
// tx_pop is gated by baud16_tick so the FIFO pointer advances exactly once per byte.
module uart_tx #(
    parameter bit PARITY_EN = 1'b0
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       baud16_tick,

    input  logic       tx_empty,
    output logic       tx_pop,        // single-cycle pop (baud16_tick gated)
    input  logic [7:0] tx_rdata,

    input  logic       tx_en,
    input  logic       parity_odd,    // 0=even, 1=odd

    output logic       tx            // serial output, idles high
);

    typedef enum logic [2:0] {
        TX_IDLE   = 3'd0,
        TX_START  = 3'd1,
        TX_DATA   = 3'd2,
        TX_PARITY = 3'd3,
        TX_STOP   = 3'd4
    } tx_state_t;

    tx_state_t   state;
    logic [7:0]  shift_r;
    logic [2:0]  bit_cnt;
    logic [3:0]  tick_cnt;
    logic        par_bit;

    // Pop fires for exactly one clock (baud16_tick is one cycle wide).
    assign tx_pop = (state == TX_IDLE) && baud16_tick && !tx_empty && tx_en;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= TX_IDLE;
            tx       <= 1'b1;
            shift_r  <= '0;
            bit_cnt  <= '0;
            tick_cnt <= '0;
            par_bit  <= 1'b0;
        end else if (baud16_tick) begin
            case (state)
                TX_IDLE: begin
                    tx <= 1'b1;
                    if (!tx_empty && tx_en) begin
                        shift_r  <= tx_rdata;
                        par_bit  <= parity_odd ? ~^tx_rdata : ^tx_rdata;
                        tick_cnt <= '0;
                        bit_cnt  <= '0;
                        state    <= TX_START;
                    end
                end

                TX_START: begin
                    tx <= 1'b0;
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= '0;
                        state    <= TX_DATA;
                    end else tick_cnt <= tick_cnt + 1'b1;
                end

                TX_DATA: begin
                    tx <= shift_r[0];
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= '0;
                        shift_r  <= shift_r >> 1;
                        if (bit_cnt == 3'd7) begin
                            bit_cnt <= '0;
                            state   <= PARITY_EN ? TX_PARITY : TX_STOP;
                        end else bit_cnt <= bit_cnt + 1'b1;
                    end else tick_cnt <= tick_cnt + 1'b1;
                end

                TX_PARITY: begin
                    tx <= par_bit;
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= '0;
                        state    <= TX_STOP;
                    end else tick_cnt <= tick_cnt + 1'b1;
                end

                TX_STOP: begin
                    tx <= 1'b1;
                    if (tick_cnt == 4'd15) begin
                        tick_cnt <= '0;
                        state    <= TX_IDLE;
                    end else tick_cnt <= tick_cnt + 1'b1;
                end

                default: state <= TX_IDLE;
            endcase
        end
    end

endmodule
