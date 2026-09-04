#!/usr/bin/env tclsh
# =============================================================
# H4.2 -- Critical Module Finder
#
# Usage: tclsh H4_2_critical_module_finder.tcl dataset.txt
#
# Dataset line format: MODULE  AREA  POWER  WNS
#   e.g. FETCH 18000 12.5 -0.02
#
# Produces a weighted QoR "criticality score" per module, ranks
# modules from most-critical to least-critical, and justifies the
# chosen weighting.
#
# ---------------------------------------------------------------
# WEIGHTING RATIONALE (documented, not hard-coded folklore):
#   WNS    weight = 0.50  -> Timing violations directly threaten
#                            functional correctness / max clock
#                            frequency; a single failing path can
#                            block sign-off regardless of area/power.
#                            Given the heaviest weight.
#   POWER  weight = 0.30  -> Power affects thermal budget, battery
#                            life and reliability; important but
#                            usually fixable post-synthesis (clock
#                            gating, VT swaps) without a full re-spin.
#   AREA   weight = 0.20  -> Area affects cost/die size but is the
#                            least urgent axis once floorplan is
#                            fixed; least weight of the three.
#
# Each raw metric is normalized to a 0-1 scale (min-max across all
# modules in the dataset) before weighting, so metrics with very
# different units/ranges (ns of slack vs mW vs um^2) contribute
# fairly instead of whichever has the biggest raw numbers dominating.
#
# For WNS, more NEGATIVE slack means MORE critical, so we invert it:
# a module with the worst (most negative) WNS gets the highest
# normalized timing-criticality score of 1.0.
# =============================================================

set W_WNS   0.50
set W_POWER 0.30
set W_AREA  0.20

proc parse_dataset {filename} {
    if {![file exists $filename]} {
        puts "ERROR: file not found: $filename"
        exit 1
    }
    set fh [open $filename r]
    set modules {}
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set name  [lindex $line 0]
        set area  [lindex $line 1]
        set power [lindex $line 2]
        set wns   [lindex $line 3]
        lappend modules [list $name $area $power $wns]
    }
    close $fh
    return $modules
}

# min-max normalize x into [0,1] given range [lo,hi]; flat range -> 0
proc normalize {x lo hi} {
    if {$hi == $lo} { return 0.0 }
    return [expr {double($x - $lo) / double($hi - $lo)}]
}

proc main {argv} {
    if {[llength $argv] != 1} {
        puts "Usage: tclsh H4_2_critical_module_finder.tcl <dataset.txt>"
        exit 1
    }
    global W_WNS W_POWER W_AREA

    set modules [parse_dataset [lindex $argv 0]]
    if {[llength $modules] == 0} {
        puts "No modules found in dataset."
        exit 1
    }

    # --- gather ranges for normalization ---
    set areas {}; set powers {}; set wnss {}
    foreach m $modules {
        lassign $m name area power wns
        lappend areas  $area
        lappend powers $power
        lappend wnss   $wns
    }
    set area_lo  [tcl::mathfunc::min {*}$areas]
    set area_hi  [tcl::mathfunc::max {*}$areas]
    set power_lo [tcl::mathfunc::min {*}$powers]
    set power_hi [tcl::mathfunc::max {*}$powers]
    set wns_lo   [tcl::mathfunc::min {*}$wnss]
    set wns_hi   [tcl::mathfunc::max {*}$wnss]

    # --- compute weighted criticality score per module ---
    set results {}
    foreach m $modules {
        lassign $m name area power wns

        set area_n  [normalize $area  $area_lo  $area_hi]
        set power_n [normalize $power $power_lo $power_hi]
        # invert: most-negative WNS (worst timing) => normalized 1.0
        set wns_n   [expr {1.0 - [normalize $wns $wns_lo $wns_hi]}]

        set score [expr {($W_WNS * $wns_n) + ($W_POWER * $power_n) + ($W_AREA * $area_n)}]
        lappend results [list $name $area $power $wns $score]
    }

    # --- sort descending by score (most critical first) ---
    set sorted [lsort -real -decreasing -index 4 $results]

    puts "===================================================================="
    puts " CRITICAL MODULE FINDER  (weights: WNS=$W_WNS  POWER=$W_POWER  AREA=$W_AREA)"
    puts "===================================================================="
    puts [format "%-6s %-12s %10s %10s %8s %8s %10s" \
        "RANK" "MODULE" "AREA" "POWER" "WNS" "SCORE" "VERDICT"]
    puts "--------------------------------------------------------------------"

    set rank 1
    foreach r $sorted {
        lassign $r name area power wns score
        set score_fmt [format "%.3f" $score]
        if {$rank == 1} {
            set verdict "MOST CRITICAL"
        } elseif {$score > 0.6} {
            set verdict "HIGH RISK"
        } elseif {$score > 0.3} {
            set verdict "MODERATE"
        } else {
            set verdict "LOW RISK"
        }
        puts [format "%-6s %-12s %10s %10s %8s %8s %10s" \
            $rank $name $area $power $wns $score_fmt $verdict]
        incr rank
    }
    puts "--------------------------------------------------------------------"
    lassign [lindex $sorted 0] top_name
    puts "Top optimization priority: $top_name"
    puts "Justification: weighting favors timing (WNS 50%) since a single"
    puts "failing timing path can block sign-off; power (30%) is the next"
    puts "most costly axis (thermal/reliability); area (20%) is least"
    puts "urgent once floorplan is committed."
    puts "===================================================================="
}

main $argv
