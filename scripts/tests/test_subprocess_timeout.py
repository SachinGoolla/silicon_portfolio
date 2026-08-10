"""Regression tests for run_with_timeout()'s process-group kill behavior.

The bug this guards: `subprocess.run(cmd, shell=True, timeout=N)` only
signals the immediate shell child. A chain like `sh -c "sby ..."` -> `sby`
-> `yosys-smtbmc` -> `z3` survives the shell's death, gets reparented to
init, and keeps holding RAM -- observed directly on this host (orphaned z3
processes survived 6-39 minutes past their timeout; see project memory
feedback_resource_limits). run_with_timeout() must kill the whole process
group, not just the shell.
"""
import os
import signal
import subprocess
import time

import pytest

from pillars.common import run_with_timeout


def test_normal_command_returns_completed_process():
    result = run_with_timeout("echo hello", timeout=5, capture_output=True, text=True)
    assert result.returncode == 0
    assert "hello" in result.stdout


def test_nonzero_exit_without_check_does_not_raise():
    result = run_with_timeout("exit 3", timeout=5)
    assert result.returncode == 3


def test_check_true_raises_on_nonzero_exit():
    with pytest.raises(subprocess.CalledProcessError):
        run_with_timeout("exit 1", timeout=5, check=True)


def test_timeout_kills_grandchild_process_not_just_shell():
    """Regress the orphaned-z3 bug directly: spawn a shell that forks a
    detached-looking grandchild (via a nested `sh -c`), let the outer call
    time out, then confirm the grandchild's PID is actually dead -- not
    just reparented and still running."""
    marker = "/tmp/rwt_test_child_pid_marker_%d" % os.getpid()
    if os.path.exists(marker):
        os.remove(marker)
    # Outer shell launches a grandchild that records its own PID, then
    # sleeps well past our timeout. If only the outer shell is killed, this
    # grandchild survives (the historical bug).
    cmd = f"sh -c 'echo $$ > {marker}; sleep 30'"
    with pytest.raises(subprocess.TimeoutExpired):
        run_with_timeout(cmd, timeout=1)

    assert os.path.exists(marker), "grandchild never started -- test setup broken"
    grandchild_pid = int(open(marker).read().strip())
    os.remove(marker)

    time.sleep(0.5)  # let SIGKILL propagate
    with pytest.raises(ProcessLookupError):
        os.kill(grandchild_pid, 0)  # signal 0 = existence check only


def test_timeout_expired_output_is_decodable():
    """TimeoutExpired.stdout can be raw bytes -- confirm run_with_timeout's
    re-raised exception carries output that decode_subprocess_output() can
    safely turn into str (see test_log_parsers.py for the decoder tests)."""
    from pillars.common import decode_subprocess_output
    with pytest.raises(subprocess.TimeoutExpired) as exc_info:
        run_with_timeout("echo partial; sleep 5", timeout=0.3, capture_output=True)
    decode_subprocess_output(exc_info.value.stdout)  # must not raise
