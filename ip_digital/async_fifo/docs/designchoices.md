# async_fifo Design Choices

## Architecture: Clifford Cummings 2002 gray-code FIFO

**Why gray code?** Only one bit changes per pointer increment. This is the foundational CDC safety property: when the receiving domain samples during a transition, it captures either the old or new value — never a spurious intermediate that would corrupt the empty/full logic.

**Why PTR_W = ADDR_W + 1?** The extra MSB distinguishes full from empty. When wr_bin == rd_bin with identical MSBs → empty. When they wrap around and differ only in the top two bits → full. Without the extra bit, a FIFO with N entries (wr==rd in the lower bits) cannot tell full from empty.

**Why compare top two gray-coded bits (inverted)?** The gray code wraps MSB at count=2^ADDR_W. When full, wr_gray has its top two bits inverted relative to rd_gray — the only way to have wr_bin exactly DEPTH ahead of rd_bin in the gray-coded space. This is the Cummings Fig 6 full-detection formula.

## Parameter choices

- **DATA_W = 32**: matches the fpu_top writeback bus (result[31:0]).
- **DEPTH = 8**: minimum useful depth for 3:1 clock ratio (wr at 100 MHz, rd at 33 MHz). A 3× writer needs at least 3 entries of buffering per burst; 8 gives headroom without excessive area.
- **SYNC_STAGES = 2**: standard two-flop synchroniser. MTBF >> 10 years at these clock rates on sky130. Three stages would reduce the throughput window by one extra cycle but are unnecessary at 100 MHz for TSMC 180 nm class PDKs.

## Reset: asynchronous, active-low

Both domains have independent active-low resets (wr_rst_n, rd_rst_n). Asynchronous reset is used so the FIFO comes to a known state regardless of clock activity — critical when bringing up the system before clocks are stable.

On wr_rst_n=0: wr_bin, wr_gray, rg2wr[] all cleared.
On rd_rst_n=0: rd_bin, rd_gray, wg2rd[], rd_data all cleared.

Both reset signals should be asserted together during power-on to avoid false full/empty conditions from asymmetric reset sequencing.

## Memory: distributed (unpacked array)

`logic [DATA_W-1:0] mem[0:DEPTH-1]` synthesizes to flip-flop arrays on sky130 (no SRAM macro). For DEPTH=8, DATA_W=32: 256 FFs. For a portfolio IP, this is acceptable; production designs would use a dual-port SRAM macro with proper timing constraints. The `(* keep *)` attribute prevents Yosys from merging or optimizing mem[] FFs.

## rd_data: registered output

rd_data is registered (loaded on posedge rd_clk when rd_en && !empty). This adds one read latency cycle but:
1. Eliminates combinational glitches on rd_data (clean for downstream logic).
2. Required for the read monitor's timing: rd_data is valid the cycle AFTER rd_en.
3. Consistent with standard SRAM timing models.

## full/empty: conservative by design

The synchronised pointers (wg2rd, rg2wr) are always ≤ SYNC_STAGES cycles stale. This means:
- empty may remain asserted for up to 2 extra rd_clk cycles after a write.
- full may remain asserted for up to 2 extra wr_clk cycles after a read.

This is the standard safe design choice. The alternative (Hobson's correction, etc.) adds complexity without significant benefit at DEPTH=8.

## `(* keep *)` on synchroniser arrays

Prevents Yosys from merging wg2rd[0] with wg2rd[1] (they look identical to the optimizer). Without this, the optimiser could reduce SYNC_STAGES from 2 to 1, destroying the metastability protection. The attribute is carried through to the synthesis netlist (P6) and visible to OpenCDC (P1) for structural CDC analysis.

## Formal properties design

Four assert properties target the safety invariants directly:
- `WR_GRAY_VALID`, `RD_GRAY_VALID`: pointer consistency (prevents informal bugs in b2g function).
- `OCCUPANCY_SAFE`: wr_bin never more than DEPTH ahead of the stale rd pointer.
- `FULL_STOPS_WR`, `EMPTY_STOPS_RD`: the handshake invariants (safety: no overflow/underflow).

Two cover properties verify liveness (solver reaches full/drain from empty).

Multi-clock formal with SymbiYosys SBY v0.64: properties use `@(posedge wr_clk)` and `@(posedge rd_clk)` explicitly. SBY's smtbmc z3 engine handles asynchronous multi-clock designs by exploring all possible interleavings.

## Lint: memory cross-domain warnings

Verilator 5.036 produces `MULTIDRIVEN` advisory warnings on `mem[]` (written on wr_clk, read on rd_clk). These are structural lint warnings, not functional errors — the pointer discipline guarantees no simultaneous wr+rd to the same address. They are left advisory-only and documented here.
