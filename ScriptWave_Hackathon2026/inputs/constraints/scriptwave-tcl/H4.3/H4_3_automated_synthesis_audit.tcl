#!/usr/bin/env tclsh
# =============================================================
# H4.3 -- Automated Synthesis Audit
#
# Usage:
#   tclsh H4_3_automated_synthesis_audit.tcl synth.log qor.rpt vt_cells.txt hierarchy.txt
#
# Combines four heterogeneous inputs into a single severity-ranked
# audit report with recommended corrective actions:
#   synth.log      -> WARNING/ERROR <CATEGORY> <SIGNAL/MODULE>
#   qor.rpt        -> KEY VALUE  (AREA, POWER, WNS, TNS, VIOLATIONS, ...)
#   vt_cells.txt   -> <CELL_INST> <CELLNAME_VT>   (LVT/SVT/HVT suffix)
#   hierarchy.txt  -> MODULE <name> <cellcount>
#
# Severity policy (highest first):
#   1 CRITICAL - synth.log ERRORs (e.g. MULTIPLE_DRIVER, COMBINATIONAL_LOOP)
#   2 HIGH     - QoR limit breaches (negative WNS/TNS, VIOLATIONS > 0)
#   3 MEDIUM   - synth.log WARNINGs (e.g. LATCH_INFERRED, UNCONNECTED_PORT)
#   4 LOW      - excessive LVT-cell usage (> 40% of cells), informational
#   (Tune thresholds below to match your team's sign-off criteria.)
# =============================================================

set LVT_THRESHOLD_PCT 40.0

# --- known recommended fixes per synth.log category -----------
array set REMEDY {
    MULTIPLE_DRIVER       "Resolve net driven by multiple sources; check for accidental multi-assignment or missing tri-state control."
    COMBINATIONAL_LOOP    "Break combinational feedback path; check for missing register or misrouted feedback logic."
    LATCH_INFERRED        "Add explicit else/default branch in the RTL to avoid unintended latch inference; convert to registered logic if a latch was not intended."
    UNUSED_SIGNAL         "Remove or connect the unused signal; verify it isn't a leftover debug/test net."
    UNCONNECTED_PORT      "Connect the dangling port or tie it off explicitly (0/1) to avoid X-propagation."
}

proc parse_synth_log {filename} {
    set issues {}
    if {![file exists $filename]} { return $issues }
    set fh [open $filename r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set sev_word  [lindex $line 0]
        set category  [lindex $line 1]
        set target    [lindex $line 2]
        lappend issues [list $sev_word $category $target]
    }
    close $fh
    return $issues
}

proc parse_kv_report {filename} {
    array set data {}
    if {![file exists $filename]} { return [array get data] }
    set fh [open $filename r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set data([lindex $line 0]) [lindex $line 1]
    }
    close $fh
    return [array get data]
}

proc parse_vt_cells {filename} {
    set counts(LVT) 0
    set counts(SVT) 0
    set counts(HVT) 0
    set counts(OTHER) 0
    set total 0
    if {![file exists $filename]} { return [list [array get counts] 0] }
    set fh [open $filename r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set cellname [lindex $line 1]
        incr total
        if {[string match "*_LVT" $cellname]} {
            incr counts(LVT)
        } elseif {[string match "*_SVT" $cellname]} {
            incr counts(SVT)
        } elseif {[string match "*_HVT" $cellname]} {
            incr counts(HVT)
        } else {
            incr counts(OTHER)
        }
    }
    close $fh
    return [list [array get counts] $total]
}

proc parse_hierarchy {filename} {
    set modules {}
    if {![file exists $filename]} { return $modules }
    set fh [open $filename r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[lindex $line 0] eq "MODULE"} {
            lappend modules [list [lindex $line 1] [lindex $line 2]]
        }
    }
    close $fh
    return $modules
}

proc main {argv} {
    if {[llength $argv] != 4} {
        puts "Usage: tclsh H4_3_automated_synthesis_audit.tcl <synth.log> <qor.rpt> <vt_cells.txt> <hierarchy.txt>"
        exit 1
    }
    lassign $argv log_file qor_file vt_file hier_file
    global REMEDY LVT_THRESHOLD_PCT

    set log_issues [parse_synth_log $log_file]
    array set qor  [parse_kv_report $qor_file]
    lassign [parse_vt_cells $vt_file] vt_counts_list vt_total
    array set vt_counts $vt_counts_list
    set hier_modules [parse_hierarchy $hier_file]

    # Findings collected as: {severity_rank severity_label source description}
    set findings {}

    # --- 1. synth.log ERRORs = CRITICAL, WARNINGs = MEDIUM ---
    foreach issue $log_issues {
        lassign $issue sev cat target
        if {$sev eq "ERROR"} {
            set rank 1; set label "CRITICAL"
        } else {
            set rank 3; set label "MEDIUM"
        }
        if {[info exists REMEDY($cat)]} {
            set remedy $REMEDY($cat)
        } else {
            set remedy "Review $cat on $target manually."
        }
        lappend findings [list $rank $label "synth.log" \
            "$cat on '$target'" $remedy]
    }

    # --- 2. QoR breaches = HIGH ---
    if {[info exists qor(WNS)] && $qor(WNS) < 0} {
        lappend findings [list 2 "HIGH" "qor.rpt" \
            "Negative worst-negative-slack: WNS = $qor(WNS) ns" \
            "Optimize critical timing path(s); consider cell upsizing, buffering, or logic restructuring on the worst path."]
    }
    if {[info exists qor(TNS)] && $qor(TNS) < 0} {
        lappend findings [list 2 "HIGH" "qor.rpt" \
            "Negative total-negative-slack: TNS = $qor(TNS) ns" \
            "Multiple paths violate timing; run broader timing ECO / re-synthesis with tighter effort on the affected clock domain."]
    }
    if {[info exists qor(VIOLATIONS)] && $qor(VIOLATIONS) > 0} {
        lappend findings [list 2 "HIGH" "qor.rpt" \
            "$qor(VIOLATIONS) timing violation(s) reported" \
            "Triage violating endpoints by slack severity and fanout; prioritize fixes on paths feeding critical modules."]
    }

    # --- 3. Excessive LVT usage = LOW/informational ---
    if {$vt_total > 0} {
        set lvt_pct [expr {double($vt_counts(LVT)) / double($vt_total) * 100.0}]
        if {$lvt_pct > $LVT_THRESHOLD_PCT} {
            lappend findings [list 4 "LOW" "vt_cells.txt" \
                [format "Excessive LVT usage: %.1f%% of cells (threshold %.0f%%)" $lvt_pct $LVT_THRESHOLD_PCT] \
                "Swap non-critical-path LVT cells to SVT/HVT to reduce leakage power without harming timing."]
        }
    }

    # --- sort findings by severity rank (1=most severe first) ---
    set sorted [lsort -integer -index 0 $findings]

    puts "===================================================================="
    puts " AUTOMATED SYNTHESIS AUDIT REPORT"
    puts "===================================================================="
    puts "Inputs: $log_file, $qor_file, $vt_file, $hier_file"
    puts ""
    puts "-- Design Snapshot -------------------------------------------------"
    if {[info exists qor(AREA)]}    { puts "  Area          : $qor(AREA)" }
    if {[info exists qor(POWER)]}   { puts "  Power         : $qor(POWER)" }
    if {[info exists qor(WNS)]}     { puts "  WNS           : $qor(WNS) ns" }
    if {[info exists qor(TNS)]}     { puts "  TNS           : $qor(TNS) ns" }
    if {[info exists qor(VIOLATIONS)]} { puts "  Violations    : $qor(VIOLATIONS)" }
    if {$vt_total > 0} {
        puts [format "  VT mix        : LVT=%d SVT=%d HVT=%d (of %d cells)" \
            $vt_counts(LVT) $vt_counts(SVT) $vt_counts(HVT) $vt_total]
    }
    if {[llength $hier_modules] > 0} {
        set total_cells 0
        set largest_name ""; set largest_cells -1
        foreach m $hier_modules {
            lassign $m name cells
            incr total_cells $cells
            if {$cells > $largest_cells} { set largest_cells $cells; set largest_name $name }
        }
        puts "  Total cells   : $total_cells (across [llength $hier_modules] module(s) listed)"
        puts "  Largest module: $largest_name ($largest_cells cells)"
    }
    puts ""
    puts "-- Severity-Ranked Findings -----------------------------------------"
    if {[llength $sorted] == 0} {
        puts "  No issues found. Design is clean."
    } else {
        set n 1
        foreach f $sorted {
            lassign $f rank label source desc remedy
            puts "  \[$n\] $label  (source: $source)"
            puts "      Issue      : $desc"
            puts "      Corrective : $remedy"
            incr n
        }
    }
    puts ""
    puts "-- Overall Sign-off Status ------------------------------------------"
    set critical_count 0
    set high_count 0
    foreach f $sorted {
        lassign $f rank
        if {$rank == 1} { incr critical_count }
        if {$rank == 2} { incr high_count }
    }
    if {$critical_count > 0} {
        puts "  STATUS: BLOCKED -- $critical_count critical issue(s) must be fixed before sign-off."
    } elseif {$high_count > 0} {
        puts "  STATUS: AT RISK -- $high_count high-severity QoR issue(s) need resolution."
    } else {
        puts "  STATUS: CLEAR -- no blocking issues found."
    }
    puts "===================================================================="
}

main $argv
