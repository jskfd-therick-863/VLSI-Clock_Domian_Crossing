#!/usr/bin/env tclsh
# =============================================================
# H5.1 -- Mini Synthesis Flow Manager
#
# Usage:
#   tclsh H5_1_mini_synthesis_flow_manager.tcl <flow.cfg> \
#         [rtl_dir] [constraints.sdc] [synth.log] [qor.rpt]
#
# Only <flow.cfg> is mandatory -- the sample dataset supplies just
# that file, so every later stage degrades gracefully to SKIPPED
# when its optional input isn't supplied/found, instead of crashing
# the whole flow. Supply the optional args to exercise those stages
# fully once you have RTL/constraints/log/QoR files to point at.
#
# Modular framework, one procedure per stage, run in sequence:
#   CHECK_RTL -> READ_CONFIG -> CHECK_CONSTRAINTS ->
#   ANALYZE_SYNTHESIS -> ANALYZE_QOR -> FINAL_REPORT
#
# Each stage:
#   - logs a timestamped start/end line
#   - returns/records PASS, FAIL, or SKIPPED (+ reason)
#   - errors inside a stage are caught so one bad stage doesn't
#     kill the rest of the flow (error handling requirement)
# =============================================================

set ::STAGE_RESULTS {}
set ::CONFIG {}
set ::LOG_FILE "flow_run.log"

# --- logging helper: timestamped, prints AND appends to a log file ---
proc log_msg {msg} {
    set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set line "\[$ts\] $msg"
    puts $line
    if {[catch {
        set fh [open $::LOG_FILE a]
        puts $fh $line
        close $fh
    } err]} {
        # logging to disk is best-effort; never fail the flow over it
    }
}

proc record_stage {stage status reason} {
    lappend ::STAGE_RESULTS [list $stage $status $reason]
    log_msg "STAGE $stage -> $status ($reason)"
}

# --- Stage 1: CHECK_RTL ---------------------------------------
proc CHECK_RTL {rtl_dir} {
    log_msg "=== Stage: CHECK_RTL ==="
    if {$rtl_dir eq ""} {
        record_stage "CHECK_RTL" "SKIPPED" "no RTL directory supplied"
        return
    }
    if {![file isdirectory $rtl_dir]} {
        record_stage "CHECK_RTL" "FAIL" "directory not found: $rtl_dir"
        return
    }
    set rtl_files [glob -nocomplain -directory $rtl_dir -- *.v *.sv *.vhd]
    if {[llength $rtl_files] == 0} {
        record_stage "CHECK_RTL" "FAIL" "no .v/.sv/.vhd files found in $rtl_dir"
    } else {
        record_stage "CHECK_RTL" "PASS" "[llength $rtl_files] RTL file(s) found"
    }
}

# --- Stage 2: READ_CONFIG --------------------------------------
proc READ_CONFIG {flow_cfg} {
    log_msg "=== Stage: READ_CONFIG ==="
    if {![file exists $flow_cfg]} {
        record_stage "READ_CONFIG" "FAIL" "config file not found: $flow_cfg"
        return
    }
    array set cfg {}
    set fh [open $flow_cfg r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set key   [lindex $line 0]
        set value [lindex $line 1]
        set cfg($key) $value
    }
    close $fh

    set required {DESIGN TOP CLOCK CLOCK_PERIOD MAX_AREA MAX_POWER TARGET_WNS}
    set missing {}
    foreach r $required {
        if {![info exists cfg($r)]} { lappend missing $r }
    }
    set ::CONFIG [array get cfg]

    if {[llength $missing] > 0} {
        record_stage "READ_CONFIG" "FAIL" "missing key(s): [join $missing {, }]"
    } else {
        record_stage "READ_CONFIG" "PASS" \
            "design=$cfg(DESIGN) top=$cfg(TOP) clock=$cfg(CLOCK)@$cfg(CLOCK_PERIOD)ns"
    }
}

# --- Stage 3: CHECK_CONSTRAINTS ---------------------------------
proc CHECK_CONSTRAINTS {sdc_file} {
    log_msg "=== Stage: CHECK_CONSTRAINTS ==="
    if {$sdc_file eq ""} {
        record_stage "CHECK_CONSTRAINTS" "SKIPPED" "no constraints file supplied"
        return
    }
    if {![file exists $sdc_file]} {
        record_stage "CHECK_CONSTRAINTS" "FAIL" "constraints file not found: $sdc_file"
        return
    }
    array set cfg $::CONFIG
    set clock_defined 0
    set fh [open $sdc_file r]
    while {[gets $fh line] >= 0} {
        if {[info exists cfg(CLOCK)] && [string match "*$cfg(CLOCK)*" $line] \
                && [string match "*create_clock*" $line]} {
            set clock_defined 1
        }
    }
    close $fh
    if {[info exists cfg(CLOCK)] && !$clock_defined} {
        record_stage "CHECK_CONSTRAINTS" "FAIL" \
            "no create_clock found for '$cfg(CLOCK)' in $sdc_file"
    } else {
        record_stage "CHECK_CONSTRAINTS" "PASS" "constraints file present and clock check OK"
    }
}

# --- Stage 4: ANALYZE_SYNTHESIS ---------------------------------
proc ANALYZE_SYNTHESIS {synth_log} {
    log_msg "=== Stage: ANALYZE_SYNTHESIS ==="
    if {$synth_log eq ""} {
        record_stage "ANALYZE_SYNTHESIS" "SKIPPED" "no synthesis log supplied"
        return
    }
    if {![file exists $synth_log]} {
        record_stage "ANALYZE_SYNTHESIS" "FAIL" "log file not found: $synth_log"
        return
    }
    set errors 0
    set warnings 0
    set fh [open $synth_log r]
    while {[gets $fh line] >= 0} {
        if {[string match "ERROR *" $line]}   { incr errors }
        if {[string match "WARNING *" $line]} { incr warnings }
    }
    close $fh
    if {$errors > 0} {
        record_stage "ANALYZE_SYNTHESIS" "FAIL" "$errors error(s), $warnings warning(s) in log"
    } else {
        record_stage "ANALYZE_SYNTHESIS" "PASS" "0 errors, $warnings warning(s) in log"
    }
}

# --- Stage 5: ANALYZE_QOR ---------------------------------------
proc ANALYZE_QOR {qor_rpt} {
    log_msg "=== Stage: ANALYZE_QOR ==="
    if {$qor_rpt eq ""} {
        record_stage "ANALYZE_QOR" "SKIPPED" "no QoR report supplied"
        return
    }
    if {![file exists $qor_rpt]} {
        record_stage "ANALYZE_QOR" "FAIL" "QoR report not found: $qor_rpt"
        return
    }
    array set cfg $::CONFIG
    if {![info exists cfg(MAX_AREA)]} {
        record_stage "ANALYZE_QOR" "FAIL" "cannot check QoR: config was not loaded (READ_CONFIG failed earlier)"
        return
    }
    array set qor {}
    set fh [open $qor_rpt r]
    while {[gets $fh line] >= 0} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        set qor([lindex $line 0]) [lindex $line 1]
    }
    close $fh

    set fails {}
    if {[info exists qor(AREA)] && $qor(AREA) > $cfg(MAX_AREA)} {
        lappend fails "AREA $qor(AREA) > MAX_AREA $cfg(MAX_AREA)"
    }
    if {[info exists qor(POWER)] && $qor(POWER) > $cfg(MAX_POWER)} {
        lappend fails "POWER $qor(POWER) > MAX_POWER $cfg(MAX_POWER)"
    }
    if {[info exists qor(WNS)] && $qor(WNS) < $cfg(TARGET_WNS)} {
        lappend fails "WNS $qor(WNS) < TARGET_WNS $cfg(TARGET_WNS)"
    }

    if {[llength $fails] > 0} {
        record_stage "ANALYZE_QOR" "FAIL" [join $fails "; "]
    } else {
        record_stage "ANALYZE_QOR" "PASS" "all QoR metrics within limits"
    }
}

# --- Stage 6: FINAL_REPORT --------------------------------------
proc FINAL_REPORT {} {
    log_msg "=== Stage: FINAL_REPORT ==="
    puts ""
    puts "===================================================================="
    puts " MINI SYNTHESIS FLOW -- FINAL REPORT"
    puts "===================================================================="
    puts [format "%-22s %-10s %s" "STAGE" "STATUS" "DETAIL"]
    puts "--------------------------------------------------------------------"
    set pass 0; set fail 0; set skip 0
    foreach s $::STAGE_RESULTS {
        lassign $s stage status reason
        puts [format "%-22s %-10s %s" $stage $status $reason]
        switch -- $status {
            PASS    { incr pass }
            FAIL    { incr fail }
            SKIPPED { incr skip }
        }
    }
    puts "--------------------------------------------------------------------"
    puts "Totals: $pass passed, $fail failed, $skip skipped"
    if {$fail > 0} {
        puts "OVERALL FLOW STATUS: FAIL"
    } elseif {$skip > 0} {
        puts "OVERALL FLOW STATUS: INCOMPLETE (some stages skipped -- provide missing inputs)"
    } else {
        puts "OVERALL FLOW STATUS: PASS"
    }
    puts "===================================================================="
}

# --- Main / orchestration with error handling --------------------
proc main {argv} {
    if {[llength $argv] < 1} {
        puts "Usage: tclsh H5_1_mini_synthesis_flow_manager.tcl <flow.cfg> \[rtl_dir\] \[constraints.sdc\] \[synth.log\] \[qor.rpt\]"
        exit 1
    }
    set flow_cfg  [lindex $argv 0]
    set rtl_dir   [lindex $argv 1]
    set sdc_file  [lindex $argv 2]
    set synth_log [lindex $argv 3]
    set qor_rpt   [lindex $argv 4]

    if {[catch {CHECK_RTL $rtl_dir} err]} {
        record_stage "CHECK_RTL" "ERROR" $err
    }
    if {[catch {READ_CONFIG $flow_cfg} err]} {
        record_stage "READ_CONFIG" "ERROR" $err
    }
    if {[catch {CHECK_CONSTRAINTS $sdc_file} err]} {
        record_stage "CHECK_CONSTRAINTS" "ERROR" $err
    }
    if {[catch {ANALYZE_SYNTHESIS $synth_log} err]} {
        record_stage "ANALYZE_SYNTHESIS" "ERROR" $err
    }
    if {[catch {ANALYZE_QOR $qor_rpt} err]} {
        record_stage "ANALYZE_QOR" "ERROR" $err
    }
    FINAL_REPORT
}

main $argv
