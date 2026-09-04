# ============================================
# H2.3 - Hierarchy Analyzer
# ============================================

if {$argc != 1} {
    puts "Usage: tclsh hierarchy_analyzer.tcl <dataset>"
    exit 1
}

set dataset [lindex $argv 0]

if {![file exists $dataset]} {
    puts "ERROR: Dataset file not found: $dataset"
    exit 1
}

set fp [open $dataset r]

set top_module ""
set modules {}

set total_cells 0
set largest_module ""
set largest_cells 0
set smallest_module ""
set smallest_cells -1

while {[gets $fp line] >= 0} {

    if {[string trim $line] eq ""} {
        continue
    }

    set fields [split $line]

    if {[lindex $fields 0] eq "TOP"} {

        if {[llength $fields] != 2} {
            puts "WARNING: Invalid TOP line: $line"
            continue
        }

        set top_module [lindex $fields 1]
        continue
    }

    if {[lindex $fields 0] eq "MODULE"} {

        if {[llength $fields] != 3} {
            puts "WARNING: Invalid MODULE line: $line"
            continue
        }

        set module_name [lindex $fields 1]
        set cell_count  [lindex $fields 2]

        lappend modules [list $module_name $cell_count]

        set total_cells [expr {$total_cells + $cell_count}]

        if {$cell_count > $largest_cells} {
            set largest_cells $cell_count
            set largest_module $module_name
        }

        if {$smallest_cells == -1 || $cell_count < $smallest_cells} {
            set smallest_cells $cell_count
            set smallest_module $module_name
        }
    }
}

close $fp

puts "===== HIERARCHY ANALYZER ====="
puts ""

puts "TOP MODULE: $top_module"
puts ""

puts [format "%-15s %12s %15s" \
    "MODULE" "CELL_COUNT" "PERCENT"]

puts "--------------------------------------------"

foreach module $modules {

    set module_name [lindex $module 0]
    set cell_count  [lindex $module 1]

    set percent [expr {($cell_count * 100.0) / $total_cells}]

    puts [format "%-15s %12d %14.2f%%" \
        $module_name $cell_count $percent]
}

puts "--------------------------------------------"

puts "TOTAL CELL COUNT: $total_cells"

puts [format "LARGEST MODULE: %s (%d cells)" \
    $largest_module $largest_cells]

puts [format "SMALLEST MODULE: %s (%d cells)" \
    $smallest_module $smallest_cells]

puts ""
puts "===== ANALYSIS COMPLETE ====="
