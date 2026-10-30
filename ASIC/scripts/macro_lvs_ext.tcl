# Transistor-level extraction of the OpenRAM macro GDS (recipe from the macro's own run_ext.sh).
# Env: MACRO_GDS, MACRO_CELL, OUT_DIR. Writes $OUT_DIR/$MACRO_CELL.spice. Used by `make macro-lvs`.
drc off
gds warning default
gds flatten true
gds ordering true
gds readonly true
gds read $env(MACRO_GDS)
load $env(MACRO_CELL)
cellname delete \(UNNAMED\)
cd $env(OUT_DIR)
port makeall
extract unique all
extract style ngspice(si)
extract all
ext2spice hierarchy on
ext2spice format ngspice
ext2spice cthresh infinite
ext2spice rthresh infinite
ext2spice renumber off
ext2spice scale off
ext2spice blackbox on
ext2spice subcircuit top on
ext2spice global off
ext2spice -o $env(OUT_DIR)/$env(MACRO_CELL).spice $env(MACRO_CELL)
puts "MACRO_EXT_DONE"
quit -noprompt
