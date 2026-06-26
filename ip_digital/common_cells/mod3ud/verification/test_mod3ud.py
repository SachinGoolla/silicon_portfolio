"""cocotb tests for mod3ud — 3-bit up/down counter with F7/S7 states.

Set TEST_SEED env var to replay a specific random run: TEST_SEED=42 make sim

State machine: UP(cnt 0→6) → F7(cnt=7) → S7(cnt=6) → DOWN(cnt 6→1) → UP ...
Expected cnt sequence after reset: 0,1,2,3,4,5,6,7,7,6,5,4,3,2,1,0,1,2,...
Period = 15 clock cycles.
"""
import os
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def reset_dut(dut):
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_reset(dut):
    """Counter holds 0 during reset (wait one edge first so regs are initialized)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    await RisingEdge(dut.clk)  # first edge clears X — cnt becomes 0
    for _ in range(3):
        await RisingEdge(dut.clk)
        assert dut.cnt.value == 0, f"Expected cnt=0 during reset, got {dut.cnt.value}"
    dut.rst.value = 0


@cocotb.test()
async def test_count_sequence(dut):
    """Verify the full 15-cycle up/down sequence after reset."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    # Expected sequence: one full period starting from cnt=0
    # Clock by clock after de-assert of rst:
    # State=UP:  cnt increments each cycle
    # State=F7:  cnt forced to 7
    # State=S7:  cnt forced to 6
    # State=DOWN: cnt decrements each cycle until cnt==1 → back to UP
    expected = [1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1, 0]
    for i, exp in enumerate(expected):
        await RisingEdge(dut.clk)
        got = int(dut.cnt.value)
        assert got == exp, f"Cycle {i+1}: expected cnt={exp}, got {got}"


@cocotb.test()
async def test_max_value(dut):
    """Counter never exceeds 7 (3-bit bound) over two full periods."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    for _ in range(30):
        await RisingEdge(dut.clk)
        assert int(dut.cnt.value) <= 7, f"cnt exceeded 7: {dut.cnt.value}"


@cocotb.test()
async def test_periodic(dut):
    """Sequence repeats exactly every 15 cycles after warm-up."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Capture one full period
    period = 15
    first = []
    for _ in range(period):
        await RisingEdge(dut.clk)
        first.append(int(dut.cnt.value))
    second = []
    for _ in range(period):
        await RisingEdge(dut.clk)
        second.append(int(dut.cnt.value))
    assert first == second, f"Sequence not periodic:\n  period1={first}\n  period2={second}"


class Mod3UDModel:
    """Cycle-accurate Python reference model for mod3ud.
    Mirrors the RTL state machine exactly so the scoreboard can detect
    any divergence between RTL and the architectural spec.
    """
    UP, DOWN, F7, S7 = 0, 1, 2, 3

    def __init__(self):
        self.cnt   = 0
        self.state = self.UP

    def reset(self):
        self.cnt   = 0
        self.state = self.UP

    def tick(self, rst: int) -> int:
        """Advance one clock cycle. Returns cnt after the rising edge.
        Both always blocks in the RTL evaluate with the SAME (pre-edge) state and cnt,
        so we capture old_state before updating state, then apply cnt update with old_state.
        """
        if rst:
            self.reset()
            return self.cnt
        old_state = self.state
        old_cnt   = self.cnt
        # State transition (mirrors first always block)
        if   old_state == self.DOWN: self.state = self.UP   if old_cnt == 1 else self.DOWN
        elif old_state == self.F7:   self.state = self.S7
        elif old_state == self.S7:   self.state = self.DOWN
        elif old_state == self.UP:   self.state = self.F7   if old_cnt == 6 else self.UP
        # Counter update using OLD state (mirrors second always block)
        if   old_state == self.UP:   self.cnt = (old_cnt + 1) & 0x7
        elif old_state == self.DOWN: self.cnt = (old_cnt - 1) & 0x7
        elif old_state == self.F7:   self.cnt = 7
        elif old_state == self.S7:   self.cnt = 6
        return self.cnt


@cocotb.test()
async def test_scoreboard(dut):
    """Cycle-accurate scoreboard: DUT output must match Python reference model
    on every clock edge for 5 complete periods (75 cycles). Any mismatch means
    the RTL diverged from the architectural specification."""
    model = Mod3UDModel()
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    # Apply reset — drive DUT and tick model in lockstep through every edge.
    # cocotb returns from await RisingEdge at Δ1 (before NBAs commit), so
    # dut.cnt.value shows what the PREVIOUS edge committed.
    # The model must be one tick AHEAD of what the DUT will show,
    # so we compare model.cnt (pre-tick) with dut.cnt.value (pre-edge).
    dut.rst.value = 1
    model.tick(rst=1)            # edge 1 committed by DUT
    await RisingEdge(dut.clk)
    model.tick(rst=1)            # edge 2 committed by DUT
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    model.tick(rst=0)            # edge 3 committed by DUT (first active edge: cnt→1)
    await RisingEdge(dut.clk)   # DUT shows pre-edge-3 = 0; model.cnt = 1

    mismatches = []
    for cycle in range(75):
        await RisingEdge(dut.clk)          # DUT shows pre-edge value (prev committed)
        dut_cnt = int(dut.cnt.value)        # = what model.cnt was before this iteration's tick
        ref_cnt = model.cnt                 # pre-tick = what DUT should show
        model.tick(rst=0)                   # advance model for next comparison
        if dut_cnt != ref_cnt:
            mismatches.append(f"  cycle {cycle+1}: DUT={dut_cnt} REF={ref_cnt}")
        if len(mismatches) >= 5:
            break  # first 5 mismatches tell the story

    assert not mismatches, (
        f"Scoreboard: {len(mismatches)} divergence(s) from reference model:\n"
        + "\n".join(mismatches)
    )


@cocotb.test()
async def test_random_reset_stimulus(dut):
    """Randomized reset assertion/de-assertion: cnt must be 0 whenever rst=1.

    Seed from TEST_SEED env var for reproducible replay; printed on failure.
    """
    seed = int(os.environ.get("TEST_SEED", 0)) or random.randint(1, 0xFFFF_FFFF)
    rng = random.Random(seed)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.rst.value = 1
    await RisingEdge(dut.clk)

    for cycle in range(200):
        # Randomly assert/de-assert reset with 20% probability each cycle
        if rng.random() < 0.20:
            dut.rst.value = 1
        elif rng.random() < 0.30:
            dut.rst.value = 0
        await RisingEdge(dut.clk)
        if dut.rst.value == 1:
            assert int(dut.cnt.value) == 0, (
                f"cnt={dut.cnt.value} during reset at cycle {cycle} "
                f"(TEST_SEED={seed} to reproduce)"
            )
