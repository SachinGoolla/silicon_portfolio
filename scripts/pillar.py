#!/usr/bin/env python3
"""Silicon Portfolio — 8-pillar RTL verification orchestrator."""
import argparse
import hashlib
import json
import subprocess
import sys
import shutil
import re
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Per-pillar modules — each exposes run(flow) -> str
from pillars.common import (C, PILLAR_ICONS, PILLAR_NAMES, Dashboard,
                             AllPillarMetrics, LintMetrics, FormalMetrics,
                             FunctionalMetrics, SimMetrics, CoverageMetrics,
                             SynthMetrics, LECMetrics, STAMetrics)
from pillars import (p1_lint, p2_formal, p3_functional, p4_sim,
                     p5_coverage, p6_synth, p7_lec, p8_sta_gls, p9_upf)


# ── PillarFlow: shared state and utilities ────────────────────────────────────

class PillarFlow:
    def __init__(self, top_module: str, verbose: bool = False,
                 pdk: str = 'auto', ip_path: Optional[str] = None,
                 params: str = ""):
        self.top     = top_module
        self.verbose = verbose
        self.pdk     = pdk
        self.root    = Path(__file__).parent.parent.resolve()
        # Parse "KEY=VAL,KEY2=VAL2" into dict for use by pillars
        self.params: Dict[str, str] = {}
        for pair in params.split(","):
            pair = pair.strip()
            if "=" in pair:
                k, v = pair.split("=", 1)
                self.params[k.strip()] = v.strip()

        # IP path: explicit override or default convention
        if ip_path:
            self.ip_dir = (self.root / ip_path).resolve()
        else:
            self.ip_dir = self.root / "ip_digital" / "common_cells" / self.top

        self.src_dir   = self.ip_dir / "rtl"
        self.verif_dir = self.ip_dir / "verification"
        self.build_dir = self.ip_dir / "build"
        self.lib_dir   = self.root / "lib"
        self.log_dir   = self.ip_dir / "logs"
        self.state_file = self.build_dir / ".pillar_state.json"

        self.build_dir.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)

        # Git SHA — used for waveform archiving and regression tracking
        try:
            self.sha = subprocess.check_output(
                "git rev-parse --short HEAD", shell=True, cwd=self.root,
                stderr=subprocess.DEVNULL, text=True).strip() or "unknown"
        except Exception:
            self.sha = "unknown"
        self.archive_dir = self.build_dir / "archive" / self.sha
        self.archive_dir.mkdir(parents=True, exist_ok=True)

        self.state       = self._load_state()
        self.all_metrics = self._load_last_metrics() or AllPillarMetrics(
            timestamp=datetime.now().isoformat(), module_name=top_module)
        self.all_metrics.timestamp = datetime.now().isoformat()

    def archive_artifact(self, src: Path, label: str = "", keep: int = 10) -> Optional[Path]:
        """Copy src into build/archive/<sha>/. Prunes oldest SHA dirs beyond keep."""
        if not src.exists():
            return None
        dst = self.archive_dir / src.name
        shutil.copy2(src, dst)
        if self.verbose:
            print(f"     {C.dim(f'→ archived {label or src.name} → archive/{self.sha}/')}")
        # Retention: remove oldest SHA dirs beyond keep limit
        archive_root = self.build_dir / "archive"
        sha_dirs = sorted(archive_root.iterdir(), key=lambda p: p.stat().st_mtime)
        for old in sha_dirs[:-keep]:
            shutil.rmtree(old, ignore_errors=True)
        return dst

    # ── State / checkpointing ─────────────────────────────────────────────────

    def _load_state(self) -> Dict:
        if self.state_file.exists():
            try:
                with open(self.state_file) as f:
                    return json.load(f)
            except Exception:
                return {}
        return {}

    def _save_state(self):
        with open(self.state_file, "w") as f:
            json.dump(self.state, f, indent=2)

    def _load_last_metrics(self) -> Optional[AllPillarMetrics]:
        """Seed from latest report so cached pillars retain values across runs."""
        reports = sorted(self.build_dir.glob(".pillar_report_*.json"))
        if not reports:
            return None
        try:
            with open(reports[-1]) as f:
                d = json.load(f)
            m = AllPillarMetrics(timestamp=d.get('timestamp', ''),
                                 module_name=d.get('module', ''))
            def _safe(cls, data):
                valid = {k: v for k, v in data.items() if k in cls.__dataclass_fields__}
                return cls(**valid)
            if 'lint'       in d: m.lint       = _safe(LintMetrics,       d['lint'])
            if 'formal'     in d: m.formal     = _safe(FormalMetrics,     d['formal'])
            if 'functional' in d: m.functional = _safe(FunctionalMetrics, d['functional'])
            if 'sim'        in d: m.sim        = _safe(SimMetrics,        d['sim'])
            if 'coverage'   in d: m.coverage   = _safe(CoverageMetrics,   d['coverage'])
            if 'synth'      in d: m.synth      = _safe(SynthMetrics,      d['synth'])
            if 'lec'        in d: m.lec        = _safe(LECMetrics,        d['lec'])
            if 'sta'        in d: m.sta        = _safe(STAMetrics,        d['sta'])
            return m
        except Exception:
            return None

    def hash_files(self, file_paths: List[Path]) -> str:
        h = hashlib.sha256()
        for p in sorted(file_paths):
            if p.exists():
                h.update(p.read_bytes())
        return h.hexdigest()

    def is_checkpoint_valid(self, step: str, deps: List[Path]) -> bool:
        return self.state.get(self.top, {}).get(step) == self.hash_files(deps)

    def update_checkpoint(self, step: str, deps: List[Path]):
        self.state.setdefault(self.top, {})[step] = self.hash_files(deps)
        self._save_state()

    # ── FuseSoC / .core integration ───────────────────────────────────────────
    #
    # Three-layer resolution (each layer falls through to the next on failure):
    #   1. .core YAML present  → parse CAPI2, resolve local deps by rglob
    #   2. fusesoc CLI on PATH → use for external dep resolution
    #   3. Glob fallback       → original behaviour, always succeeds

    def _find_core_file(self) -> Optional[Path]:
        """Locate the CAPI2 .core manifest for this module."""
        exact = self.ip_dir / f"{self.top}.core"
        if exact.exists():
            return exact
        candidates = list(self.ip_dir.glob("*.core"))
        return candidates[0] if len(candidates) == 1 else None

    def _resolve_core_deps(self, dep_names: List[str]) -> List[Path]:
        """
        Resolve dependency core-name strings to concrete file lists.
        Format: "vendor:lib:module:version"  (version may be omitted)
        Search order:
          1. Sibling .core files anywhere under repo root
          2. fusesoc CLI (if installed) for externally-fetched cores
        Unresolvable deps are warned and skipped — never hard-fail.
        """
        resolved: List[Path] = []
        for dep in dep_names:
            parts   = dep.split(":")
            modname = parts[2] if len(parts) >= 3 else parts[-1]
            # Skip self-referential deps (common in tb filesets)
            if modname == self.top:
                continue
            # Search repo for matching .core file
            hits = [c for c in self.root.rglob(f"{modname}.core")
                    if c.parent != self.ip_dir]
            if hits:
                dep_dir   = hits[0].parent
                dep_files, _ = self._parse_core_fileset(hits[0], dep_dir, ['rtl'])
                resolved.extend(dep_files)
                continue
            # Try fusesoc CLI for external cores
            if shutil.which("fusesoc"):
                r = subprocess.run(
                    f"fusesoc --cores-root {self.root} show {dep} 2>/dev/null",
                    shell=True, capture_output=True, text=True)
                if r.returncode == 0:
                    print(f"     {C.warn('⚠ dep')} {dep}: external core found in fusesoc "
                          f"registry — run `fusesoc fetch {dep}` to cache locally")
                    continue
            print(f"     {C.warn('⚠ dep')} {dep}: unresolved "
                  f"(no local .core; {'fusesoc not on PATH' if not shutil.which('fusesoc') else 'not in registry'})")
        return resolved

    def _parse_core_fileset(self, core_file: Path, ip_dir: Path,
                             fileset_keys: List[str]) -> Tuple[List[Path], bool]:
        """
        Parse a CAPI2 .core YAML and return (files, has_sv).
        has_sv=True when any file_type is systemVerilogSource.
        Returns ([], False) on any parse error — callers fall back to glob.
        """
        try:
            import yaml  # type: ignore
        except ImportError:
            print(f"     {C.warn('⚠')} PyYAML not installed — "
                  f"pip install pyyaml (or activate .venv). Falling back to glob.")
            return [], False
        try:
            raw  = core_file.read_text()
            core = yaml.safe_load(raw)
        except Exception as e:
            print(f"     {C.warn('⚠')} {core_file.name}: YAML parse error ({e}). "
                  f"Falling back to glob.")
            return [], False
        if not isinstance(core, dict) or 'filesets' not in core:
            print(f"     {C.warn('⚠')} {core_file.name}: not CAPI2 (no 'filesets' key). "
                  f"Falling back to glob.")
            return [], False

        filesets_def = core.get('filesets', {})
        files: List[Path] = []
        seen:  set        = set()
        has_sv            = False
        dep_names:List[str] = []

        for fs_key in fileset_keys:
            fs = filesets_def.get(fs_key)
            if not fs:
                continue
            # Default file_type for all files in this fileset
            default_ft = fs.get('file_type', 'verilogSource')
            if 'systemVerilog' in default_ft:
                has_sv = True
            dep_names.extend(fs.get('depend', []))

            for entry in fs.get('files', []):
                # Entry is either a plain string or a single-key dict with attrs
                if isinstance(entry, dict):
                    fname = next(iter(entry))
                    attrs = entry[fname] or {}
                    ft    = attrs.get('file_type', default_ft)
                else:
                    fname, ft = entry, default_ft
                if 'systemVerilog' in str(ft):
                    has_sv = True
                p = (ip_dir / fname).resolve()
                if p in seen:
                    continue
                seen.add(p)
                if p.exists():
                    files.append(p)
                else:
                    print(f"     {C.warn('⚠ core')} {core_file.name}: "
                          f"declared file not found: {fname}")

        # Recursively pull in dependency files
        for dep_f in self._resolve_core_deps(dep_names):
            if dep_f not in seen:
                seen.add(dep_f); files.append(dep_f)

        return files, has_sv

    def _core_fileset_for_target(self, target: str) -> List[str]:
        """
        Map a pillar target name to the list of .core fileset keys it needs.
        lint/formal/sim/synth/lec/sta all use 'rtl'; functional also adds tb filesets.
        """
        base = ['rtl']
        if target in ('functional', 'sim_tb'):
            base += ['tb_icarus', 'tb_cocotb']
        if target == 'formal':
            base += ['formal']
        return base

    # ── RTL discovery ─────────────────────────────────────────────────────────
    #
    # Public API (used by all pillars):
    #   _find_all_rtl()   → design-only RTL files
    #   _find_top_rtl()   → file containing the top module definition
    #   _find_tb_files()  → testbench + cocotb files (P3 only)
    #   has_sv            → True if any RTL file is SystemVerilog (set by _find_all_rtl)

    def _find_all_rtl(self) -> List[Path]:
        """
        Return design RTL files. Prefers .core 'rtl' fileset; falls back to glob.
        Sets self.has_sv as a side-effect so pillar modules can use -sv flag correctly.
        """
        core_file = self._find_core_file()
        if core_file:
            files, has_sv = self._parse_core_fileset(core_file, self.ip_dir, ['rtl'])
            if files:
                self.has_sv = has_sv
                return files
        # Glob fallback
        seen, files = set(), []
        has_sv = False
        for ext in ('.sv', '.v'):
            for f in sorted(self.src_dir.glob(f"*{ext}")):
                if f.stem not in seen:
                    seen.add(f.stem); files.append(f)
                    if ext == '.sv':
                        has_sv = True
        self.has_sv = has_sv
        return files

    def _find_top_rtl(self) -> Optional[Path]:
        """Find the file that defines the top module. Derived from _find_all_rtl."""
        for f in self._find_all_rtl():
            if f.stem == self.top:
                return f
        # Fallback: search src_dir directly
        for ext in ('.sv', '.v'):
            p = self.src_dir / f"{self.top}{ext}"
            if p.exists():
                return p
        return None

    def _find_tb_files(self) -> List[Path]:
        """
        Return testbench / cocotb files for P3 functional sim.
        Uses .core tb_* filesets if present; falls back to verif_dir glob.
        """
        core_file = self._find_core_file()
        if core_file:
            files, _ = self._parse_core_fileset(
                core_file, self.ip_dir, ['tb_icarus', 'tb_cocotb'])
            if files:
                return files
        # Glob fallback: all sv/v in verification/ (excluding formal sby artifacts)
        seen, files = set(), []
        for ext in ('.sv', '.v', '.py'):
            for f in sorted(self.verif_dir.glob(f"*{ext}")):
                if f.stem not in seen:
                    seen.add(f.stem); files.append(f)
        return files

    def _select_lib_files(self) -> Tuple:
        """Return (tt_lib, all_corners, pdk_name). Never mixes PDKs."""
        all_libs = sorted(self.lib_dir.glob("*.lib"))
        pdk = self.pdk
        if pdk == 'auto':
            pdk = 'sky130' if any('sky130' in f.name for f in all_libs) else 'nangate'
        if pdk == 'sky130':
            corners = [f for f in all_libs if 'sky130' in f.name]
            tt = next((f for f in corners if 'tt_' in f.name), corners[0] if corners else None)
            return tt, corners, 'sky130'
        else:
            nangate = [f for f in all_libs if 'nangate' in f.name.lower() or 'Nangate' in f.name]
            return (nangate[0] if nangate else None), nangate, 'nangate'

    # ── Subprocess helpers ────────────────────────────────────────────────────

    def run_capture(self, cmd: str, cwd: Path = None) -> subprocess.CompletedProcess:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              cwd=cwd or self.root)

    def run_logged(self, cmd: str, log_file: Path, step_name: str,
                   cwd: Path = None) -> bool:
        """Run cmd, return True on success. Never exits — callers decide."""
        result = subprocess.run(cmd, shell=True, cwd=cwd or self.root)
        if result.returncode != 0 and self.verbose:
            print(f"  {C.dim(f'  [{step_name}] exit {result.returncode}')}")
        return result.returncode == 0

    # ── VCD helper ────────────────────────────────────────────────────────────

    def _open_vcd(self, vcd_file: Path):
        if not vcd_file.exists():
            return
        r = subprocess.run(f"code --reuse-window '{vcd_file}'",
                           shell=True, capture_output=True)
        if r.returncode == 0:
            print(f"  {C.ok('📊 VCD opened in VaporView:')} {vcd_file.name}")
        else:
            print(f"  {C.info('📊 VCD available:')} {vcd_file}")

    # ── Parallel-child result files ───────────────────────────────────────────

    def _save_step_result(self, step: str, status: str):
        """Write per-step result JSON for collection by the parallel orchestrator."""
        result_file = self.build_dir / f".pillar_result_{step}.json"
        data = {"step": step, "status": status, "metrics": self._metrics_dict()}
        with open(result_file, "w") as f:
            json.dump(data, f, indent=2)

    def _load_step_result(self, step: str) -> Optional[tuple]:
        """Read a per-step result written by a parallel child. Returns (status, metrics_dict)."""
        result_file = self.build_dir / f".pillar_result_{step}.json"
        if not result_file.exists():
            return None
        try:
            with open(result_file) as f:
                d = json.load(f)
            return d.get("status", "FAIL"), d.get("metrics", {})
        except Exception:
            return None

    def _recover_status_from_log(self, step: str) -> str:
        """Fallback: scan the step's log file for pass/fail keywords when result JSON is absent."""
        log_candidates = [
            self.log_dir / f"{step}_{self.top}.log",
            self.log_dir / f"formal_{self.top}.log",
            self.log_dir / f"sim_{self.top}.log",
        ]
        for log_path in log_candidates:
            if log_path.exists():
                text = log_path.read_text(errors='replace')
                if any(kw in text for kw in ('$fatal', '$error', 'FAILED', 'ERROR:', 'DONE (FAIL')):
                    return "FAIL"
                if any(kw in text for kw in ('DONE (PASS', 'All tests passed', '$finish', 'PASS')):
                    return "WARN"  # partial recovery — not confident enough for PASS
        return "FAIL"

    def _merge_step_metrics(self, step: str, metrics_dict: dict):
        """Merge one step's metrics from a child process into our all_metrics."""
        cls_map = {
            "lint":       ("lint",       LintMetrics),
            "formal":     ("formal",     FormalMetrics),
            "functional": ("functional", FunctionalMetrics),
            "sim":        ("sim",        SimMetrics),
            "coverage":   ("coverage",   CoverageMetrics),
            "synth":      ("synth",      SynthMetrics),
            "lec":        ("lec",        LECMetrics),
            "sta":        ("sta",        STAMetrics),
        }
        if step not in cls_map or step not in metrics_dict:
            return
        attr, cls = cls_map[step]
        d = metrics_dict[step]
        valid = {k: v for k, v in d.items() if k in cls.__dataclass_fields__}
        # CoverageMetrics.uncovered_lines: JSON gives list[list], restore to list[tuple]
        if step == "coverage" and "uncovered_lines" in valid:
            valid["uncovered_lines"] = [tuple(t) for t in valid["uncovered_lines"]]
        setattr(self.all_metrics, attr, cls(**valid))

    # ── Persistence ───────────────────────────────────────────────────────────

    def _metrics_dict(self) -> dict:
        m = self.all_metrics
        return {
            "timestamp": m.timestamp,
            "module":    m.module_name,
            "lint":      asdict(m.lint),
            "formal":    asdict(m.formal),
            "functional":asdict(m.functional),
            "sim":       asdict(m.sim),
            "coverage":  {**asdict(m.coverage),
                          "uncovered_lines": [list(t) for t in m.coverage.uncovered_lines]},
            "synth":     asdict(m.synth),
            "lec":       asdict(m.lec),
            "sta":       {**asdict(m.sta), "critical_paths": m.sta.critical_paths},
        }

    def _save_report(self):
        d = self._metrics_dict()
        ts = d["timestamp"].replace(':', '').replace('.', '')
        report = self.build_dir / f".pillar_report_{ts}.json"
        with open(report, "w") as f:
            json.dump(d, f, indent=2)
        if self.verbose:
            print(f"\n  {C.info('📊 Report:')} {report}")
        return report

    def _append_history(self, pillar_results: Dict[str, str]):
        """Append a compact row to the long-term regression DB (.pillar_history.jsonl)."""
        m = self.all_metrics
        row = {
            "ts":              m.timestamp,
            "module":          m.module_name,
            "lint_warn":       m.lint.warnings,
            "lint_errors":     m.lint.errors,
            "formal_status":   m.formal.status,
            "formal_depth":    m.formal.depth,
            "func_pass":       m.functional.tests_passed,
            "func_fail":       m.functional.tests_failed,
            "cov_pct":         m.coverage.line_coverage_pct,
            "cov_uncovered":   len(m.coverage.uncovered_lines),
            "synth_cells":     m.synth.total_cells,
            "synth_status":    m.synth.status,
            "lec_status":      m.lec.status,
            "lec_proven":      m.lec.proven_points,
            "slack_ns":        m.sta.slack_ns,
            "slack_status":    m.sta.slack_status,
            "cells":           m.sta.total_cells,
            "max_freq_mhz":    m.sta.max_frequency_mhz,
            "gls_status":      m.sta.gls_status,
            "cov_toggle_pct":  m.coverage.toggle_coverage_pct,
            "sha":             self.sha,
            "pillar_results":  pillar_results,
        }
        history_file = self.build_dir / ".pillar_history.jsonl"
        with open(history_file, "a") as f:
            f.write(json.dumps(row) + "\n")

    # ── History / regression ──────────────────────────────────────────────────

    def print_history(self, n: int = 10):
        history_file = self.build_dir / ".pillar_history.jsonl"

        # Try full history first
        rows = []
        if history_file.exists():
            for line in history_file.read_text().splitlines():
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass

        # Fall back to adjacent report diff if no history yet
        if len(rows) < 2:
            reports = sorted(self.build_dir.glob(".pillar_report_*.json"))
            if len(reports) < 2:
                print(f"\n  {C.warn('⚠ Need at least 2 runs for history')}")
                return
            rows = []
            for rp in reports[-min(n, len(reports)):]:
                try:
                    with open(rp) as f:
                        d = json.load(f)
                    rows.append({
                        "ts": d.get("timestamp", "?"),
                        "module": d.get("module", "?"),
                        "lint_warn": d.get("lint", {}).get("warnings", 0),
                        "formal_status": d.get("formal", {}).get("status", "?"),
                        "func_pass": d.get("functional", {}).get("tests_passed", 0),
                        "slack_ns": d.get("sta", {}).get("slack_ns", 0),
                        "cells": d.get("sta", {}).get("total_cells", 0),
                        "cov_uncovered": len(d.get("coverage", {}).get("uncovered_lines", [])),
                    })
                except Exception:
                    pass

        rows = rows[-n:]
        print(f"\n  {C.hdr('━━━ PILLAR HISTORY')}  {C.dim(self.top)}"
              f"  {C.dim(f'({len(rows)} entries)')}")

        def _delta(label, vals, good='up', fmt=str, suffix=''):
            prev, curr = vals[-2], vals[-1]
            try:
                diff = float(curr) - float(prev)
            except (TypeError, ValueError):
                diff = None
            cv = f"{fmt(curr)}{suffix}"
            if diff is None or diff == 0:
                arrow = C.dim('  ━')
                d = C.dim(f"{fmt(prev)}{suffix} → {cv}")
            elif (diff > 0) == (good == 'up'):
                arrow = C.ok(' ▲'); d = f"{C.dim(f'{fmt(prev)}{suffix}')} → {C.ok(cv)}  {C.dim(f'({diff:+.3g})')}"
            else:
                arrow = C.err(' ▼'); d = f"{C.dim(f'{fmt(prev)}{suffix}')} → {C.err(cv)}  {C.dim(f'({diff:+.3g})')}"
            print(f"  {arrow}  {label:<28} {d}")

        ts_list = [r.get('ts', '?')[:16] for r in rows]
        print(f"  {C.dim('timestamps:')} {C.dim(' | '.join(ts_list))}\n")

        print(f"  {C.info('── Lint')}")
        _delta("Warnings", [r.get('lint_warn', 0) for r in rows], good='down')

        print(f"\n  {C.info('── Formal')}")
        statuses = [r.get('formal_status', '?') for r in rows]
        prev_s, curr_s = statuses[-2], statuses[-1]
        sc = C.ok(curr_s) if curr_s == 'PASS' else C.err(curr_s)
        print(f"  {'  ━'}  {'Status':<28} {C.dim(prev_s)} → {sc}")

        print(f"\n  {C.info('── Functional')}")
        _delta("Tests Passed", [r.get('func_pass', 0) for r in rows], good='up')
        _delta("Tests Failed", [r.get('func_fail', 0) for r in rows], good='down')

        print(f"\n  {C.info('── Coverage')}")
        _delta("Uncovered Lines", [r.get('cov_uncovered', 0) for r in rows], good='down')
        _delta("Line Cov %", [r.get('cov_pct', 0) for r in rows], good='up',
               fmt=lambda x: f"{float(x):.1f}", suffix='%')

        print(f"\n  {C.info('── Timing')}")
        _delta("Slack",    [r.get('slack_ns', 0) for r in rows], good='up',
               fmt=lambda x: f"{float(x):.3f}", suffix=' ns')
        _delta("Max Freq", [r.get('max_freq_mhz', r.get('sta', {}).get('max_frequency_mhz', 0) if isinstance(r.get('sta'), dict) else 0) for r in rows],
               good='up', fmt=lambda x: f"{float(x):.1f}", suffix=' MHz')
        _delta("Cells",   [r.get('cells', 0) for r in rows], good='down')
        print()

    def print_timing_trend(self, n: int = 50):
        """Show worst-slack and max-freq trend over last N runs with SHA."""
        history_file = self.build_dir / ".pillar_history.jsonl"
        if not history_file.exists():
            print(f"\n  {C.warn('⚠ No history yet — run at least one full pillar pass first')}")
            return
        rows = []
        for line in history_file.read_text().splitlines():
            try: rows.append(json.loads(line))
            except Exception: pass
        rows = rows[-n:]
        if not rows:
            print(f"\n  {C.warn('⚠ No history rows found')}")
            return
        print(f"\n  {C.hdr('━━━ Timing Trend')}  {C.dim(f'last {len(rows)} runs — {self.top}')}")
        print(f"  {'SHA':<8}  {'Slack(ns)':>10}  {'Status':<6}  {'MaxFreq(MHz)':>13}  {'Timestamp'}")
        print(f"  {'-'*7}  {'-'*10}  {'-'*6}  {'-'*13}  {'-'*19}")
        for r in rows:
            sha    = r.get('sha', '?')[:7]
            slack  = r.get('slack_ns', None)
            status = r.get('slack_status', '?')
            freq   = r.get('max_freq_mhz', None)
            ts     = r.get('ts', '')[:19]
            slack_s = f"{float(slack):+.3f}" if slack is not None else "  N/A  "
            freq_s  = f"{float(freq):.1f}" if freq is not None else "N/A"
            if status == "MET":       status_s = C.ok(status)
            elif status == "VIOLATED": status_s = C.err(status)
            else:                      status_s = C.dim(status)
            print(f"  {sha:<8}  {slack_s:>10}  {status_s:<6}  {freq_s:>13}  {ts}")
        print()

    # ── Summary ───────────────────────────────────────────────────────────────

    def print_summary(self, results: Dict[str, str] = None):
        results = results or {}
        m = self.all_metrics

        def _status(key, ok_condition):
            r = results.get(key)
            if r == "SKIP":  return C.warn("SKIP")
            if r == "FAIL":  return C.err("FAIL")
            if r == "WARN":  return C.warn("WARN")
            if r == "PASS" or ok_condition: return C.ok("PASS")
            return C.dim("—")

        dash = Dashboard("ALL PILLARS — 9-PILLAR FLOW", C.BCYAN)
        dash.add_metric("P1 Lint+CDC",    _status("lint",       m.lint.warnings == 0 and m.lint.errors == 0))
        dash.add_metric("P2 Formal",      _status("formal",     m.formal.status == "PASS"))
        if m.functional.tests_total > 0:
            dash.add_metric("P3 Functional",
                            C.ok(f"{m.functional.tests_passed}/{m.functional.tests_total}")
                            if m.functional.tests_failed == 0 else
                            C.err(f"{m.functional.tests_passed}/{m.functional.tests_total}"))
        else:
            dash.add_metric("P3 Functional", _status("functional", False))
        dash.add_metric("P4 Simulation",   _status("sim",        m.sim.status == "PASS"))
        dash.add_metric("P5 Coverage",     _status("coverage",   True))
        dash.add_metric("P6 Synthesis",    _status("synth",      m.synth.status == "PASS"))
        dash.add_metric("P7 LEC",          _status("lec",        m.lec.status in ("PASS", "WARN")))
        dash.add_metric("P8 STA+GLS",      _status("sta",        m.sta.slack_status == "MET"))
        if "upf" in results:
            dash.add_metric("P9 UPF",       _status("upf",        results.get("upf") == "PASS"))
        dash.add_section_header()
        if m.synth.total_cells > 0:
            dash.add_metric("Cell Count",    str(m.synth.total_cells))
        if m.sta.slack_ns != 0:
            dash.add_metric("Worst Slack",   f"{m.sta.slack_ns:.3f} ns")
            dash.add_metric("Max Freq",      f"{m.sta.max_frequency_mhz:.1f} MHz")
        if m.lec.status not in ("UNKNOWN", "SKIP"):
            dash.add_metric("LEC",           m.lec.status)
        if m.sta.gls_status not in ("UNKNOWN",):
            dash.add_metric("GLS",           m.sta.gls_status)
        if m.formal.status == "PASS":
            dash.add_metric("Proof Method",  m.formal.proof_method)
        dash.print()

        report = self._save_report()
        if self.verbose:
            print(f"  {C.info('📊 Full report:')} {report}")

        # Failures
        failed = [k for k, v in results.items() if v == "FAIL"]
        if failed:
            print(f"\n  {C.err('❌ FAILED pillars:')} {', '.join(failed)}")
        else:
            print(f"\n  {C.ok('✓ All pillars passed or skipped')}")

        return results

    # ── Clean ─────────────────────────────────────────────────────────────────

    def clean(self):
        print(f"\n  {C.hdr('━━━ CLEAN')}  {C.dim(self.top)}")
        for t in (self.build_dir, self.log_dir):
            if t.exists():
                shutil.rmtree(t)
                print(f"  {C.warn('🗑')}  Removed {t.relative_to(self.root)}")
        sby_work = self.verif_dir / self.top
        if sby_work.exists():
            shutil.rmtree(sby_work)
            print(f"  {C.warn('🗑')}  Removed {sby_work.relative_to(self.root)}")
        print(f"  {C.ok('✓ Clean complete')} for {self.top}")

    # ── Orchestration ─────────────────────────────────────────────────────────

    def run_all(self, coverage_threshold: int = 0, coverage_toggle_threshold: int = 0,
                formal_depth: int = 0,
                force: bool = False, pdk: str = 'auto',
                ip_path: Optional[str] = None) -> Dict[str, str]:
        """Orchestrate all 8 pillars in two dependency waves via GNU parallel.

        Wave 1 (independent): P1 P2 P3 P4 P6
        Wave 2 (depend on W1 outputs): P5 P7 P8

        GNU parallel --group serializes each job's stdout/stderr atomically so
        output never interleaves. -j3 caps RAM-intensive tool concurrency.
        Falls back to sequential if GNU parallel is not on PATH.
        """
        results: Dict[str, str] = {}
        has_parallel = bool(shutil.which("parallel"))
        jobs = 2  # 12 GB RAM ceiling — Yosys/Verilator each pull 2-4 GB; -j3 risks OOM

        # Build the base argument string for child invocations
        script = Path(__file__).resolve()
        base = f"{sys.executable} {script} --top {self.top} --parallel-child"
        if pdk != 'auto':
            base += f" --pdk {pdk}"
        if ip_path:
            base += f" --ip-path {ip_path}"
        if force:
            base += " --force"
        if formal_depth > 0:
            base += f" --formal-depth {formal_depth}"
        if self.params:
            params_str = ",".join(f"{k}={v}" for k, v in self.params.items())
            base += f" --params {params_str}"

        _STEP_NUM = {
            'lint':1,'formal':2,'functional':3,'sim':4,
            'coverage':5,'synth':6,'lec':7,'sta':8,'upf':9,
        }

        def _run_wave(steps: List[str], label: str):
            labels = " ".join(f"P{_STEP_NUM.get(s, '?')}" for s in steps)
            print(f"\n  {C.info(f'⚡ {label}')}  {C.dim(f'{label} — {len(steps)} pillars in parallel...')}")

            if has_parallel:
                cmds = []
                for step in steps:
                    cmd = f"{base} --step {step}"
                    if step == "coverage" and coverage_threshold:
                        cmd += f" --coverage-threshold {coverage_threshold}"
                    if step == "coverage" and coverage_toggle_threshold:
                        cmd += f" --coverage-toggle-threshold {coverage_toggle_threshold}"
                    cmds.append(cmd)
                # Feed one command per line to parallel via stdin
                # --group: buffer each job's output, print atomically on completion
                # -j{jobs}: max concurrent jobs
                parallel_input = "\n".join(cmds)
                subprocess.run(
                    f"parallel --group -j{jobs}",
                    input=parallel_input, text=True, shell=True, cwd=self.root
                )
            else:
                # Fallback: sequential in-process (no parallelism)
                seq_map = {
                    "lint":       lambda: p1_lint.run(self),
                    "formal":     lambda: p2_formal.run(self, formal_depth=formal_depth),
                    "functional": lambda: p3_functional.run(self),
                    "sim":        lambda: p4_sim.run(self),
                    "coverage":   lambda: p5_coverage.run(self, threshold=coverage_threshold,
                                                           toggle_threshold=coverage_toggle_threshold),
                    "synth":      lambda: p6_synth.run(self),
                    "lec":        lambda: p7_lec.run(self),
                    "sta":        lambda: p8_sta_gls.run(self),
                    "upf":        lambda: p9_upf.run(self),
                }
                for step in steps:
                    results[step] = seq_map[step]()
                return  # metrics already in self.all_metrics; no files to read

            # Read per-step result files written by child processes
            for step in steps:
                r = self._load_step_result(step)
                if r:
                    status, metrics = r
                    results[step] = status
                    self._merge_step_metrics(step, metrics)
                else:
                    # Child crashed before writing result — recover from log
                    status = self._recover_status_from_log(step)
                    results[step] = status
                    print(f"  {C.warn(f'⚠ {step}: result file missing — recovered {status} from log')}")

        _run_wave(["lint", "formal", "functional", "sim", "synth"], "Wave 1")
        _run_wave(["coverage", "lec", "sta", "upf"],               "Wave 2")
        return results

    def run_step(self, step: str, coverage_threshold: int = 0,
                coverage_toggle_threshold: int = 0,
                formal_depth: int = 0,
                force: bool = False, pdk: str = 'auto',
                ip_path: Optional[str] = None) -> Dict[str, str]:
        single = {
            "lint":       lambda: p1_lint.run(self),
            "formal":     lambda: p2_formal.run(self, formal_depth=formal_depth),
            "functional": lambda: p3_functional.run(self),
            "sim":        lambda: p4_sim.run(self),
            "coverage":   lambda: p5_coverage.run(self, threshold=coverage_threshold,
                                                   toggle_threshold=coverage_toggle_threshold),
            "synth":      lambda: p6_synth.run(self),
            "lec":        lambda: p7_lec.run(self),
            "sta":        lambda: p8_sta_gls.run(self),
            "upf":        lambda: p9_upf.run(self),
        }
        if step == "all":
            results = self.run_all(coverage_threshold=coverage_threshold,
                                   coverage_toggle_threshold=coverage_toggle_threshold,
                                   formal_depth=formal_depth,
                                   force=force, pdk=pdk, ip_path=ip_path)
        elif step == "clean":
            self.clean()
            return {}
        elif step == "history":
            self.print_history()
            return {}
        elif step == "timing-trend":
            self.print_timing_trend()
            return {}
        elif step in single:
            result = single[step]()
            results = {step: result}
        else:
            print(f"Unknown step: {step}")
            sys.exit(1)

        self._append_history(results)
        self.print_summary(results)
        return results


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Silicon Portfolio — Hardware Verification Pillars",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Steps:  lint | formal | functional | sim | coverage | synth | lec | sta | all | clean | history
PDKs:   --pdk sky130 | nangate | auto  (auto: prefers sky130)
        """
    )
    parser.add_argument("--top",      required=True, help="Top-level module name")
    parser.add_argument("--step",
                        choices=["lint","formal","functional","sim",
                                 "coverage","synth","lec","sta","upf",
                                 "all","clean","history","timing-trend"],
                        default="all")
    parser.add_argument("--pdk",      choices=["sky130","nangate","auto"], default="auto",
                        help="PDK for STA corner sweep (default: auto)")
    parser.add_argument("--ip-path",  default=None,
                        help="Override IP path relative to repo root "
                             "(e.g. ip_analog/custom_cells)")
    parser.add_argument("--coverage-threshold", type=int, default=0, metavar="PCT",
                        help="Minimum line coverage %% — Pillar 5 FAILS below this (0=advisory)")
    parser.add_argument("--coverage-toggle-threshold", type=int, default=0, metavar="PCT",
                        help="Minimum toggle coverage %% — Pillar 5 FAILS below this (0=advisory)")
    parser.add_argument("--formal-depth", type=int, default=0, metavar="N",
                        help="Override k-induction depth in .sby (0=use .sby value)")
    parser.add_argument("--params", default="", metavar="KEY=VAL,...",
                        help="RTL parameter overrides, e.g. WIDTH=8,DEPTH=16 "
                             "(passed as Verilator -G and SBY chparam)")
    parser.add_argument("--force",    action="store_true",
                        help="Ignore cached checkpoints and re-run")
    parser.add_argument("-v", "--verbose", action="store_true")
    parser.add_argument("--parallel-child", action="store_true",
                        help=argparse.SUPPRESS)  # internal: run by GNU parallel

    args = parser.parse_args()
    flow = PillarFlow(args.top, verbose=args.verbose, pdk=args.pdk,
                      ip_path=args.ip_path, params=args.params)

    if args.force:
        flow.state.pop(args.top, None)
        print(f"  {C.warn('⚠ --force: all checkpoints cleared — full re-run (slow on low-RAM servers)')}")

    if args.parallel_child:
        # Child mode: run exactly one step, write result file, exit.
        # Output goes directly to stdout — GNU parallel captures and serializes it.
        single = {
            "lint":       lambda: p1_lint.run(flow),
            "formal":     lambda: p2_formal.run(flow, formal_depth=args.formal_depth),
            "upf":        lambda: p9_upf.run(flow),
            "functional": lambda: p3_functional.run(flow),
            "sim":        lambda: p4_sim.run(flow),
            "coverage":   lambda: p5_coverage.run(flow, threshold=args.coverage_threshold,
                                                   toggle_threshold=args.coverage_toggle_threshold),
            "synth":      lambda: p6_synth.run(flow),
            "lec":        lambda: p7_lec.run(flow),
            "sta":        lambda: p8_sta_gls.run(flow),
        }
        if args.step not in single:
            sys.exit(1)
        status = single[args.step]()
        flow._save_step_result(args.step, status)
        sys.exit(0 if status != "FAIL" else 1)

    results = flow.run_step(args.step, coverage_threshold=args.coverage_threshold,
                            coverage_toggle_threshold=args.coverage_toggle_threshold,
                            formal_depth=args.formal_depth,
                            force=args.force, pdk=args.pdk, ip_path=args.ip_path)

    # Exit 1 if any pillar failed (but only after ALL pillars ran)
    if any(v == "FAIL" for v in results.values()):
        sys.exit(1)
