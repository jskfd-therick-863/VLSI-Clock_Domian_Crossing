# H1.3 - Clock Calculator
# Usage:
#   tclsh clock_calculator.tcl <dataset_file>

if {$argc != 1} {
    puts "Usage: tclsh clock_calculator.tcl <dataset_file>"
    exit 1
}

set filename [lindex $argv 0]

if {![file exists $filename]} {
    puts "ERROR: File not found: $filename"
    exit 1
}

set clocks {}

set fp [open $filename r]

while {[gets $fp line] >= 0} {
    set line [string trim $line]

    if {$line eq ""} {
        continue
    }

    set fields [split $line]

    if {[llength $fields] < 2} {
        continue
    }

    set name [lindex $fields 0]
    set freq [lindex $fields 1]

    if {![string is double -strict $freq]} {
        continue
    }

    if {$freq <= 0} {
        continue
    }

    # Period in ns = 1000 / frequency in MHz
    set period [expr {1000.0 / $freq}]

    lappend clocks [list $freq $name $period]
}

close $fp

# Sort from fastest to slowest clock
set clocks [lsort -real -decreasing -index 0 $clocks]

puts "===== CLOCK CALCULATOR ====="
puts [format "%-12s %-17s %s" "Clock" "Frequency(MHz)" "Period(ns)"]
puts "------------------------------------------"

foreach clock $clocks {
    set freq   [lindex $clock 0]
    set name   [lindex $clock 1]
    set period [lindex $clock 2]

    puts [format "%-12s %-17.2f %.3f" $name $freq $period]
}
