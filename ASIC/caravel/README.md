# Caravel integration (mini profile)

The chip is a Caravel user project: `user_project_wrapper` (2920 x 3520 um, fixed pins) instantiates `gpu_caravel_top`
(`src/rtl/gpu_caravel_top.sv`), which is `gpu_asic_top` plus Caravel's port names and tie-offs. The wrapper is hardened
**flat** by this repository's flow (GPU logic and the three SRAM macros placed directly in the wrapper). Inside a met1-met4
sub-macro, as the template's macro-first flow would need, the power grid cannot reach the SRAMs' met4 power pins; this was
found in a floorplan trial (`PDN-0232`/`PDN-0233`).
This directory holds the wrapper RTL and `defines.v` from [chipfoundry/caravel_user_project](https://github.com/chipfoundry/caravel_user_project),
pinned in `scripts/caravel_setup.sh` (commit `b510613`, MPW_TAG CC2509); the fixed pin DEF and Caravel's SDC are in `flow/caravel/`.

| Signal | Connection |
|---|---|
| `wb_clk_i`, `wb_rst_i` | GPU clock and reset (one domain with the management Wishbone). The GPU is closed at 40 ns: keep the Caravel core clock at or below 25 MHz. |
| `wbs_*` | GPU Wishbone slave; register and memory map at `0x3000_0000` as in `docs/` |
| `user_irq[0]` / `[1]` / `[2]` | done / fault (STATUS[4]) / 0 |
| `io_oeb` / `io_out` / `la_data_out` | tied to 1 / 0 / 0 in `gpu_caravel_top` |
| `la_data_in`, `la_oenb`, `io_in`, `analog_io`, `user_clock2` | unused |

## Flow
1. Harden the wrapper: `MINI=1 CARAVEL=1 bash ./run_asic.sh`. The config is derived from the mini flow config by
   `scripts/caravel_config.py`: top `user_project_wrapper` clocked by `wb_clk_i`, die 2920 x 3520, pins from the template DEF,
   the four power domains with the template's core ring and straps, Caravel's SDC (`flow/caravel/user_project_wrapper.sdc`),
   and the same repair and signoff settings as the mini layout.
2. `scripts/caravel_setup.sh flow/runs/caravel_<tag>` installs the wrapper RTL, GPU RTL, SRAM model and hardened views in the template checkout.
3. In the checkout: Caravel-level simulation and the shuttle precheck.

`make MINI=1 top-caravel` runs the chip regression through `gpu_caravel_top` and checks the tie-offs every cycle.

## Open decision
The template pins ChipFoundry's LibreLane fork (`CI2511`) and open_pdks `3e0e31dc`; this repository's flow uses LibreLane 3.0.16 and
open_pdks `8afc8346`. The final macro and wrapper should be built with the shuttle's versions.
