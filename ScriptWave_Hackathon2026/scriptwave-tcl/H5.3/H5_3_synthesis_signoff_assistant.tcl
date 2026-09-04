#!/usr/bin/env tclsh
# =============================================================
# H5.3 -- Synthesis Sign-Off Assistant
#
# Usage: tclsh H5_3_synthesis_signoff_assistant.tcl <root_dir>
#
# Given an UNKNOWN collection of RTL/synthesis-related files (any
# names, any depth of subdirectories -- e.g. blackbox/rtl/,
# blackbox/reports/, blackbox/config/, blackbox/logs/), this script:
#   1. Recursively discovers every file under root_dir.
#   2. Classifies each file by CONTENT (not filename), since names
#      in an unknown drop are not trustworthy.
#   3. Extracts metrics (AREA/POWER/WNS/...) and limits (MAX_*/MIN_*).
#   4. Flags missing data (a limit with no matching metric, or vice
#      versa) and malformed data (non-numeric values, conflicting
#      duplicate keys across files).
#   5. Cross-checks metrics vs. limits and produces an autonomous
#      PASS/FAIL sign-off report.
#
# Classification heuristics (first match wins, checked per file):
#   - any line starts with WARNING/ERROR         -> synth_log
#   - any line starts with MODULE <name> <count> -> hierarchy
#   - any "<inst> <cell>_LVT|_SVT|_HVT" line      -> vt_cells
#   - keys include MAX_* or MIN_*                -> limits
#   - keys look like bare ALLCAPS metric names    -> qor (metrics)
#   - none of the above                           -> unknown (flagged)
# =============================================================

# --- recursively collect all regular files under a directory ---
# Script/tooling files are excluded outright: this audit is meant to
# scan RTL/synthesis DATA, not the Tcl scripts doing the scanning
# (otherwise a script sitting next to its own dataset -- or copies of
# itself in subfolders -- gets misread as design data).
set ::EXCLUDED_EXTENSIONS {.tcl .tk .py .sh .pl .md}

proc find_all_files {dir} {
    set out {}
    if {![file isdirectory $dir]} { return $out }
    foreach entry [glob -nocomplain -directory $dir -- *] {
        if {[file isdirectory $entry]} {
            lappend out {*}[find_all_files $entry]
        } elseif {[file isfile $entry]} {
            set ext [string tolower [file extension $entry]]
            if {[lsearch -exact $::EXCLUDED_EXTENSIONS $ext] < 0} {
                lappend out $entry
            }
        }
    }
    return $out
}

# --- read a file into a list of trimmed, non-empty lines ---
proc read_lines {path} {
    set lines {}
    if {[catch {
        set fh [open $path r]
        while {[gets $fh line] >= 0} {
            set line [string trim $line]
            if {$line ne ""} { lappend lines $line }
        }
        close $fh
    } err]} {
        return -code error "cannot read $path: $err"
    }
    return $lines
}

# --- classify one file's lines; returns {type kvdict malformed_lines} ---
proc classify {lines} {
    set has_warn_err 0
    set has_module   0
    set has_vt       0
    foreach l $lines {
        if {[string match "WARNING *" $l] || [string match "ERROR *" $l]} { set has_warn_err 1 }
        if {[string match "MODULE *" $l]} { set has_module 1 }
        if {[regexp {_LVT$|_SVT$|_HVT$} $l]} { set has_vt 1 }
    }
    if {$has_warn_err} { return [list synth_log {} {}] }
    if {$has_module}   { return [list hierarchy {} {}] }
    if {$has_vt}       { return [list vt_cells {} {}] }

    # try KEY VALUE or KEY=VALUE style, allowing "=" or whitespace separator.
    # KEY must be ALL_CAPS (with digits/underscores) like real QoR/limit
    # keys (AREA, MAX_POWER, MIN_WNS, ...) -- this deliberately excludes
    # lowercase/mixed-case identifiers so code fragments (e.g. an
    # accidental "exit 1" line) can never be mistaken for a metric.
    array set kv {}
    set malformed {}
    set recognized_count 0
    foreach l $lines {
        if {[regexp {^([A-Z][A-Z0-9_]*)[\s=]+(-?[0-9]+\.?[0-9]*)$} $l -> key val]} {
            set kv($key) $val
            incr recognized_count
        } else {
            lappend malformed $l
        }
    }
    # A file with zero recognized KEY=VALUE lines is just not a data file
    # (prose, a README, an index, a log with a different format, etc.)
    # -- report it as "unknown" with no line-by-line noise, since dumping
    # every prose line as "malformed" isn't a useful audit finding.
    if {$recognized_count == 0} {
        return [list unknown {} {}]
    }
    set is_limits 0
    foreach k [array names kv] {
        if {[string match "MAX_*" $k] || [string match "MIN_*" $k]} { set is_limits 1 }
    }
    if {$is_limits} {
        return [list limits [array get kv] $malformed]
    }
    return [list qor [array get kv] $malformed]
}

proc main {argv} {
    if {[llength $argv] != 1} {
        puts "Usage: tclsh H5_3_synthesis_signoff_assistant.tcl <root_dir>"
        exit 1
    }
    set root [lindex $argv 0]
    if {![file isdirectory $root]} {
        puts "ERROR: not a directory: $root"
        exit 1
    }

    set files [find_all_files $root]

    array set metrics {}
    array set limits  {}
    set conflicts {}
    set unknown_files {}
    set malformed_report {}
    set discovered {}

    foreach f $files {
        if {[catch {read_lines $f} lines]} {
            lappend unknown_files "$f (unreadable)"
            continue
        }
        if {[llength $lines] == 0} {
            lappend unknown_files "$f (empty)"
            continue
        }
        lassign [classify $lines] type kvlist malformed
        lappend discovered [list $f $type]

        if {[llength $malformed] > 0} {
            foreach m $malformed {
                lappend malformed_report "$f: unrecognized line -> '$m'"
            }
        }

        if {$type eq "qor"} {
            array set kv $kvlist
            foreach k [array names kv] {
                if {[info exists metrics($k)] && $metrics($k) != $kv($k)} {
                    lappend conflicts "metric $k: conflicting values $metrics($k) (earlier) vs $kv($k) (in $f)"
                }
                set metrics($k) $kv($k)
            }
            array unset kv
        } elseif {$type eq "limits"} {
            array set kv $kvlist
            foreach k [array names kv] {
                if {[info exists limits($k)] && $limits($k) != $kv($k)} {
                    lappend conflicts "limit $k: conflicting values $limits($k) (earlier) vs $kv($k) (in $f)"
                }
                set limits($k) $kv($k)
            }
            array unset kv
        } elseif {$type eq "unknown"} {
            lappend unknown_files "$f (content not recognized)"
        }
    }

    puts "===================================================================="
    puts " SYNTHESIS SIGN-OFF ASSISTANT -- AUTONOMOUS DISCOVERY REPORT"
    puts "===================================================================="
    puts "Root scanned: $root"
    puts "Files found : [llength $files]"
    puts ""
    puts "-- Discovered files ------------------------------------------------"
    foreach d $discovered {
        lassign $d f type
        puts [format "  %-8s %s" "\[$type\]" $f]
    }
    puts ""
    puts "-- Metrics discovered -----------------------------------------------"
    if {[array size metrics] == 0} {
        puts "  (none found)"
    } else {
        foreach k [lsort [array names metrics]] {
            puts "  $k = $metrics($k)"
        }
    }
    puts ""
    puts "-- Limits discovered -------------------------------------------------"
    if {[array size limits] == 0} {
        puts "  (none found)"
    } else {
        foreach k [lsort [array names limits]] {
            puts "  $k = $limits($k)"
        }
    }
    puts ""
    puts "-- Data-quality flags ------------------------------------------------"
    set flag_count 0
    foreach u $unknown_files {
        puts "  UNRECOGNIZED FILE: $u"
        incr flag_count
    }
    foreach m $malformed_report {
        puts "  MALFORMED LINE   : $m"
        incr flag_count
    }
    foreach c $conflicts {
        puts "  CONFLICT         : $c"
        incr flag_count
    }
    if {$flag_count == 0} {
        puts "  (none -- all discovered data is well-formed and consistent)"
    }
    puts ""
    puts "-- Cross-check: metrics vs. limits ------------------------------------"
    set criteria_pass 0
    set criteria_fail 0
    set criteria_incomplete 0
    foreach lk [lsort [array names limits]] {
        if {[regexp {^MAX_(.+)$} $lk -> mkey]} {
            set op "<="
        } elseif {[regexp {^MIN_(.+)$} $lk -> mkey]} {
            set op ">="
        } else {
            continue
        }
        if {![info exists metrics($mkey)]} {
            puts [format "  %-20s -> INCOMPLETE (no matching metric '%s' found)" $lk $mkey]
            incr criteria_incomplete
            continue
        }
        set mval $metrics($mkey)
        set lval $limits($lk)
        if {![string is double -strict $mval] || ![string is double -strict $lval]} {
            puts [format "  %-20s -> INCOMPLETE (non-numeric value: metric=%s limit=%s)" $lk $mval $lval]
            incr criteria_incomplete
            continue
        }
        if {$op eq "<="} {
            set ok [expr {$mval <= $lval}]
        } else {
            set ok [expr {$mval >= $lval}]
        }
        if {$ok} {
            puts [format "  %-20s -> PASS (%s = %s, limit %s %s)" $lk $mkey $mval $op $lval]
            incr criteria_pass
        } else {
            puts [format "  %-20s -> FAIL (%s = %s, limit %s %s)" $lk $mkey $mval $op $lval]
            incr criteria_fail
        }
    }
    # metrics with no corresponding limit at all -- informational only
    foreach mk [lsort [array names metrics]] {
        set has_limit 0
        foreach lk [array names limits] {
            if {$lk eq "MAX_$mk" || $lk eq "MIN_$mk"} { set has_limit 1 }
        }
        if {!$has_limit} {
            puts [format "  %-20s -> INFO (metric present, no limit defined to check against)" $mk]
        }
    }

    puts ""
    puts "===================================================================="
    puts " AUTONOMOUS SIGN-OFF VERDICT"
    puts "===================================================================="
    puts "Criteria: $criteria_pass pass, $criteria_fail fail, $criteria_incomplete incomplete"
    if {$flag_count > 0} {
        puts "Data quality: $flag_count issue(s) found in discovered inputs (see flags above)."
    }
    if {$criteria_fail > 0} {
        puts "STATUS: SIGN-OFF BLOCKED -- $criteria_fail limit(s) violated."
    } elseif {$criteria_incomplete > 0} {
        puts "STATUS: SIGN-OFF INCOMPLETE -- insufficient/malformed data to fully verify."
    } else {
        puts "STATUS: SIGN-OFF CLEAR -- all checkable criteria pass."
    }
    puts "===================================================================="
}

main $argv
