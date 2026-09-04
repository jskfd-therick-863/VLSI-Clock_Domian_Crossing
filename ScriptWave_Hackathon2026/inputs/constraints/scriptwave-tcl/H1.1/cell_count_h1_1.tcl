# SET 1 | LEVEL 1 | HURDLE 1
# Standard-Cell Counter
# Usage: tclsh cell_count_h1_1.tcl <dataset_file>

if {$argc != 1} {
    puts "Usage: tclsh cell_count_h1_1.tcl <dataset_file>"
    exit 1
}

set filename [lindex $argv 0]

if {![file exists $filename]} {
    puts "ERROR: File not found: $filename"
    exit 1
}

set total 0
set comb 0
set seq 0
array set cell_count {}

set fp [open $filename r]

while {[gets $fp line] >= 0} {
    set line [string trim $line]

    if {$line eq ""} {
        continue
    }

    set fields [split $line]

    if {[llength $fields] < 3} {
        continue
    }

    set cell [lindex $fields 1]
    set type [lindex $fields 2]

    incr total

    if {$type eq "COMB"} {
        incr comb
    } elseif {$type eq "SEQ"} {
        incr seq
    }

    incr cell_count($cell)
}

close $fp

set most_frequent ""
set max_count 0

foreach cell [array names cell_count] {
    if {$cell_count($cell) > $max_count} {
        set max_count $cell_count($cell)
        set most_frequent $cell
    }
}

puts "===== STANDARD CELL COUNTER ====="
puts [format "%-20s %d" "Total cells" $total]
puts [format "%-20s %d" "Combinational cells" $comb]
puts [format "%-20s %d" "Sequential cells" $seq]

puts ""
puts "Cell type counts:"
foreach cell [lsort [array names cell_count]] {
    puts [format "  %-15s %d" $cell $cell_count($cell)]
}

puts ""
puts "Most frequent cell: $most_frequent"
puts "Frequency: $max_count"
