#!/usr/bin/env bash
set -e

# ==============================================================================
# Configuration & Paths
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VENV_PATH="$HOME/eda/librelane/.venv"
SRC_DIR="$SCRIPT_DIR/src/rtl"
INCLUDE_DIR="$SRC_DIR/include"
BUILD_DIR="$REPO_ROOT/build/test"
OUT_VERILOG="$BUILD_DIR/gpu_asic_converted.v"
CONFIG_FILE="$SCRIPT_DIR/flow/config.yaml"

# Pre-built OpenRAM sky130 macros (gds/lef/lib). Copied into flow/macros/ (gitignored) because the
# dockerized flow only sees the design directory. Override with SRAM_MACRO_DIR=...
SRAM_NAME="sky130_sram_2kbyte_1rw1r_32x512_8"
SRAM_MACRO_DIR="${SRAM_MACRO_DIR:-$HOME/Projects/sky130_sram_macros}"
MACRO_DST="$SCRIPT_DIR/flow/macros"

# Colors for terminal output
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ==============================================================================
# CLI Argument Parsing
# ==============================================================================
STAGE_TARGET=""
AUDIT_ONLY=0

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -f|--floorplan) STAGE_TARGET="--to OpenROAD.Floorplan" ;;
        -r|--route)     STAGE_TARGET="--to OpenROAD.DetailedRouting" ;;
        -a|--audit)     AUDIT_ONLY=1 ;;
        -R|--resume-route) STAGE_TARGET="--last-run --from OpenROAD.GlobalRouting" ;;
        --clean)
            echo -e "${YELLOW}[CLEAN] Removing previous build & run artifacts...${NC}"
            rm -rf "$BUILD_DIR" "$SCRIPT_DIR/flow/runs"
            echo -e "${GREEN}[CLEAN] Done.${NC}"
            exit 0
            ;;
        -h|--help)
            echo "Usage: ./run_asic.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  (no args)       Run full flow all the way to GDSII layout"
            echo "  -f, --floorplan Stop after OpenROAD Floorplan"
            echo "  -r, --route     Stop after OpenROAD Detailed Routing"
            echo "  -a, --audit     Run only sv2v and Yosys synthesis check"
            echo "  -R, --resume-route  Re-run from Global Routing in the most recent run dir"
            echo "  --clean         Remove build/ and runs/ directories"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
    shift
done

# ==============================================================================
# 1. Environment & Prerequisite Checks
# ==============================================================================
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}              mahi-gpu ASIC Flow Automation                     ${NC}"
echo -e "${CYAN}================================================================${NC}"

if [ ! -f "$VENV_PATH/bin/activate" ]; then
    echo -e "${RED}[ERROR] Virtualenv not found at $VENV_PATH${NC}"
    exit 1
fi

if ! command -v sv2v &> /dev/null; then
    echo -e "${RED}[ERROR] sv2v is not installed or not in PATH.${NC}"
    exit 1
fi

if ! command -v yosys &> /dev/null; then
    echo -e "${RED}[ERROR] yosys is not installed or not in PATH.${NC}"
    exit 1
fi

mkdir -p "$BUILD_DIR" "$MACRO_DST"

for ext in gds lef; do
    if [ ! -f "$MACRO_DST/$SRAM_NAME.$ext" ]; then
        SRC="$SRAM_MACRO_DIR/$SRAM_NAME/$SRAM_NAME.$ext"
        [ -f "$SRC" ] || { echo -e "${RED}[ERROR] missing $SRC (set SRAM_MACRO_DIR)${NC}"; exit 1; }
        cp "$SRC" "$MACRO_DST/"
    fi
done
if [ ! -f "$MACRO_DST/${SRAM_NAME}_TT_1p8V_25C.lib" ]; then
    cp "$SRAM_MACRO_DIR/$SRAM_NAME/${SRAM_NAME}_TT_1p8V_25C.lib" "$MACRO_DST/"
fi

# ==============================================================================
# 2. Step 1: SystemVerilog to Verilog (sv2v)
# ==============================================================================
echo -e "\n${YELLOW}>>> [1/3] Running sv2v conversion (Profile: TARGET_ASIC, SRAM macros)...${NC}"

sv2v -DSYNTHESIS -DTARGET_ASIC=1 -DMAHI_SRAM_MACRO=1 \
  -I "$INCLUDE_DIR" \
  "$INCLUDE_DIR/gpu_pkg.sv" \
  "$SRC_DIR"/*.sv \
  -w "$OUT_VERILOG"

echo -e "${GREEN}[PASS] Converted netlist created at:${NC} $OUT_VERILOG"

# ==============================================================================
# 3. Step 2: Yosys Gate & Latch Audit
# ==============================================================================
echo -e "\n${YELLOW}>>> [2/3] Running fast Yosys synthesis & latch check...${NC}"

yosys -q -p "
  read_liberty -lib $MACRO_DST/${SRAM_NAME}_TT_1p8V_25C.lib;
  read_verilog $OUT_VERILOG;
  hierarchy -check -top gpu_asic_top;
  proc; opt; memory; opt; fsm; opt;
  techmap; opt;
  stat;
  select -assert-none t:\$_DLATCH_*;
"

echo -e "${GREEN}[PASS] Zero latches detected. Hierarchy and syntax verified.${NC}"

if [ "$AUDIT_ONLY" -eq 1 ]; then
    echo -e "\n${GREEN}[DONE] Audit-only complete.${NC}"
    exit 0
fi

# ==============================================================================
# 4. Step 3: Run LibreLane Flow
# ==============================================================================
echo -e "\n${YELLOW}>>> [3/3] Activating LibreLane virtual environment & starting flow...${NC}"

# Source the virtualenv
# shellcheck source=/dev/null
source "$VENV_PATH/bin/activate"

LIBRELANE_CMD="librelane --dockerized $STAGE_TARGET $CONFIG_FILE"
echo -e "${CYAN}Executing:${NC} $LIBRELANE_CMD\n"

# Run LibreLane from the ASIC directory
(cd "$SCRIPT_DIR" && $LIBRELANE_CMD)

# ==============================================================================
# 5. Summary & Post-Run Metrics Report
# ==============================================================================
LATEST_RUN=$(ls -td "$SCRIPT_DIR/flow/runs"/RUN_* 2>/dev/null | head -n 1)

if [ -n "$LATEST_RUN" ]; then
    echo -e "\n${CYAN}================================================================${NC}"
    echo -e "${GREEN}Flow completed successfully!${NC}"
    echo -e "Run Directory: ${YELLOW}$LATEST_RUN${NC}"
    
    METRICS_FILE="$LATEST_RUN/final/metrics.json"
    if [ -f "$METRICS_FILE" ]; then
        echo -e "\n${CYAN}Key Metrics Summary:${NC}"
        python3 -c "
import json
try:
    with open('$METRICS_FILE') as f:
        m = json.load(f)
    keys = [
        'design__instance__count', 
        'design__instance__area', 
        'design__die__bbox', 
        'timing__setup__ws', 
        'timing__hold__ws', 
        'route__drc_errors'
    ]
    for k in keys:
        if k in m:
            print(f'  {k:30}: {m[k]}')
except Exception as e:
    pass
"
    fi

    # Check if GDS layout was generated
    GDS_FILE=$(find "$LATEST_RUN/final" -name "*.gds" 2>/dev/null | head -n 1)
    if [ -n "$GDS_FILE" ]; then
        echo -e "\n${GREEN}[GDSII GENERATED]${NC} $GDS_FILE"
        echo -e "To view layout: ${YELLOW}klayout $GDS_FILE${NC}"
    else
        DEF_FILE=$(find "$LATEST_RUN/final" -name "*.def" 2>/dev/null | head -n 1)
        if [ -n "$DEF_FILE" ]; then
            echo -e "\n${YELLOW}[LAYOUT DEF]${NC} $DEF_FILE"
            echo -e "To view floorplan: ${YELLOW}klayout $DEF_FILE${NC}"
        fi
    fi
    echo -e "${CYAN}================================================================${NC}"
fi
