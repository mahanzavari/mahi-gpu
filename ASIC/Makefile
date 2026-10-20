# =============================================================================
# ASIC/Makefile — Profile-switched build (ASIC dir only, repo root untouched)
#   make sim                -> full 32-bit sim profile (default)
#   make sim PROFILE=asic   -> 1 core / 2 warps / 12-bit PMEM / 14-bit DMEM
#   make sim PROFILE=fpga   -> 2 cores / 4 warps / 16-bit addrs
#   make convert-asic       -> sv2v Verilog for LibreLane / Yosys
# =============================================================================
PROFILE ?= sim

ifeq ($(PROFILE),asic)
    C_FLAGS += -DTARGET_ASIC=1
    SV2V_FLAGS += -DTARGET_ASIC=1
else ifeq ($(PROFILE),fpga)
    C_FLAGS += -DTARGET_FPGA=1
    SV2V_FLAGS += -DTARGET_FPGA=1
endif

RTL_PKG   := src/rtl/include/gpu_pkg.sv
RTL_F     := rtl.f
TB_MATMUL := src/tb/kernels/tb_matmul.sv

RTL_SOURCES := $(RTL_PKG) \
  src/rtl/dispatch.sv src/rtl/fetcher.sv src/rtl/decoder.sv src/rtl/registers.sv \
  src/rtl/alu.sv src/rtl/pc.sv src/rtl/lsu.sv src/rtl/scheduler.sv src/rtl/shared_mem.sv \
  src/rtl/dcache.sv src/rtl/icache.sv src/rtl/l2_cache.sv src/rtl/victim_write_buffer.sv \
  src/rtl/controller.sv src/rtl/dcr.sv src/rtl/core_pmu.sv src/rtl/fp32_fma.sv \
  src/rtl/core.sv src/rtl/gpu.sv

.PHONY: sim sim-filelist convert-asic convert-asic-filelist lint-asic unit-alu verify-asic verify-asic-trace

# 1. RTL Simulation (gpu_pkg.sv FIRST so types/constants elaborate)
sim:
	mkdir -p build
	iverilog $(C_FLAGS) -g2012 \
	  $(RTL_PKG) \
	  src/rtl/dispatch.sv \
	  src/rtl/fetcher.sv \
	  src/rtl/decoder.sv \
	  src/rtl/registers.sv \
	  src/rtl/alu.sv \
	  src/rtl/pc.sv \
	  src/rtl/lsu.sv \
	  src/rtl/scheduler.sv \
	  src/rtl/shared_mem.sv \
	  src/rtl/dcache.sv \
	  src/rtl/icache.sv \
	  src/rtl/l2_cache.sv \
	  src/rtl/victim_write_buffer.sv \
	  src/rtl/controller.sv \
	  src/rtl/dcr.sv \
	  src/rtl/core_pmu.sv \
	  src/rtl/core.sv \
	  src/rtl/gpu.sv \
	  $(TB_MATMUL) -o build/sim.out
	vvp build/sim.out

# 1b. Same sim via canonical filelist (Bug 2: order enforced by rtl.f)
sim-filelist:
	mkdir -p build
	iverilog $(C_FLAGS) -g2012 -c $(RTL_F) $(TB_MATMUL) -o build/sim.out
	vvp build/sim.out

# 5. Behavioral verification (Verilator, ASIC profile): NZP branch + nested
#    CALL/RET regression. This is the test that caught the pc.sv dead-logic
#    bug introduced during the ASIC port.
VERIF_TB := src/tb/ISA/tb_asic_call_ret_branch.sv
verify-asic:
	mkdir -p build/verilator
	verilator --binary --timing -DTARGET_ASIC=1 \
	  -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-PINMISSING \
	  --top-module tb_asic_call_ret_branch -Mdir build/verilator \
	  $(RTL_SOURCES) $(VERIF_TB) -o verify_asic
	./build/verilator/verify_asic

# Same test with MEM_TRACE (icache miss/fill + dmem write logging) for debugging.
verify-asic-trace:
	mkdir -p build/verilator
	verilator --binary --timing -DTARGET_ASIC=1 -DMEM_TRACE=1 \
	  -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-PINMISSING \
	  --top-module tb_asic_call_ret_branch -Mdir build/verilator \
	  $(RTL_SOURCES) $(VERIF_TB) -o verify_asic_trace
	./build/verilator/verify_asic_trace

# 3. Quick syntax lint of the package under each profile
lint-asic:
	iverilog -g2012 -o /dev/null $(RTL_PKG)
	iverilog -g2012 -DTARGET_ASIC=1 -o /dev/null $(RTL_PKG)
	iverilog -g2012 -DTARGET_FPGA=1 -o /dev/null $(RTL_PKG)
	@echo "gpu_pkg.sv OK (sim/asic/fpga)"

# 4. Standalone leaf unit-sim example (Bug 2: package must be on cmdline)
#   make unit-alu TB=src/tb/compute/tb_alu.sv
unit-alu:
	mkdir -p build
	iverilog -g2012 $(RTL_PKG) src/rtl/alu.sv $(TB) -o build/alu.out
	vvp build/alu.out

# 2. SV2V Conversion for LibreLane / Yosys
# Note: Always pass gpu_pkg.sv FIRST so sv2v elaborates types and constants!
convert-asic:
	mkdir -p build/asic
	sv2v $(SV2V_FLAGS) -DTARGET_ASIC=1 \
	  -I src/rtl/include \
	  $(RTL_PKG) \
	  src/rtl/dispatch.sv \
	  src/rtl/fetcher.sv \
	  src/rtl/decoder.sv \
	  src/rtl/registers.sv \
	  src/rtl/alu.sv \
	  src/rtl/pc.sv \
	  src/rtl/lsu.sv \
	  src/rtl/scheduler.sv \
	  src/rtl/shared_mem.sv \
	  src/rtl/dcache.sv \
	  src/rtl/icache.sv \
	  src/rtl/l2_cache.sv \
	  src/rtl/victim_write_buffer.sv \
	  src/rtl/controller.sv \
	  src/rtl/dcr.sv \
	  src/rtl/core_pmu.sv \
	  src/rtl/core.sv \
	  src/rtl/gpu.sv \
	  src/rtl/gpu_axi4_adaptor.sv \
	  src/rtl/axi4_adaptor.sv \
	  src/rtl/fp32_fma.sv \
	  -w build/asic/gpu_asic.v

# 3. Quick syntax lint of the package under each profile
lint-asic:
	iverilog -g2012 -o /dev/null $(RTL_PKG)
	iverilog -g2012 -DTARGET_ASIC=1 -o /dev/null $(RTL_PKG)
	iverilog -g2012 -DTARGET_FPGA=1 -o /dev/null $(RTL_PKG)
	@echo "gpu_pkg.sv OK (sim/asic/fpga)"
