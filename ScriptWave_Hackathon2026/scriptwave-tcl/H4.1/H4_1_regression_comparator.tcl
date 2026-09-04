#!/usr/bin/env tclsh
# =============================================================
# H4.1 -- Synthesis Regression Comparator
#
# Usage: tclsh H4_1_regression_comparator.tcl baseline.rpt new.rpt
#
# Compares a baseline synthesis run against a new run and reports,
# per metric: absolute value (before/after), delta, %change, and a
# classification of IMPROVED / REGRESSED / UNCHANGED.
#
# Direction convention (lower-is-better vs higher-is-better) is
# metric-specific and encoded explicitly below:
#   AREA   -> lower is better  (less silicon)
#   POWER  -> lower is better  (less energy)
#   WNS    -> higher is better (less negative / more positive slack)
#   CELLS  -> lower is better  (fewer cells, all else equal)
# =============================================================

# --- 1. Parse a "KEY VALUE" report file into a dict -----------
proc parse_report {filename} {
    if {![file exists $filename]} {
        puts "ERROR: file not found: $filename"
        exit 1
    }
    set fh [open $filename r]
    array set data {}
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set key   [lindex $line 0]
        set value [lindex $line 1]
        set data($key) $value
    }
    close $fh
    return [array get data]
}

# --- 2. Classify a metric's change ------------------------------
# direction: "lower" means smaller new value = improvement
#            "higher" means larger new value = improvement
proc classify {baseline new direction {tol 1e-9}} {
    set delta [expr {$new - $baseline}]
    if {abs($delta) <= $tol} {
        return "UNCHANGED"
    }
    if {$direction eq "lower"} {
        return [expr {$delta < 0 ? "IMPROVED" : "REGRESSED"}]
    } else {
        return [expr {$delta > 0 ? "IMPROVED" : "REGRESSED"}]
    }
}

# --- 3. %change, guarding against divide-by-zero -----------------
proc pct_change {baseline new} {
    if {$baseline == 0} {
        return "N/A"
    }
    return [format "%.2f" [expr {(($new - $baseline) / double(abs($baseline))) * 100.0}]]
}

# --- 4. Main -------------------------------------------------------
proc main {argv} {
    if {[llength $argv] != 2} {
        puts "Usage: tclsh H4_1_regression_comparator.tcl <baseline.rpt> <new.rpt>"
        exit 1
    }
    lassign $argv baseline_file new_file

    array set base [parse_report $baseline_file]
    array set new  [parse_report $new_file]

    # metric -> direction of improvement
    array set direction {
        AREA   lower
        POWER  lower
        WNS    higher
        CELLS  lower
    }

    puts "===================================================================="
    puts " SYNTHESIS REGRESSION COMPARATOR"
    puts "===================================================================="
    puts [format "%-10s %12s %12s %10s %10s %-10s" \
        "METRIC" "BASELINE" "NEW" "DELTA" "%CHANGE" "STATUS"]
    puts "--------------------------------------------------------------------"

    set improved 0
    set regressed 0
    set unchanged 0

    # Preserve a sensible, deterministic column order
    foreach metric {AREA POWER WNS CELLS} {
        if {![info exists base($metric)] || ![info exists new($metric)]} {
            continue
        }
        set b $base($metric)
        set n $new($metric)
        set delta [format "%.3f" [expr {$n - $b}]]
        set pct   [pct_change $b $n]
        set dir   $direction($metric)
        set status [classify $b $n $dir]

        switch -- $status {
            IMPROVED  { incr improved }
            REGRESSED { incr regressed }
            UNCHANGED { incr unchanged }
        }

        set pct_display [expr {$pct eq "N/A" ? "N/A" : "${pct}%"}]
        puts [format "%-10s %12s %12s %10s %10s %-10s" \
            $metric $b $n $delta $pct_display $status]
    }

    puts "--------------------------------------------------------------------"
    puts "Summary: $improved improved, $regressed regressed, $unchanged unchanged"

    # Overall verdict: any regression on AREA/POWER/WNS/CELLS fails the run.
    # (Tune this policy to your team's sign-off criteria if needed.)
    if {$regressed == 0} {
        puts "OVERALL REGRESSION STATUS: PASS (no metric regressed)"
    } else {
        puts "OVERALL REGRESSION STATUS: FAIL ($regressed metric(s) regressed)"
    }
    puts "===================================================================="
}

main $argv
