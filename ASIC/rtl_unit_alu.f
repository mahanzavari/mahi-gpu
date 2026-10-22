# =============================================================================
# ASIC/rtl_unit_alu.f — Minimal filelist for the alu unit testbench (Bug 2).
# Package FIRST, then DUT. Run from ASIC/ as CWD:
#   iverilog -g2012 -c rtl_unit_alu.f src/tb/compute/tb_alu.sv -o build/alu.out
# (replace tb path with your actual alu TB filename)
# =============================================================================
src/rtl/include/gpu_pkg.sv
src/rtl/alu.sv
