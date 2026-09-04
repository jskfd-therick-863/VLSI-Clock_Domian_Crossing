# ==========================================
# LEVEL 3 - H3.2 CELL-VT ANALYZER
# ==========================================

# Usage:
#   tclsh cell_vt_analyzer.tcl <dataset.txt>

if {$argc != 1} {
    puts "Usage: tclsh cell_vt_analyzer.tcl <dataset.txt>"
    exit 1
}

set input_file [lindex $argv 0]

# Check input file
if {![file exists $input_file]} {
    puts "ERROR: Dataset not found: $input_file"
    exit 1
}

# Initialize counters
set total 0
set lvt 0
set svt 0
set hvt 0

# Open dataset
set fp [open $input_file r]

while {[gets $fp line] >= 0} {

    set line [string trim $line]

    # Ignore blank lines
    if {$line eq ""} {
        continue
    }

    # Expected format:
    # U1 NAND2_LVT
    set fields [split $line]

    if {[llength $fields] < 2} {
        continue
    }

    set instance [lindex $fields 0]
    set cell     [lindex $fields 1]

    incr total

    # Identify Vt type from cell-name suffix
    if {[string match "*_LVT" $cell]} {
        incr lvt
    } elseif {[string match "*_SVT" $cell]} {
        incr svt
    } elseif {[string match "*_HVT" $cell]} {
        incr hvt
    }
}

close $fp

# Check that data was found
if {$total == 0} {
    puts "ERROR: No cells found in dataset"
    exit 1
}

# Calculate percentages
set lvt_pct [expr {100.0 * $lvt / $total}]
set svt_pct [expr {100.0 * $svt / $total}]
set hvt_pct [expr {100.0 * $hvt / $total}]

# Print report
puts "=========================================="
puts "           CELL-VT ANALYZER"
puts "=========================================="
puts [format "TOTAL CELLS : %d" $total]
puts [format "LVT         : %d (%.2f%%)" $lvt $lvt_pct]
puts [format "SVT         : %d (%.2f%%)" $svt $svt_pct]
puts [format "HVT         : %d (%.2f%%)" $hvt $hvt_pct]
puts "------------------------------------------"

# H3.2 requirement:
# Flag excessive LVT usage when LVT exceeds 40%
if {$lvt_pct > 40.0} {
    puts "LVT STATUS  : EXCESSIVE"
    puts "OVERALL     : FAIL"
} else {
    puts "LVT STATUS  : NORMAL"
    puts "OVERALL     : PASS"
}

puts "=========================================="
