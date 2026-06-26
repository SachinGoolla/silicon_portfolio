#!/usr/bin/env bash
# Silicon Portfolio — Welcome banner (runs on SSH login / new terminal)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; NC='\033[0m'

check() { command -v "$1" &>/dev/null && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"; }
ver()   { command -v "$1" &>/dev/null && "$@" 2>/dev/null | head -1 | grep -oP '\d+\.\d+[.\d]*' | head -1 || echo "not found"; }

echo -e ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}⬡  SILICON PORTFOLIO — 8-Pillar RTL Verification${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo -e "${DIM}  $(date '+%A %d %b %Y  %H:%M')  │  $(hostname)  │  $(uname -m)${NC}"
echo ""

# Tool status
printf "  ${BOLD}Tools${NC}   "
printf "Verilator $(check verilator)${DIM}$(ver verilator --version)${NC}  "
printf "Yosys $(check yosys)${DIM}$(ver yosys --version)${NC}  "
printf "SBY $(check sby)${DIM}$(sby --version 2>/dev/null | grep -oP 'v[\d.\-a-z]+' | head -1)${NC}\n"
printf "          "
printf "OpenSTA $(check sta)${DIM}$(ver sta -version)${NC}  "
printf "Icarus $(check iverilog)${DIM}$(ver iverilog -V)${NC}  "
printf "Python $(check python3)${DIM}$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')${NC}\n"

# Venv status
if [[ -n "$VIRTUAL_ENV" ]]; then
    echo -e "  ${BOLD}Venv${NC}    ${GREEN}✓ active${NC} ${DIM}(.venv — cocotb $(python3 -c 'import cocotb; print(cocotb.__version__)' 2>/dev/null || echo "?"))${NC}"
else
    echo -e "  ${BOLD}Venv${NC}    ${YELLOW}⚠ not active${NC} ${DIM}(run: source $REPO/.venv/bin/activate)${NC}"
fi

# Module list
MODS=$(ls "$REPO/ip_digital/common_cells/" 2>/dev/null | tr '\n' '  ' | sed 's/  $//')
echo -e "  ${BOLD}IPs${NC}     ${DIM}${MODS:-none yet}${NC}"
echo ""

echo -e "  ${BOLD}8-Pillar Flow${NC}   ${DIM}🔍P1→🔬P2→✅P3→🎬P4→📈P5→🏗️P6→⚖️P7→⏱️P8${NC}"
echo ""
echo -e "  ${BOLD}Quick commands${NC}"
echo -e "  ${CYAN}pillar --top <module>                    ${NC}${DIM}# run all 8 pillars (~2 min)${NC}"
echo -e "  ${CYAN}pillar --top <module> --step lint        ${NC}${DIM}# P1  lint + CDC/RDC${NC}"
echo -e "  ${CYAN}pillar --top <module> --step formal      ${NC}${DIM}# P2  SymbiYosys k-induction${NC}"
echo -e "  ${CYAN}pillar --top <module> --step functional  ${NC}${DIM}# P3  cocotb / Icarus tests${NC}"
echo -e "  ${CYAN}pillar --top <module> --step sim         ${NC}${DIM}# P4  Verilator binary + VCD${NC}"
echo -e "  ${CYAN}pillar --top <module> --step coverage    ${NC}${DIM}# P5  line/branch coverage${NC}"
echo -e "  ${CYAN}pillar --top <module> --step synth       ${NC}${DIM}# P6  Yosys RTL → gate netlist${NC}"
echo -e "  ${CYAN}pillar --top <module> --step lec         ${NC}${DIM}# P7  RTL↔netlist equivalence${NC}"
echo -e "  ${CYAN}pillar --top <module> --step sta         ${NC}${DIM}# P8  OpenSTA + zero-delay GLS${NC}"
echo -e "  ${CYAN}pillar --top <module> --step history     ${NC}${DIM}# regression trend (all runs)${NC}"
echo -e "  ${CYAN}pillar --top <module> --step clean       ${NC}${DIM}# wipe build/ and logs/${NC}"
echo -e "  ${CYAN}pillar --top <module> --force            ${NC}${DIM}# ignore checkpoints, re-run${NC}"
echo -e "  ${CYAN}pillar --top <module> --coverage-threshold 90  ${NC}${DIM}# P5 hard gate${NC}"
echo ""
echo -e "  ${DIM}New module skeleton:${NC}"
echo -e "  ${DIM}mkdir -p ip_digital/common_cells/<mod>/{rtl,verification,build,logs}${NC}"
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""
