# Magic drc(full) on a standalone macro GDS, same settings as the flow's Magic.DRC step.
# env: MACRO_GDS (path), MACRO_CELL (top cell), OUT (report path). Run by `make macro-drc`.
crashbackups disable
locking disable
units internal
gds noduplicates true
gds readonly true
gds read $::env(MACRO_GDS)
set oscale [cif scale out]
magic::suspendall
load $::env(MACRO_CELL)
select top cell
drc euclidean on
drc style drc(full)
drc check
set drcresult [drc listall why]
set fout [open $::env(OUT) w]
set count 0
foreach {errtype coordlist} $drcresult {
    puts $fout $errtype
    foreach coord $coordlist {
        puts $fout [format " %.3fum %.3fum %.3fum %.3fum" [expr {$oscale*[lindex $coord 0]}] [expr {$oscale*[lindex $coord 1]}] [expr {$oscale*[lindex $coord 2]}] [expr {$oscale*[lindex $coord 3]}]]
        incr count
    }
}
puts $fout "COUNT: $count"
close $fout
puts "MACRO_DRC_COUNT: $count"
exit
