"""
test_rr_arbiter.py  --  Cocotb Functional Tests for rr_arbiter (Pillar 3)
=========================================================================

DESIGN UNDER TEST:
  rr_arbiter -- N-way burst-aware masked round-robin arbiter
  N_REQ=4, matching fpu_top's four functional units (NONCOMP/CVT/FMA/DIVSQRT).

REFERENCE MODEL:
  RRArbiterRef mirrors the RTL state machine exactly.
  burst_hold is purely combinational (no stored flag) -- same as RTL.

TIMING NOTE:
  grant_o is registered.  We call ReadOnly() after every RisingEdge() to
  ensure nonblocking assignments (NBA) have settled before sampling outputs.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ReadOnly


N_REQ = 4


# =============================================================================
# Reference model
# =============================================================================

class RRArbiterRef:
    def __init__(self, n=N_REQ):
        self.n     = n
        self.pp    = 1   # one-hot: starts at req 0
        self.grant = 0

    def _lsb(self, v):
        return v & (-v) if v else 0

    def step(self, req, mask, burst_lock, last):
        n_mask     = (1 << self.n) - 1
        active     = req & ~mask & n_mask
        prio_mask  = (~(self.pp - 1)) & n_mask
        masked_req = active & prio_mask
        next_g     = self._lsb(masked_req) if masked_req else self._lsb(active)

        burst_hold = bool(burst_lock) and bool(self.grant) and not bool(last)

        if burst_hold:
            pass
        elif active:
            self.grant = next_g
            self.pp = 1 << ((self.grant.bit_length()) % self.n)
        else:
            self.grant = 0
        return self.grant


# =============================================================================
# Helpers
# =============================================================================

async def tick(dut):
    await RisingEdge(dut.clk)
    await ReadOnly()


async def reset_dut(dut, cycles=3):
    dut.rst_n.value        = 0
    dut.req_i.value        = 0
    dut.mask_i.value       = 0
    dut.burst_lock_i.value = 0
    dut.last_i.value       = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def onehot0(v, n, label):
    mask = (1 << n) - 1
    x = int(v) & mask
    assert x & (x - 1) == 0, f"{label}: not one-hot0: 0x{x:x}"


# =============================================================================
# Tests
# =============================================================================

@cocotb.test()
async def test_round_robin_all_active(dut):
    """All 4 requesters active -- each granted within 4x2 cycles, DUT matches ref."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    ref = RRArbiterRef()
    seen = 0
    dut.req_i.value  = 0b1111
    dut.mask_i.value = 0b0000
    for cycle in range(N_REQ * 4):
        await tick(dut)
        g_dut = int(dut.grant_o.value)
        g_ref = ref.step(0b1111, 0, 0, 0)
        onehot0(g_dut, N_REQ, f"rr{cycle}")
        assert g_dut == g_ref, f"rr {cycle}: DUT={g_dut:#06b} REF={g_ref:#06b}"
        seen |= g_dut
    assert seen == 0b1111, f"not all granted: seen={seen:#06b}"
    dut._log.info("PASS round-robin")


@cocotb.test()
async def test_mask_suppression(dut):
    """Req[1] masked -- must never be granted."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    ref = RRArbiterRef()
    dut.req_i.value  = 0b1111
    dut.mask_i.value = 0b0010
    for cycle in range(N_REQ * 4):
        await tick(dut)
        g_dut = int(dut.grant_o.value)
        g_ref = ref.step(0b1111, 0b0010, 0, 0)
        assert not (g_dut & 0b0010), f"mask{cycle}: req[1] granted ({g_dut:#06b})"
        assert g_dut == g_ref, f"mask{cycle}: DUT={g_dut:#06b} REF={g_ref:#06b}"
    dut._log.info("PASS mask suppression")


@cocotb.test()
async def test_burst_lock_hold(dut):
    """Grant frozen 4 cycles while burst_lock_i=1, released on last_i."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    ref = RRArbiterRef()

    dut.req_i.value        = 0b0100
    dut.mask_i.value       = 0b0000
    dut.burst_lock_i.value = 0
    dut.last_i.value       = 0

    await tick(dut)
    first = int(dut.grant_o.value)
    g_ref = ref.step(0b0100, 0, 0, 0)
    assert first == 0b0100, f"expected 0b0100 got {first:#06b}"
    assert first == g_ref

    # FallingEdge escapes ReadOnly so signal writes below are in the active phase.
    await FallingEdge(dut.clk)
    dut.burst_lock_i.value = 1
    dut.req_i.value        = 0b1111
    for cycle in range(4):
        await tick(dut)
        g_dut = int(dut.grant_o.value)
        g_ref = ref.step(0b1111, 0, 1, 0)
        assert g_dut == first, f"burst{cycle}: changed to {g_dut:#06b}"
        assert g_dut == g_ref, f"burst{cycle}: DUT={g_dut:#06b} REF={g_ref:#06b}"

    await FallingEdge(dut.clk)
    dut.last_i.value = 1
    await tick(dut)
    ref.step(0b1111, 0, 1, 1)
    await FallingEdge(dut.clk)
    dut.last_i.value = 0
    dut.burst_lock_i.value = 0

    await tick(dut)
    g_dut = int(dut.grant_o.value)
    g_ref = ref.step(0b1111, 0, 0, 0)
    assert g_dut == g_ref, f"post-burst: DUT={g_dut:#06b} REF={g_ref:#06b}"
    dut._log.info("PASS burst lock")


@cocotb.test()
async def test_priority_wrap(dut):
    """req[3] and req[0] only -- pointer wraps from 3 to 0."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    ref = RRArbiterRef()
    dut.req_i.value  = 0b1001
    dut.mask_i.value = 0b0000
    for cycle in range(12):
        await tick(dut)
        g_dut = int(dut.grant_o.value)
        g_ref = ref.step(0b1001, 0, 0, 0)
        assert not (g_dut & 0b0110), f"wrap{cycle}: inactive granted ({g_dut:#06b})"
        assert g_dut == g_ref, f"wrap{cycle}: DUT={g_dut:#06b} REF={g_ref:#06b}"
    dut._log.info("PASS priority wrap")


@cocotb.test()
async def test_single_requester(dut):
    """One requester only -- granted every cycle."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)
    ref = RRArbiterRef()
    dut.req_i.value  = 0b0010
    dut.mask_i.value = 0b0000
    for cycle in range(8):
        await tick(dut)
        g_dut = int(dut.grant_o.value)
        g_ref = ref.step(0b0010, 0, 0, 0)
        assert g_dut == g_ref, f"single{cycle}: DUT={g_dut:#06b} REF={g_ref:#06b}"
    dut._log.info("PASS single requester")
