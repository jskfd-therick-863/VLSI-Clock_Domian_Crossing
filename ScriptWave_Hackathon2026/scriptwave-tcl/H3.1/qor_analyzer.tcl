# ==========================================
# LEVEL 3 - H3.1 QoR ANALYZER
# ==========================================

# Usage:
#   tclsh qor_analyzer.tcl <qor.rpt> <limits.cfg>

# Check command-line arguments
if {$argc != 2} {
    puts "Usage: tclsh qor_analyzer.tcl <qor.rpt> <limits.cfg>"
    exit 1
}

set qor_file [lindex $argv 0]
set limits_file [lindex $argv 1]

# Check that both files exist
if {![file exists $qor_file]} {
    puts "ERROR: QoR report not found: $qor_file"
    exit 1
}

if {![file exists $limits_file]} {
    puts "ERROR: Limits file not found: $limits_file"
    exit 1
}

# Arrays to store QoR values and limits
array set qor {}
array set limits {}

# ------------------------------------------
# Read QoR report
# ------------------------------------------
set fp [open $qor_file r]

while {[gets $fp line] >= 0} {
    set line [string trim $line]

    # Ignore empty lines
    if {$line eq ""} {
        continue
    }

    set fields [split $line]

    # Expected format:
    # METRIC VALUE
    if {[llength $fields] >= 2} {
        set metric [lindex $fields 0]
        set value  [lindex $fields 1]

        set qor($metric) $value
    }
}

close $fp

# ------------------------------------------
# Read limits configuration
# ------------------------------------------
set fp [open $limits_file r]

while {[gets $fp line] >= 0} {
    set line [string trim $line]

    if {$line eq ""} {
        continue
    }

    set fields [split $line]

    # Expected format:
    # LIMIT VALUE
    if {[llength $fields] >= 2} {
        set limit_name [lindex $fields 0]
        set value      [lindex $fields 1]

        set limits($limit_name) $value
    }
}

close $fp

# ------------------------------------------
# Validate required information
# ------------------------------------------
set required_qor {AREA POWER WNS VIOLATIONS}

foreach metric $required_qor {
    if {![info exists qor($metric)]} {
        puts "ERROR: Missing QoR metric: $metric"
        exit 1
    }
}

set required_limits {MAX_AREA MAX_POWER MIN_WNS MAX_VIOLATIONS}

foreach limit $required_limits {
    if {![info exists limits($limit)]} {
        puts "ERROR: Missing limit: $limit"
        exit 1
    }
}

# ------------------------------------------
# Perform QoR checks
# ------------------------------------------
set overall_status "PASS"

puts "=========================================="
puts "             QoR ANALYZER"
puts "=========================================="

# AREA
if {$qor(AREA) <= $limits(MAX_AREA)} {
    puts [format "AREA        : PASS  (%.2f <= %.2f)" \
        $qor(AREA) $limits(MAX_AREA)]
} else {
    puts [format "AREA        : FAIL  (%.2f > %.2f)" \
        $qor(AREA) $limits(MAX_AREA)]
    set overall_status "FAIL"
}

# POWER
if {$qor(POWER) <= $limits(MAX_POWER)} {
    puts [format "POWER       : PASS  (%.2f <= %.2f)" \
        $qor(POWER) $limits(MAX_POWER)]
} else {
    puts [format "POWER       : FAIL  (%.2f > %.2f)" \
        $qor(POWER) $limits(MAX_POWER)]
    set overall_status "FAIL"
}

# WNS
# WNS must be greater than or equal to MIN_WNS
if {$qor(WNS) >= $limits(MIN_WNS)} {
    puts [format "WNS         : PASS  (%.3f >= %.3f)" \
        $qor(WNS) $limits(MIN_WNS)]
} else {
    puts [format "WNS         : FAIL  (%.3f < %.3f)" \
        $qor(WNS) $limits(MIN_WNS)]
    set overall_status "FAIL"
}

# VIOLATIONS
if {$qor(VIOLATIONS) <= $limits(MAX_VIOLATIONS)} {
    puts [format "VIOLATIONS  : PASS  (%d <= %d)" \
        $qor(VIOLATIONS) $limits(MAX_VIOLATIONS)]
} else {
    puts [format "VIOLATIONS  : FAIL  (%d > %d)" \
        $qor(VIOLATIONS) $limits(MAX_VIOLATIONS)]
    set overall_status "FAIL"
}

puts "------------------------------------------"
puts "OVERALL STATUS: $overall_status"
puts "=========================================="
