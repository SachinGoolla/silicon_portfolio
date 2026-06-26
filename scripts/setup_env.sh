#!/usr/bin/env bash
# ============================================================
# Silicon Portfolio — One-time shell setup for new engineers
# Run: bash ~/silicon_portfolio/scripts/setup_env.sh
# ============================================================
set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_RC="$HOME/.bashrc"

echo ""
echo "  Silicon Portfolio — Environment Setup"
echo "  ======================================"
echo "  Repo: $REPO"
echo ""

# ── 1. Create .venv if missing ─────────────────────────────
if [ ! -f "$REPO/.venv/bin/activate" ]; then
    echo "  [1/3] Creating Python venv..."
    python3 -m venv "$REPO/.venv"
    "$REPO/.venv/bin/pip" install --quiet "cocotb==2.0.1"
    echo "  [1/3] ✓ .venv created + cocotb 2.0.1 installed"
else
    echo "  [1/3] ✓ .venv already exists"
fi

# ── 2. Inject shell config (idempotent) ───────────────────
MARKER="# SILICON_PORTFOLIO_ENV"
if grep -q "$MARKER" "$SHELL_RC" 2>/dev/null; then
    echo "  [2/3] ✓ Shell config already present in $SHELL_RC"
else
    echo "  [2/3] Writing shell config to $SHELL_RC..."
    cat >> "$SHELL_RC" << SHELLEOF

$MARKER
# Auto-activate silicon_portfolio venv on cd + pillar shortcut
_sp_cd() {
    builtin cd "\$@" || return
    if [[ "\$PWD" == "$REPO"* ]] && [[ -f "$REPO/.venv/bin/activate" ]]; then
        if [[ "\$VIRTUAL_ENV" != "$REPO/.venv" ]]; then
            source "$REPO/.venv/bin/activate"
        fi
    fi
}
alias cd='_sp_cd'
pillar() { "$REPO/.venv/bin/python3" "$REPO/scripts/pillar.py" "\$@"; }
export -f pillar

# Auto-welcome on SSH login if landing in project
if [[ "\$PWD" == "$REPO"* ]] || [[ -z "\$PS1_SILICON_SHOWN" ]]; then
    export PS1_SILICON_SHOWN=1
    bash "$REPO/scripts/welcome.sh" 2>/dev/null || true
fi
SHELLEOF
    echo "  [2/3] ✓ Shell config written"
fi

# ── 3. Source now ─────────────────────────────────────────
echo "  [3/3] Activating for this session..."
source "$REPO/.venv/bin/activate"

echo ""
echo "  ✓ Setup complete. Open a new terminal or run:"
echo "    source ~/.bashrc"
echo ""
bash "$REPO/scripts/welcome.sh"
