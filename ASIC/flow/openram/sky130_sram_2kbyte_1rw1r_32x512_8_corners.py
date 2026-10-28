"""
OpenRAM config: re-characterize sky130_sram_2kbyte_1rw1r_32x512_8 at the three PVT corners the flow analyses.

Same macro as OpenRAM's macros/sram_configs/sky130_sram_2kbyte_1rw1r_32x512_8.py (32 bits x 512 words, byte write, 1rw+1r ports), but:
  * the shipped config sets nominal_corner_only = True, which is why only the TT_1p8V_25C liberty exists;
  * here the corners are the ones LibreLane's STA uses: TT 1.80 V 25 C, SS 1.60 V 100 C, FF 1.95 V -40 C;
  * netlist_only: the layout (GDS/LEF) is not regenerated, only the SPICE netlist is simulated.
Run with scripts/openram_corners.sh.
"""
import os

word_size = 32
num_words = 512
write_size = 8
num_rw_ports = 1
num_r_ports = 1
num_w_ports = 0

tech_name = "sky130"
nominal_corner_only = False
_ALL = {"TT": ("TT", 1.8, 25), "SS": ("SS", 1.6, 100), "FF": ("FF", 1.95, -40)}
# OPENRAM_CORNERS="TT SS FF" (default) or any subset: the corners are independent and each full-array simulation takes ~20 min,
# so scripts/openram_corners.sh --parallel runs one OpenRAM process per corner.
use_specified_corners = [_ALL[c] for c in os.environ.get("OPENRAM_CORNERS", "TT SS FF").split()]
# The sky130 tech file has no "fet_models" entry, which OpenRAM looks up to fill these lists when nominal_corner_only is False;
# giving them explicitly avoids that. The models themselves come from tech.spice["fet_libraries"] (.lib tt / ss / ff of sky130.lib.spice).
process_corners = ["TT", "SS", "FF"]
supply_voltages = [1.6, 1.8, 1.95]
temperatures = [-40, 25, 100]

route_supplies = "ring"
uniquify = True
check_lvsdrc = False
netlist_only = True
analytical_delay = False
use_nix = False   # tools (ngspice) are provided by scripts/openram_corners.sh, do not bootstrap a Nix toolchain

output_name = "sky130_sram_2kbyte_1rw1r_32x512_8"
output_path = os.environ.get("OPENRAM_OUT", "/tmp/openram_out")
