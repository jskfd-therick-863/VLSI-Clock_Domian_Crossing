# H2.2 - Synthesis Warning Classifier

if {$argc != 1} {
    puts "Usage: tclsh synthesis_warning_classifier.tcl <logfile>"
    exit 1
}

set logfile [lindex $argv 0]

if {![file exists $logfile]} {
    puts "ERROR: Log file not found: $logfile"
    exit 1
}

set fp [open $logfile r]

array set category_count {}
set warning_count 0
set error_count 0
set total_count 0

while {[gets $fp line] >= 0} {
    if {[string trim $line] eq ""} {
        continue
    }

    set fields [split $line]

    if {[llength $fields] < 3} {
        puts "WARNING: Skipping malformed line: $line"
        continue
    }

    set severity [lindex $fields 0]
    set category [lindex $fields 1]
    set signal   [lindex $fields 2]

    incr total_count

    if {$severity eq "WARNING"} {
        incr warning_count
    } elseif {$severity eq "ERROR"} {
        incr error_count
    }

    if {[info exists category_count($category)]} {
        incr category_count($category)
    } else {
        set category_count($category) 1
    }
}

close $fp

puts "===== SYNTHESIS WARNING CLASSIFIER ====="
puts ""
puts "TOTAL ISSUES : $total_count"
puts "WARNINGS     : $warning_count"
puts "ERRORS       : $error_count"
puts ""

puts "CATEGORY COUNTS"
puts "---------------"

foreach category [lsort [array names category_count]] {
    puts [format "%-25s %d" $category $category_count($category)]
}

puts ""
puts "REPEATED ISSUES"
puts "---------------"

set repeated_found 0

foreach category [lsort [array names category_count]] {
    if {$category_count($category) > 1} {
        puts [format "%-25s %d occurrences" $category $category_count($category)]
        set repeated_found 1
    }
}

if {!$repeated_found} {
    puts "None"
}

puts ""

if {$error_count > 0} {
    puts "OVERALL SYNTHESIS STATUS: FAIL"
    puts "Reason: One or more synthesis errors were detected."
} elseif {$warning_count > 0} {
    puts "OVERALL SYNTHESIS STATUS: WARNING"
    puts "Reason: Warnings were detected, but no errors were found."
} else {
    puts "OVERALL SYNTHESIS STATUS: PASS"
}

puts ""
puts "===== ANALYSIS COMPLETE ====="
