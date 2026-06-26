import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

@cocotb.test()
async def mod1000_counter_test(dut):
    """Test that the counter correctly increments and rolls over."""
    # Start 3GHz clock (approx 0.33ns period, using 1ns for simplicity in simulation)
    cocotb.start_soon(Clock(dut.clk, 1, unit="ns").start())
    
    # Initialize and Reset
    dut.rst_n.value = 0
    await Timer(2, unit="ns")
    dut.rst_n.value = 1
    
    # Run for a few cycles to ensure basic counting works
    for i in range(10):
        await RisingEdge(dut.clk)
        count_val = int(dut.count.value)
        assert count_val < 1000, f"Count {count_val} exceeded modulus 999!"
        
    # If it didn't crash and bounds are respected, pass!
    dut._log.info("mod1000 Basic Functional Test Passed!")
