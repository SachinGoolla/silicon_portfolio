// uart_fifo.sv — Synchronous FIFO for UART TX/RX buffering.
// Standard write-first style: push_data visible immediately on pop_data
// when wr and rd pointers coincide (full-speed pipelining not needed here;
// clarity and formal-provability are the priority).
//
// DEPTH must be a power-of-2.  The extra pointer bit (PTR_W+1) distinguishes
// full from empty without a separate counter.
module uart_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst_n,

    input  logic             push_en,
    input  logic [WIDTH-1:0] push_data,
    output logic             full,

    input  logic             pop_en,
    output logic [WIDTH-1:0] pop_data,
    output logic             empty
);

    localparam int PTR_W = $clog2(DEPTH);

    logic [WIDTH-1:0] mem [DEPTH];
    logic [PTR_W:0]   wr_ptr, rd_ptr;

    // Extra MSB distinguishes full (pointers equal except MSB) from empty (equal).
    assign full  = (wr_ptr[PTR_W] != rd_ptr[PTR_W]) &&
                   (wr_ptr[PTR_W-1:0] == rd_ptr[PTR_W-1:0]);
    assign empty = (wr_ptr == rd_ptr);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (push_en && !full)  wr_ptr <= wr_ptr + 1'b1;
            if (pop_en  && !empty) rd_ptr <= rd_ptr + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (push_en && !full)
            mem[wr_ptr[PTR_W-1:0]] <= push_data;
    end

    // Combinatorial read — head element always visible without pop.
    assign pop_data = mem[rd_ptr[PTR_W-1:0]];

endmodule
