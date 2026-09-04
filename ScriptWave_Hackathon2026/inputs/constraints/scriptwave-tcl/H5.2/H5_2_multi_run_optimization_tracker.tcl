#!/usr/bin/env tclsh
# =============================================================
# H5.2 -- Multi-Run Optimization Tracker
#
# Usage: tclsh H5_2_multi_run_optimization_tracker.tcl dataset.txt
#
# Dataset line format: RUNx AREA=<v> POWER=<v> WNS=<v>
#   e.g. RUN1 AREA=195000 POWER=138 WNS=-0.31
#
# Determines the best implementation run via a team-defined scoring
# function, reports the run-over-run improvement trend per metric,
# and justifies the winning selection.
#
# ---------------------------------------------------------------
# SCORING FUNCTION (team-defined, documented):
#   Each metric is min-max normalized to [0,1] across all runs in
#   the dataset, oriented so that 1.0 = best-in-set, 0.0 = worst-in-set:
#     AREA, POWER  -> lower raw value = better  (inverted normalize)
#     WNS          -> higher raw value = better (direct normalize)
#   Weighted sum, same rationale as the Level 4 criticality scorer:
#     WNS   weight = 0.50  (timing closure is the hardest/most costly
#                           thing to fix late, so it dominates the score)
#     POWER weight = 0.30  (thermal/battery impact, moderately fixable)
#     AREA  weight = 0.20  (cost/die size, least urgent post-floorplan)
#   Highest total score = best run. Weights are exposed as variables
#   below so a team can retune them to their own sign-off priorities.
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
    set runs {}
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set tokens [split $line]
        set run_name [lindex $tokens 0]
        array set kv {}
        foreach tok [lrange $tokens 1 end] {
            if {[regexp {^([A-Z_]+)=(-?[0-9.]+)$} $tok -> key val]} {
                set kv($key) $val
            }
        }
        lappend runs [list $run_name $kv(AREA) $kv(POWER) $kv(WNS)]
        array unset kv
    }
    close $fh
    return $runs
}

proc normalize {x lo hi} {
    if {$hi == $lo} { return 0.0 }
    return [expr {double($x - $lo) / double($hi - $lo)}]
}

proc main {argv} {
    if {[llength $argv] != 1} {
        puts "Usage: tclsh H5_2_multi_run_optimization_tracker.tcl <dataset.txt>"
        exit 1
    }
    global W_WNS W_POWER W_AREA

    set runs [parse_dataset [lindex $argv 0]]
    if {[llength $runs] == 0} {
        puts "No runs found in dataset."
        exit 1
    }

    set areas {}; set powers {}; set wnss {}
    foreach r $runs {
        lassign $r name area power wns
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

    set scored {}
    foreach r $runs {
        lassign $r name area power wns
        set area_good  [expr {1.0 - [normalize $area  $area_lo  $area_hi]}]
        set power_good [expr {1.0 - [normalize $power $power_lo $power_hi]}]
        set wns_good   [normalize $wns $wns_lo $wns_hi]
        set score [expr {($W_WNS * $wns_good) + ($W_POWER * $power_good) + ($W_AREA * $area_good)}]
        lappend scored [list $name $area $power $wns $score]
    }
    set ranked [lsort -real -decreasing -index 4 $scored]

    puts "===================================================================="
    puts " MULTI-RUN OPTIMIZATION TRACKER  (weights: WNS=$W_WNS POWER=$W_POWER AREA=$W_AREA)"
    puts "===================================================================="
    puts [format "%-6s %-8s %10s %8s %8s %8s" "RANK" "RUN" "AREA" "POWER" "WNS" "SCORE"]
    puts "--------------------------------------------------------------------"
    set rank 1
    foreach r $ranked {
        lassign $r name area power wns score
        puts [format "%-6s %-8s %10s %8s %8s %8s" $rank $name $area $power $wns [format "%.3f" $score]]
        incr rank
    }
    puts "--------------------------------------------------------------------"
    lassign [lindex $ranked 0] best_name
    puts "BEST RUN: $best_name"
    puts ""

    # --- improvement trend across runs, in original dataset order ---
    puts "-- Run-over-run trend (dataset order) -------------------------------"
    set prev {}
    foreach r $runs {
        lassign $r name area power wns
        if {$prev ne ""} {
            lassign $prev pname parea ppower pwns
            set d_area  [expr {$area - $parea}]
            set d_power [expr {$power - $ppower}]
            set d_wns   [format "%.3f" [expr {$wns - $pwns}]]
            set area_dir  [expr {$d_area  < 0 ? "better" : ($d_area  > 0 ? "worse" : "flat")}]
            set power_dir [expr {$d_power < 0 ? "better" : ($d_power > 0 ? "worse" : "flat")}]
            set wns_dir   [expr {$d_wns   > 0 ? "better" : ($d_wns   < 0 ? "worse" : "flat")}]
            puts "  $pname -> $name : AREA [format {%+d} $d_area] ($area_dir), POWER [format {%+.1f} $d_power] ($power_dir), WNS $d_wns ($wns_dir)"
        }
        set prev $r
    }
    puts "--------------------------------------------------------------------"
    puts "Justification: $best_name scores highest under the timing-weighted"
    puts "model (WNS 50% / POWER 30% / AREA 20%) because timing closure is"
    puts "prioritized over area/power once a design is otherwise viable;"
    puts "it need not be the single smallest-area run to be the best overall."
    puts "===================================================================="
}

main $argv
