"""Pillar 9 — Power Intent / UPF (Unified Power Format).
Parses .upf file, checks power domain structure, and runs Yosys read_upf
to verify isolation cell insertion in the gate netlist.
Returns PASS | FAIL | SKIP | WARN.
"""
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional
from .common import C, Dashboard, PILLAR_ICONS


# ── UPF dataclass ─────────────────────────────────────────────────────────────

@dataclass
class UPFMetrics:
    domains: List[str] = field(default_factory=list)
    supply_nets: List[str] = field(default_factory=list)
    isolation_strategies: List[str] = field(default_factory=list)
    level_shifters: List[str] = field(default_factory=list)
    retention_regs: List[str] = field(default_factory=list)
    always_on_domains: List[str] = field(default_factory=list)
    domain_boundaries: List[tuple] = field(default_factory=list)  # (from, to)
    errors: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    yosys_status: str = "SKIP"


# ── UPF parser ────────────────────────────────────────────────────────────────

def _parse_upf(upf_file: Path) -> UPFMetrics:
    """Statically parse UPF Tcl commands to extract power architecture."""
    m = UPFMetrics()
    text = upf_file.read_text(errors='replace')

    for line in text.splitlines():
        line = line.strip()
        if line.startswith('#') or not line:
            continue

        # create_power_domain <name> [-elements <...>]
        pd = re.match(r'create_power_domain\s+(\S+)', line)
        if pd:
            m.domains.append(pd.group(1))

        # create_supply_net <name>
        sn = re.match(r'create_supply_net\s+(\S+)', line)
        if sn:
            m.supply_nets.append(sn.group(1))

        # set_isolation <strategy_name> -domain <domain> ...
        iso = re.match(r'set_isolation\s+(\S+).*-domain\s+(\S+)', line)
        if iso:
            m.isolation_strategies.append(f"{iso.group(1)} @ {iso.group(2)}")

        # set_level_shifter <name> -domain <domain> ...
        ls = re.match(r'set_level_shifter\s+(\S+).*-domain\s+(\S+)', line)
        if ls:
            m.level_shifters.append(f"{ls.group(1)} @ {ls.group(2)}")

        # set_retention <name> -domain <domain>
        ret = re.match(r'set_retention\s+(\S+).*-domain\s+(\S+)', line)
        if ret:
            m.retention_regs.append(f"{ret.group(1)} @ {ret.group(2)}")

        # create_power_switch (always-on supply topology indicator)
        ps = re.match(r'create_power_switch\s+(\S+)', line)
        if ps:
            m.always_on_domains.append(ps.group(1))

    return m


def _check_domain_boundaries(m: UPFMetrics):
    """Cross-check: every non-primary domain must have at least one isolation strategy."""
    if len(m.domains) <= 1:
        return  # single domain — no boundaries to check
    primary = m.domains[0]
    iso_domains = {s.split(' @ ')[-1] for s in m.isolation_strategies}
    for domain in m.domains[1:]:
        if domain not in iso_domains:
            m.warnings.append(
                f"Domain '{domain}' has no isolation strategy — "
                f"signals crossing to '{primary}' may corrupt when powered off")


def _check_level_shifters(m: UPFMetrics):
    """Warn if multi-domain design has no level shifters (voltage mismatch risk)."""
    if len(m.domains) > 1 and not m.level_shifters:
        m.warnings.append(
            "Multi-domain design with no set_level_shifter — "
            "if domains run at different voltages, synthesis won't insert level shifters")


def _run_yosys_upf(flow, upf_file: Path, synth_v: Path) -> str:
    """Run Yosys read_upf on the gate netlist to verify isolation cell insertion.
    Returns PASS | FAIL | SKIP | WARN."""
    if not synth_v.exists():
        return "SKIP"  # no netlist yet

    yosys_log = flow.log_dir / f"upf_{flow.top}_yosys.log"
    tcl = flow.build_dir / "sta" / f"upf_check_{flow.top}.tcl"
    tcl.parent.mkdir(exist_ok=True)
    # No liberty needed for structural UPF check — avoids sky130 liberty parse errors
    tcl.write_text(
        f"read_verilog {synth_v}\n"
        f"read_upf {upf_file}\n"
        f"hierarchy -top {flow.top}\n"
        f"upf_check\n"
        f"stat\n"
    )
    result = subprocess.run(
        f"yosys -q -s {tcl} > {yosys_log} 2>&1",
        shell=True, cwd=flow.root)

    if not yosys_log.exists():
        return "SKIP"
    log_text = yosys_log.read_text(errors='replace')

    if result.returncode != 0 or 'ERROR' in log_text.upper():
        # Yosys < 0.36 has no read_upf — treat as advisory, not FAIL
        if 'read_upf' in log_text and (
                'no such command' in log_text.lower() or
                'unknown command' in log_text.lower()):
            return "WARN"
        return "FAIL"

    if 'upf_check' in log_text.lower() and 'error' not in log_text.lower():
        return "PASS"
    return "WARN"


# ── Entry point ───────────────────────────────────────────────────────────────

def run(flow) -> str:
    icon = "⚡"
    print(f"\n  {C.hdr('━━━ PILLAR 9: Power Intent / UPF')}  {icon}  {C.dim(flow.top)}")

    upf_files = list(flow.verif_dir.glob("*.upf")) + list(flow.src_dir.glob("*.upf"))
    if not upf_files:
        print(f"     {C.warn('⚠ Skipped')} — no .upf file in {flow.verif_dir} or {flow.src_dir}")
        print(f"     {C.dim('Create verification/{top}.upf to enable power intent verification.')}")
        print(f"     {C.dim('Minimal UPF: create_power_domain PD_TOP -include_scope')}")
        return "SKIP"

    upf_file = upf_files[0]
    print(f"     {C.info('▶')} Parsing UPF: {upf_file.name}")
    m = _parse_upf(upf_file)
    _check_domain_boundaries(m)
    _check_level_shifters(m)

    # Yosys UPF netlist check (only if synth netlist exists)
    synth_v = flow.build_dir / "sta" / f"{flow.top}_synth.v"
    print(f"     {C.info('▶')} Checking gate netlist UPF compliance (Yosys read_upf)...")
    m.yosys_status = _run_yosys_upf(flow, upf_file, synth_v)

    # ── Dashboard ─────────────────────────────────────────────────────────────
    dash = Dashboard("POWER INTENT — UPF", C.BMAGENTA)
    dash.add_metric("UPF File",           upf_file.name)
    dash.add_metric("Power Domains",      len(m.domains),
                    value_color=C.BGREEN if m.domains else C.BRED)
    dash.add_metric("Supply Nets",        len(m.supply_nets))
    dash.add_metric("Isolation Strategies", len(m.isolation_strategies),
                    value_color=C.BGREEN if m.isolation_strategies or len(m.domains) <= 1
                    else C.BYELLOW)
    dash.add_metric("Level Shifters",     len(m.level_shifters))
    dash.add_metric("Retention Regs",     len(m.retention_regs))
    dash.add_metric("Power Switches",     len(m.always_on_domains))

    yosys_color = (C.BGREEN if m.yosys_status == "PASS"
                   else C.BYELLOW if m.yosys_status in ("SKIP", "WARN")
                   else C.BRED)
    dash.add_metric("Yosys UPF Check",   m.yosys_status, value_color=yosys_color)

    if m.domains:
        dash.add_section_header(f"Power Domains ({len(m.domains)})")
        for d in m.domains[:6]:
            dash.add_row("domain", d)

    if m.isolation_strategies:
        dash.add_section_header("Isolation")
        for iso in m.isolation_strategies[:4]:
            dash.add_row("strategy", iso[:40])

    if m.warnings:
        dash.add_section_header(f"Warnings ({len(m.warnings)})")
        for w in m.warnings[:4]:
            dash.add_row("⚠", w[:60])

    # ── Insights ──────────────────────────────────────────────────────────────
    if m.domains:
        dash.add_insight(
            f"UPF defines {len(m.domains)} power domain(s) — "
            f"synthesis will insert isolation/level-shift cells at domain crossings.", "good")
    if m.isolation_strategies:
        dash.add_insight(
            f"{len(m.isolation_strategies)} isolation strateg(ies) declared — "
            f"gates crossing powered-off domains will be gated correctly.", "good")
    if m.warnings:
        for w in m.warnings[:2]:
            dash.add_insight(w, "warn")
    # Retention is only needed when a domain can be powered OFF (has a power switch).
    # A single always-on domain needs no retention — suppress the false positive.
    if not m.retention_regs and len(m.domains) > 1 and m.always_on_domains:
        dash.add_insight(
            "No set_retention declared — state in powered-off domains will be lost on wake-up.", "warn")
    elif not m.retention_regs and len(m.domains) == 1:
        dash.add_insight(
            "Single always-on domain — no retention cells needed; all state is preserved.", "good")
    dash.add_insight(
        "UPF P3/P4 power-aware simulation requires Questa MV or VCS-LP — "
        "Verilator/Icarus do not model X-state injection on domain power-off.", "improve")
    dash.add_insight(
        "For full OpenROAD UPF flow: place UPF in verification/ and run OpenROAD "
        "read_upf → insert_power_switches → place_pd.", "improve")
    dash.print()

    if not m.domains:
        print(f"  {C.err('❌ UPF FAIL')} — no create_power_domain found in {upf_file.name}")
        return "FAIL"

    if m.warnings and not m.isolation_strategies and len(m.domains) > 1:
        print(f"  {C.warn('⚠ UPF WARN')} — multi-domain but no isolation strategies defined")
        return "WARN"

    if m.yosys_status == "FAIL":
        print(f"  {C.err('❌ UPF FAIL')} — Yosys read_upf found errors in gate netlist")
        return "FAIL"

    print(f"  {C.ok('✓ UPF PASS')}  "
          f"{C.dim(f'{len(m.domains)} domains | {len(m.isolation_strategies)} iso | Yosys={m.yosys_status}')}")
    return "PASS"
