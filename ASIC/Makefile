# =============================================================================
# ASIC/Makefile — Profile-switched build + verification entry points
#
#   make verify             -> lint (3 profiles) + unit tests + system tests
#   make lint               -> Verilator -Wall on gpu for sim/asic/fpga profiles
#   make unit               -> all unit tests (src/tb/unit)
#   make unit-pc            -> a single unit test (unit-<name> for tb_<name>.sv)
#   make verify-asic        -> ASIC-profile system test (NZP branch + CALL/RET)
#   make verify-matmul      -> 2-core 5x5 matmul system test
#   make verify-asic-trace  -> same, with MEM_TRACE logging
#   make sim [PROFILE=asic|fpga]  -> iverilog run of tb_matmul
#   make convert-asic       -> sv2v Verilog for LibreLane / Yosys
#
# gpu_pkg.sv MUST be first on every command line (leaf defaults reference it).
# Verilator is the primary simulator; iverilog is kept for `sim` only.
# NOTE: do not use `automatic`/in-loop `int x = ...` scratch vars in TBs --
# iverilog rejects `automatic`, Verilator makes bare ones static (init once).
# Hoist plain `integer`s to module scope and assign with blocking `=`.
# =============================================================================
PROFILE ?= sim

ifeq ($(PROFILE),asic)
    PROFILE_DEF := -DTARGET_ASIC=1
else ifeq ($(PROFILE),fpga)
    PROFILE_DEF := -DTARGET_FPGA=1
else
    PROFILE_DEF :=
endif
C_FLAGS    += $(PROFILE_DEF)
SV2V_FLAGS += $(PROFILE_DEF)

RTL_PKG   := src/rtl/include/gpu_pkg.sv
RTL_F     := rtl.f
TB_MATMUL := src/tb/kernels/tb_matmul.sv

RTL_SOURCES := $(RTL_PKG) \
  src/rtl/dispatch.sv src/rtl/fetcher.sv src/rtl/decoder.sv src/rtl/registers.sv \
  src/rtl/alu.sv src/rtl/pc.sv src/rtl/lsu.sv src/rtl/scheduler.sv src/rtl/shared_mem.sv \
  src/rtl/dcache.sv src/rtl/icache.sv src/rtl/l2_cache.sv src/rtl/victim_write_buffer.sv \
  src/rtl/controller.sv src/rtl/dcr.sv src/rtl/core_pmu.sv src/rtl/fp32_fma.sv \
  src/rtl/core.sv src/rtl/gpu.sv

# Verilator flags shared by all simulations. Width/pin warnings in the RTL are
# baselined (see LINT_WAIVE); simulation builds just don't fail on them.
VL_SIM  := --binary --timing --assert -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-PINMISSING

# SVA checkers (bound, no RTL edits). Checkers + per-module bind files.
SVA_DIR   := src/rtl/sva
SVA_CHK   := $(SVA_DIR)/core_sva.sv $(SVA_DIR)/misc_sva.sv
SVA_BINDS := $(addprefix $(SVA_DIR)/,bind_core.sv bind_pc.sv bind_scheduler.sv bind_lsu.sv \
             bind_fetcher.sv bind_victim_write_buffer.sv)
SVA_ALL   := $(SVA_CHK) $(SVA_BINDS)

# Lint gate: -Wall, with the 10 warning categories present in the baseline
# waived. Any NEW category (LATCH, UNDRIVEN, MULTIDRIVEN, COMBDLY, ...) fails.
LINT_WAIVE := -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-BLKSEQ -Wno-PINMISSING \
              -Wno-PINCONNECTEMPTY -Wno-EOFNEWLINE -Wno-UNUSEDSIGNAL \
              -Wno-UNUSEDPARAM -Wno-CASEINCOMPLETE -Wno-VARHIDDEN

UNIT_TESTS := $(patsubst src/tb/unit/tb_%.sv,%,$(wildcard src/tb/unit/tb_*.sv))

.PHONY: verify lint unit sim sim-filelist verify-asic verify-asic-trace \
        verify-matmul unit-alu-stub convert-asic clean $(addprefix unit-,$(UNIT_TESTS))

verify: lint unit verify-asic verify-matmul
	@echo "== make verify: ALL PASSED =="

# --- Lint -------------------------------------------------------------------
lint:
	@for d in "" "-DTARGET_ASIC=1" "-DTARGET_FPGA=1"; do \
	  echo "lint gpu [$$d]"; \
	  verilator --lint-only -Wall $(LINT_WAIVE) $$d --top-module gpu $(RTL_SOURCES) || exit 1; \
	done
	@echo "lint OK (sim/asic/fpga)"

# --- Unit tests: src/tb/unit/tb_<name>.sv -> `make unit-<name>` ---------------
# Each test lists its DUT sources in UNIT_SRC_<name> (default: rtl/<name>.sv).
UNIT_SRC_pc := src/rtl/pc.sv
UNIT_DEF_alu := -DUSE_COMB_DIV=1
UNIT_SRC_registers := src/rtl/registers.sv
UNIT_SRC_fp32_fma := src/rtl/fp32_fma.sv
UNIT_SRC_decoder := src/rtl/decoder.sv
UNIT_SRC_l2_cache := src/rtl/victim_write_buffer.sv src/rtl/l2_cache.sv
UNIT_SRC_dcache := src/rtl/dcache.sv
UNIT_SVA_pc := $(SVA_DIR)/bind_pc.sv
UNIT_SVA_l2_cache := $(SVA_DIR)/bind_victim_write_buffer.sv

unit: $(addprefix unit-,$(UNIT_TESTS)) unit-alu-stub

# ALU again without USE_COMB_DIV: DIV/MOD must return 0 (documented ASIC stub).
unit-alu-stub:
	@mkdir -p build/unit_alu_stub
	verilator $(VL_SIM) -DTARGET_ASIC=1 --top-module tb_alu -Mdir build/unit_alu_stub \
	  $(RTL_PKG) src/rtl/alu.sv src/tb/unit/tb_alu.sv -o tb_alu >/dev/null
	./build/unit_alu_stub/tb_alu

$(addprefix unit-,$(UNIT_TESTS)): unit-%:
	@mkdir -p build/unit_$*
	verilator $(VL_SIM) -DTARGET_ASIC=1 $(UNIT_DEF_$*) --top-module tb_$* -Mdir build/unit_$* \
	  $(RTL_PKG) $(or $(UNIT_SRC_$*),src/rtl/$*.sv) $(SVA_CHK) $(UNIT_SVA_$*) src/tb/unit/tb_$*.sv -o tb_$* >/dev/null
	./build/unit_$*/tb_$*

# --- System tests -----------------------------------------------------------
VERIF_TB := src/tb/ISA/tb_asic_call_ret_branch.sv
verify-asic:
	mkdir -p build/verilator
	verilator $(VL_SIM) -DTARGET_ASIC=1 \
	  --top-module tb_asic_call_ret_branch -Mdir build/verilator \
	  $(RTL_SOURCES) $(SVA_ALL) $(VERIF_TB) -o verify_asic >/dev/null
	./build/verilator/verify_asic

# 2-core / 32-thread 5x5 matmul (CALL/RET, divergence, LDR/STR, DIV). Needs
# USE_COMB_DIV: the ASIC alu stubs DIV/MOD to 0 otherwise. Self-checking: the
# TB prints "...TESTS PASSED!" only if every result matches, so grep for it.
verify-matmul:
	mkdir -p build/matmul
	verilator $(VL_SIM) -DUSE_COMB_DIV=1 --top-module tb_matmul -Mdir build/matmul \
	  $(RTL_SOURCES) $(SVA_ALL) $(TB_MATMUL) -o matmul >/dev/null
	./build/matmul/matmul | tee build/matmul/run.log | grep -E "FAIL|PASSED|ERROR"
	@grep -q "TESTS PASSED" build/matmul/run.log

# Same test with MEM_TRACE (icache/L2/scheduler/dmem logging) for debugging.
verify-asic-trace:
	mkdir -p build/verilator_trace
	verilator $(VL_SIM) -DTARGET_ASIC=1 -DMEM_TRACE=1 \
	  --top-module tb_asic_call_ret_branch -Mdir build/verilator_trace \
	  $(RTL_SOURCES) $(SVA_ALL) $(VERIF_TB) -o verify_asic_trace >/dev/null
	./build/verilator_trace/verify_asic_trace

# --- iverilog run of tb_matmul (legacy; times out under iverilog even though it
# passes under Verilator -- use `make verify-matmul`)
sim:
	mkdir -p build
	iverilog $(C_FLAGS) -g2012 $(RTL_SOURCES) $(TB_MATMUL) -o build/sim.out
	vvp build/sim.out

sim-filelist:
	mkdir -p build
	iverilog $(C_FLAGS) -g2012 -c $(RTL_F) $(TB_MATMUL) -o build/sim.out
	vvp build/sim.out

# --- SV2V conversion for LibreLane / Yosys ----------------------------------
# gpu_pkg.sv first so sv2v elaborates types and constants.
convert-asic:
	mkdir -p build/asic
	sv2v $(SV2V_FLAGS) -DTARGET_ASIC=1 -I src/rtl/include \
	  $(RTL_SOURCES) src/rtl/gpu_axi4_adaptor.sv src/rtl/axi4_adaptor.sv \
	  -w build/asic/gpu_asic.v

clean:
	rm -rf build
