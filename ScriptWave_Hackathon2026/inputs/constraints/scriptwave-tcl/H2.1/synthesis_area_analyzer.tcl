# ============================================
# H2.1 - Synthesis Area Analyzer
# ============================================

if {$argc != 1} {
    puts "Usage: tclsh synthesis_area_analyzer.tcl <dataset>"
    exit 1
}

set dataset [lindex $argv 0]

if {![file exists $dataset]} {
    puts "ERROR: Dataset file not found: $dataset"
    exit 1
}

set total_area 0.0
set largest_type ""
set largest_area 0.0

set results {}

set fp [open $dataset r]

puts "===== SYNTHESIS AREA ANALYZER ====="
puts ""

while {[gets $fp line] >= 0} {

    if {[string trim $line] eq ""} {
        continue
    }

    set fields [split $line]

    if {[llength $fields] != 3} {
        puts "WARNING: Skipping malformed line: $line"
        continue
    }

    set cell_type [lindex $fields 0]
    set count     [lindex $fields 1]
    set area_cell [lindex $fields 2]

    set area [expr {$count * $area_cell}]

    set total_area [expr {$total_area + $area}]

    if {$area > $largest_area} {
        set largest_area $area
        set largest_type $cell_type
    }

    lappend results [list $cell_type $count $area_cell $area]
}

close $fp

puts [format "%-12s %10s %15s %15s %12s" \
    "CELL_TYPE" "COUNT" "AREA/CELL" "TOTAL_AREA" "PERCENT"]

puts "----------------------------------------------------------------"

foreach result $results {

    set cell_type [lindex $result 0]
    set count     [lindex $result 1]
    set area_cell [lindex $result 2]
    set area      [lindex $result 3]

    set percent [expr {($area / $total_area) * 100.0}]

    puts [format "%-12s %10d %15.2f %15.2f %11.2f%%" \
        $cell_type $count $area_cell $area $percent]
}

puts "----------------------------------------------------------------"

puts [format "TOTAL AREA: %.2f" $total_area]

puts [format "LARGEST AREA CONTRIBUTOR: %s (%.2f)" \
    $largest_type $largest_area]

puts ""
puts "===== ANALYSIS COMPLETE ====="
