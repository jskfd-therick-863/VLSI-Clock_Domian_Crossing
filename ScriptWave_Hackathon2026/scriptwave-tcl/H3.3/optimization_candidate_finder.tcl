#!/usr/bin/env tclsh

# ============================================================
# H3.3 - Optimization Candidate Finder
# Rank timing optimization candidates using:
#   1. Negative slack (timing urgency)
#   2. Fanout
#   3. Cell strength
#
# The question does not prescribe numerical weights, so this
# script uses a team-defined weighted score:
#   50% timing + 30% fanout + 20% cell-strength priority
# ============================================================

if {$argc != 1} {
    puts "Usage: tclsh optimization_candidate_finder.tcl <dataset.txt>"
    exit 1
}

set input_file [lindex $argv 0]

if {![file exists $input_file]} {
    puts "ERROR: Dataset not found: $input_file"
    exit 1
}

set candidates {}

set fp [open $input_file r]

while {[gets $fp line] >= 0} {

    set line [string trim $line]

    # Ignore empty lines
    if {$line eq ""} {
        continue
    }

    # Dataset format:
    # INSTANCE,CELL_TYPE,SLACK,FANOUT
    set fields [split $line ","]

    if {[llength $fields] != 4} {
        puts "WARNING: Skipping malformed line: $line"
        continue
    }

    set inst   [string trim [lindex $fields 0]]
    set cell   [string trim [lindex $fields 1]]
    set slack  [string trim [lindex $fields 2]]
    set fanout [string trim [lindex $fields 3]]

    # Validate numeric fields
    if {![string is double -strict $slack]} {
        puts "WARNING: Invalid slack for $inst: $slack"
        continue
    }

    if {![string is integer -strict $fanout]} {
        puts "WARNING: Invalid fanout for $inst: $fanout"
        continue
    }

    # --------------------------------------------------------
    # 1. Timing score
    # Negative slack means a timing violation.
    # Larger negative magnitude = higher priority.
    # Positive slack gets zero timing urgency.
    # --------------------------------------------------------
    if {$slack < 0} {
        set timing_score [expr {abs($slack) * 100.0}]
    } else {
        set timing_score 0.0
    }

    # --------------------------------------------------------
    # 2. Fanout score
    # Higher fanout means the cell affects more loads.
    # --------------------------------------------------------
    set fanout_score [expr {double($fanout)}]

    # --------------------------------------------------------
    # 3. Cell strength score
    # X1 is treated as a weaker drive strength than X2.
    # A weak X1 cell is a stronger optimization candidate.
    # --------------------------------------------------------
    if {[string match "*_X1" $cell]} {
        set strength_score 10.0
    } else {
        set strength_score 0.0
    }

    # Weighted score:
    # timing   = 50%
    # fanout   = 30%
    # strength = 20%
    set score [expr {
        0.5 * $timing_score +
        0.3 * $fanout_score +
        0.2 * $strength_score
    }]

    lappend candidates [list \
        $score \
        $inst \
        $cell \
        $slack \
        $fanout \
        $timing_score \
        $strength_score]
}

close $fp

# Highest score first
set candidates [lsort -real -decreasing -index 0 $candidates]

puts "============================================================"
puts "             OPTIMIZATION CANDIDATE FINDER"
puts "============================================================"
puts [format "%-6s %-12s %-9s %-8s %-10s" \
    "INST" "CELL" "SLACK" "FANOUT" "SCORE"]
puts "------------------------------------------------------------"

foreach candidate $candidates {

    set score          [lindex $candidate 0]
    set inst           [lindex $candidate 1]
    set cell           [lindex $candidate 2]
    set slack          [lindex $candidate 3]
    set fanout         [lindex $candidate 4]

    puts [format "%-6s %-12s %-9.2f %-8d %-10.2f" \
        $inst $cell $slack $fanout $score]
}

puts "------------------------------------------------------------"

if {[llength $candidates] > 0} {
    set best [lindex $candidates 0]

    puts "TOP CANDIDATE : [lindex $best 1]"
    puts "CELL          : [lindex $best 2]"
    puts "REASON        : highest combined timing/fanout/strength score"
}

puts "============================================================"
puts "SCORING:"
puts "  Timing urgency : 50%"
puts "  Fanout         : 30%"
puts "  Cell strength  : 20%"
puts "Higher score = higher optimization priority"
puts "============================================================"
