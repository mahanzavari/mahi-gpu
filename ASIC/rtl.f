# =============================================================================
# ASIC/rtl.f — Canonical compile order (Bug 2 fix).
# gpu_pkg.sv MUST come first: leaf defaults reference gpu_pkg::... and
# iverilog/sv2v fail with "'gpu_pkg' has not been declared" otherwise.
# Usage:
#   iverilog -g2012 -c ASIC/rtl.f <tb> -o build/sim.out
#   sv2v -DTARGET_ASIC=1 -I ASIC/src/rtl/include -c ASIC/rtl.f -w build/asic/gpu_asic.v
# =============================================================================
src/rtl/include/gpu_pkg.sv
src/rtl/dispatch.sv
src/rtl/fetcher.sv
src/rtl/decoder.sv
src/rtl/registers.sv
src/rtl/alu.sv
src/rtl/pc.sv
src/rtl/lsu.sv
src/rtl/scheduler.sv
src/rtl/shared_mem.sv
src/rtl/dcache.sv
src/rtl/icache.sv
src/rtl/l2_cache.sv
src/rtl/victim_write_buffer.sv
src/rtl/controller.sv
src/rtl/dcr.sv
src/rtl/core_pmu.sv
src/rtl/core.sv
src/rtl/gpu.sv
src/rtl/gpu_axi4_adaptor.sv
src/rtl/axi4_adaptor.sv
src/rtl/fp32_fma.sv
