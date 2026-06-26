module mod1000(
    input logic clk,
    input logic rst_n,
    output logic [9:0] count
);
    // ==========================================
    // 3GHz Ultra-Fast Architecture: Fractional Pipelined Counter
    // ==========================================
    // We break the 10-bit counter into two 5-bit counters and pipeline 
    // the carry and terminal reset conditions. 
    // Logic depth is mathematically bound to a maximum of 3 gates, entirely bypassing ABC's tendency to create deep networks!
    
    logic [4:0] count_low;
    logic [4:0] count_high;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [4:0] count_low_n; // Inverted registers to kill INV delays
    /* verilator lint_on UNUSEDSIGNAL */
    assign count = {count_high, count_low};

    logic carry_to_high_q;
    logic will_be_999_q;
    logic high_is_31_q;

    // Fast 5-bit incrementers
    logic [4:0] inc_low;
    logic l_and3;
    assign l_and3 = count_low[2] & count_low[1] & count_low[0];
    assign inc_low[0] = ~count_low[0];
    assign inc_low[1] = count_low[1] ^ count_low[0];
    assign inc_low[2] = count_low[2] ^ (count_low[1] & count_low[0]);
    assign inc_low[3] = count_low[3] ^ l_and3;
    assign inc_low[4] = count_low[4] ^ (l_and3 & count_low[3]);

    logic [4:0] inc_high;
    logic h_and3;
    assign h_and3 = count_high[2] & count_high[1] & count_high[0];
    assign inc_high[0] = count_high[0] ^ carry_to_high_q;
    assign inc_high[1] = count_high[1] ^ (count_high[0] & carry_to_high_q);
    assign inc_high[2] = count_high[2] ^ (count_high[1] & count_high[0] & carry_to_high_q);
    assign inc_high[3] = count_high[3] ^ (h_and3 & carry_to_high_q);
    assign inc_high[4] = count_high[4] ^ (h_and3 & carry_to_high_q & count_high[3]);
    
    // Fast Comparators
    logic high_is_31;
    assign high_is_31 = count_high[4] & count_high[3] & count_high[2] & count_high[1] & count_high[0];

    // 998 is High=31, Low=6. Low=6 is 00110 -> n4, n3, 2, 1, n0
    // Pipelining high_is_31 removes a massive 5-input AND from the critical path
    logic is_998_p1, is_998_p2, is_998;
    assign is_998_p1 = high_is_31_q & count_low_n[4] & count_low_n[3];
    assign is_998_p2 = count_low[2] & count_low[1] & count_low_n[0];
    assign is_998    = is_998_p1 & is_998_p2;

    // low_is_30 logic split to enforce 2-level mapping
    logic low_is_30_p1, low_is_30_p2, low_is_30;
    assign low_is_30_p1 = count_low[4] & count_low[3];
    assign low_is_30_p2 = count_low[2] & count_low[1] & count_low_n[0];
    assign low_is_30    = low_is_30_p1 & low_is_30_p2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_low       <= 5'b0;
            count_low_n     <= 5'b11111;
            count_high      <= 5'b0;
            carry_to_high_q <= 1'b0;
            will_be_999_q <= 1'b0;
            high_is_31_q  <= 1'b0;
        end else begin
            // Evaluate pipelined conditions on current state
            carry_to_high_q <= low_is_30;
            will_be_999_q   <= is_998;
            high_is_31_q    <= will_be_999_q ? 1'b0 : high_is_31;
            
            // State updates using explicit MUX decoupling
            count_low   <= will_be_999_q ? 5'd0 : inc_low;
            count_low_n <= will_be_999_q ? 5'b11111 : ~inc_low;
            count_high <= will_be_999_q ? 5'd0 : inc_high;
        end
    end

//with formal verification, we can add assertions to ensure the counter behaves as expected:
`ifdef FORMAL
    logic f_was_reset;
    initial f_was_reset = 0;

    // Track if a reset has ever occurred since power-on
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) f_was_reset <= 1'b1;
    end

    always_comb begin
        if (f_was_reset) begin
            assert(count <= 10'd999);
            // Bind pipelined shadow registers to count — required for k-induction to converge
            assert(will_be_999_q == (count == 10'd999));
            assert(carry_to_high_q == (count_low == 5'd31));
            assert(count_low_n == ~count_low);
            assert(high_is_31_q == ((count_high == 5'd31) && (count_low != 5'd0)));
        end
    end

    always_comb begin
        cover(count == 10'd0);
        cover(count == 10'd999);
    end
`endif
endmodule       
