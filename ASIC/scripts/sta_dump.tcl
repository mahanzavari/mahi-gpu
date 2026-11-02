# Timing dump for timing_map.py: one corner of a routed run, read from its final views (netlist, SDC, SPEF).
# Run in the LibreLane image:  openroad -no_init -exit scripts/sta_dump.tcl   with these environment variables:
#   STA_LIBS   liberty files of the corner (standard cells + SRAM macro)
#   STA_NL STA_SDC STA_SPEF   final netlist, SDC and the corner's SPEF
#   STA_DELAY  max (setup) or min (hold);  STA_PATHS  number of full paths to report;  STA_OUT  output directory
foreach lib $::env(STA_LIBS) { read_liberty $lib }
read_verilog $::env(STA_NL)
link_design gpu_asic_top
read_sdc $::env(STA_SDC)
read_spef $::env(STA_SPEF)

set out $::env(STA_OUT)
set delay $::env(STA_DELAY)
report_checks -path_delay $delay -group_path_count $::env(STA_PATHS) -endpoint_path_count 1 \
    -fields {fanout cap slew} -digits 3 > $out/paths_$delay.rpt
# every endpoint's worst slack, one line each
report_checks -path_delay $delay -group_path_count 1000000 -endpoint_path_count 1 -format end -digits 3 > $out/endpoints_$delay.rpt
if { $delay == "max" } {
    report_check_types -max_slew -max_capacitance -max_fanout -violators -digits 3 > $out/violators.rpt
}
