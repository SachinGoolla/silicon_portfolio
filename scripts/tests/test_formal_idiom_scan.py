"""Regression tests for p2_formal.py's static formal-idiom pre-flight scan.

Each test traces to a real finding from auditing this repo's 9 IPs for two
known-bad formal patterns on this toolchain: unparseable SVA syntax, and a
plain register's `initial X=const` that this Yosys build doesn't reliably
honor for BMC's basecase. See project memory feedback_formal_sby.
"""
from pathlib import Path

from pillars.p2_formal import _scan_formal_idioms


def _write(tmp_path: Path, name: str, content: str) -> Path:
    p = tmp_path / name
    p.write_text(content)
    return p


def test_sva_assert_property_is_error(tmp_path):
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            FOO: assert property (
                @(posedge clk) disable iff (!rst_n)
                a |-> b
            );
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert len(errors) == 1
    assert "SVA syntax" in errors[0]


def test_sva_named_property_block_is_error(tmp_path):
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            property foo_p;
                @(posedge clk) a |-> b;
            endproperty
            FOO: assert property (foo_p);
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert len(errors) == 1


def test_sva_inside_operator_is_error(tmp_path):
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            always_comb assert(!sel || (addr inside {5'h00, 5'h04}));
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert len(errors) == 1


def test_immediate_assertions_are_clean(tmp_path):
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            initial assume(!rst_n);
            always_comb begin
                if (rst_n) assert(a == b);
            end
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert errors == []
    assert warnings == []


def test_initial_const_without_assume_is_warning(tmp_path):
    """The mod1000/mod3ud/async_fifo/axi_lite_slave/fpu_axi_periph pattern:
    a plain `initial f_was_reset = 0;` flop with no `initial assume(...)`
    anywhere -- soft warning, not a hard error, since whether it actually
    causes a false PASS depends on whether the file's properties genuinely
    depend on registered state (see fpu_top vs mod1000 in project memory)."""
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            logic f_was_reset;
            initial f_was_reset = 0;
            always_ff @(posedge clk or negedge rst_n)
                if (!rst_n) f_was_reset <= 1'b1;
            always_comb begin
                if (f_was_reset) assert(count <= 10'd999);
            end
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert errors == []
    assert len(warnings) == 1
    assert "initial X=const" in warnings[0]


def test_initial_const_with_assume_present_is_clean(tmp_path):
    """If the file ALSO has `initial assume(...)` somewhere, don't warn --
    that's the confirmed-safe idiom coexisting with (now-harmless) history
    tracking, not the bug pattern."""
    rtl = _write(tmp_path, "dut.sv", """
        `ifdef FORMAL
            initial assume(!rst_n);
            logic some_history_q;
            initial some_history_q = 1'b0;
            always_comb begin
                if (rst_n) assert(a == b);
            end
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert warnings == []


def test_explanatory_comments_do_not_self_trigger(tmp_path):
    """Regression: this scanner's own docstring/RTL header comments explain
    these anti-patterns by name (e.g. "NOT SVA `assert property`"), which
    self-triggered as a false positive on apb_uart_master.sv before
    comments were stripped before scanning."""
    rtl = _write(tmp_path, "dut.sv", """
        // Written as immediate assertions, NOT SVA `assert property (...)`.
        // `inside {...}` isn't supported either -- spelled out as OR.
        `ifdef FORMAL
            initial assume(!rst_n);
            always_comb begin
                if (rst_n) assert(a == b);
            end
        `endif
    """)
    errors, warnings = _scan_formal_idioms([rtl])
    assert errors == []
    assert warnings == []


def test_no_formal_block_is_clean(tmp_path):
    rtl = _write(tmp_path, "dut.sv", "module dut(); endmodule\n")
    errors, warnings = _scan_formal_idioms([rtl])
    assert errors == []
    assert warnings == []


def test_multiple_files_aggregate_independently(tmp_path):
    good = _write(tmp_path, "good.sv", """
        `ifdef FORMAL
            initial assume(!rst_n);
            always_comb if (rst_n) assert(a);
        `endif
    """)
    bad = _write(tmp_path, "bad.sv", """
        `ifdef FORMAL
            BAD: assert property (@(posedge clk) a);
        `endif
    """)
    errors, warnings = _scan_formal_idioms([good, bad])
    assert len(errors) == 1
    assert "bad.sv" in errors[0]
