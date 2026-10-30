#!/usr/bin/env bash
# Re-characterize the OpenRAM SRAM macro at the flow's three PVT corners (see flow/openram/*_corners.py).
#   scripts/openram_corners.sh [extra sram_compiler.py options]       one process, the three corners in series
#   scripts/openram_corners.sh --parallel [extra options]              one process per corner (TT, SS, FF); output in $OPENRAM_OUT/<corner>/
# Needs: an OpenRAM checkout (OPENRAM_SRC, v1.2.50 was used), ngspice on PATH (or NGSPICE_ROOT with an extracted
# rpm tree), a Python with numpy + scikit-learn (OPENRAM_PYTHON), and the sky130A PDK of the version the flow uses (PDK_VER, as in the Makefile).
# Output: $OPENRAM_OUT/*.lib, one liberty file per corner (netlist-only: no layout is generated).
#
# One-time setup this script assumes (everything lives outside the repo, nothing here is installed system-wide):
#   1. OpenRAM v1.2.50:   git clone --depth 1 --branch v1.2.50 https://github.com/VLSIDA/OpenRAM.git      -> $OPENRAM_SRC
#   2. The Cypress SRAM cell library OpenRAM's Makefile pins (vlsida/sky130_fd_bd_sram @ fc63b12): copy cells/*/*.spice
#      into $OPENRAM_SRC/technology/sky130/sp_lib/ (name.spice -> name.sp, the *.base.spice variant wins; skip *.lvs.spice
#      and *.lvs.calibre.spice) and cells/*/*.gds into .../gds_lib/. sky130_fd_sc_hd__dlxtn_1 comes from the PDK's cell library.
#   3. In those sp_lib files rename sky130_fd_pr__special_pfet_pass -> sky130_fd_pr__special_pfet_latch. The PDK keeps the old name
#      only as a legacy alias (its own comment says so) and ngspice 47 cannot resolve the alias; both are the same device.
#   4. ngspice 47: `dnf download ngspice ngspice-codemodel`, then rpm2cpio | cpio -idm into $NGSPICE_ROOT (no root needed).
#   5. A venv with scikit-learn (OpenRAM imports it at start-up): python3 -m venv --system-site-packages $HOME/eda/openram_venv
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENRAM_SRC="${OPENRAM_SRC:-$HOME/eda/openram_src/OpenRAM}"
NGSPICE_ROOT="${NGSPICE_ROOT:-$HOME/eda/ngspice_root}"
PYTHON="${OPENRAM_PYTHON:-$HOME/eda/openram_venv/bin/python}"   # a venv with scikit-learn (OpenRAM imports it at start-up)
PDK_VER="${PDK_VER:-8afc8346a57fe1ab7934ba5a6056ea8b43078e71}"
export PDK_ROOT="$HOME/.ciel/ciel/sky130/versions/$PDK_VER"
export OPENRAM_HOME="$OPENRAM_SRC/compiler" OPENRAM_TECH="$OPENRAM_SRC/technology"
export PYTHONPATH="$OPENRAM_HOME${PYTHONPATH:+:$PYTHONPATH}"
export OPENRAM_OUT="${OPENRAM_OUT:-$HERE/build/openram_corners}"
if [ -d "$NGSPICE_ROOT/usr/bin" ]; then
  export PATH="$NGSPICE_ROOT/usr/bin:$PATH" LD_LIBRARY_PATH="$NGSPICE_ROOT/usr/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export SPICE_LIB_DIR="$NGSPICE_ROOT/usr/lib64/ngspice"
  # the packaged spinit loads the optional XSPICE code models from absolute /usr/lib64 paths; point it at the extracted tree
  mkdir -p "$OPENRAM_OUT/spice_scripts"
  sed "s|/usr/lib64|$NGSPICE_ROOT/usr/lib64|g" "$NGSPICE_ROOT/usr/lib64/ngspice/scripts/spinit" > "$OPENRAM_OUT/spice_scripts/spinit"
  export SPICE_SCRIPTS="$OPENRAM_OUT/spice_scripts"
fi
command -v ngspice >/dev/null || { echo "ngspice not found"; exit 1; }
if [ "${1:-}" = "--parallel" ]; then
  shift
  mkdir -p "$OPENRAM_OUT"
  for c in TT SS FF; do
    OPENRAM_CORNERS="$c" OPENRAM_OUT="$OPENRAM_OUT/$c" "$0" "$@" > "$OPENRAM_OUT/$c.log" 2>&1 &
    echo "started $c (pid $!), log $OPENRAM_OUT/$c.log"
  done
  wait; exit 0
fi
export OPENRAM_TMP="$OPENRAM_OUT/tmp"
mkdir -p "$OPENRAM_OUT" "$OPENRAM_TMP"
cd "$OPENRAM_SRC"
exec "$PYTHON" sram_compiler.py "$HERE/flow/openram/sky130_sram_2kbyte_1rw1r_32x512_8_corners.py" -c "$@"
