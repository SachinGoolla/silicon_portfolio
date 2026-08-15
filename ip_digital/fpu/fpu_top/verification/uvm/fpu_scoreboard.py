"""FPU scoreboard — pairs input captures with output captures and checks."""
import cocotb
from pyuvm import uvm_scoreboard, uvm_tlm_analysis_fifo, ConfigDB
from fpu_ref import expected, is_nan, CheckResult


class FPUScoreboard(uvm_scoreboard):
    """
    Receives input and output captures from the two monitors via FIFOs.
    Checks each output against the reference model.

    Assumes serialized transactions: driver waits for ready_o before each
    new input, so inputs and outputs arrive in FIFO order.
    """

    def build_phase(self):
        self.input_fifo  = uvm_tlm_analysis_fifo("input_fifo",  self)
        self.output_fifo = uvm_tlm_analysis_fifo("output_fifo", self)
        self.passed = 0
        self.failed = 0

    async def run_phase(self):
        while True:
            inp = await self.input_fifo.get()
            out = await self.output_fifo.get()
            self._check(inp, out)

    def _check(self, inp, out):
        cr = expected(inp)
        errors = []

        if cr.exact_result is not None:
            if out.result != cr.exact_result:
                errors.append(
                    f"result_o: got 0x{out.result:08X} expected 0x{cr.exact_result:08X}"
                )

        if cr.exact_int is not None:
            if out.int_result != cr.exact_int:
                errors.append(
                    f"int_result_o: got 0x{out.int_result:08X} expected 0x{cr.exact_int:08X}"
                )

        if cr.nv_flag is not None:
            got_nv = bool((out.fflags >> 4) & 1)
            if got_nv != cr.nv_flag:
                errors.append(
                    f"NV flag: got {got_nv} expected {cr.nv_flag}"
                )

        if cr.classify is not None:
            if cr.classify.get("nan"):
                if not is_nan(out.result):
                    errors.append(
                        f"expected NaN output, got 0x{out.result:08X}"
                    )

        if errors:
            self.failed += 1
            msg = f"SCOREBOARD FAIL [{cr.description}]: " + "; ".join(errors)
            self.logger.error(msg)
            cocotb.log.error(msg)
        else:
            self.passed += 1
            self.logger.debug(f"OK [{cr.description}]")

    def report_phase(self):
        total = self.passed + self.failed
        self.logger.info(
            f"Scoreboard: {self.passed}/{total} passed, {self.failed} failed"
        )
        if self.failed:
            self.logger.error("SCOREBOARD: mismatches detected — DUT has bugs!")
