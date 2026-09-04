# SET 1 | LEVEL 1 | HURDLE 2
# RTL File Classifier
# Usage: tclsh rtl_file_classifier_h1_2.tcl <root_directory>

if {$argc != 1} {
    puts "Usage: tclsh rtl_file_classifier_h1_2.tcl <root_directory>"
    exit 1
}

set root [file normalize [lindex $argv 0]]

if {![file exists $root]} {
    puts "ERROR: Directory not found: $root"
    exit 1
}

if {![file isdirectory $root]} {
    puts "ERROR: Not a directory: $root"
    exit 1
}

# Lists hold the discovered files for each required category.
set verilog {}
set systemverilog {}
set vhdl {}
set constraints {}
set tcl_files {}

# Recursively walk a directory.
proc scan_directory {dir} {
    global verilog systemverilog vhdl constraints tcl_files

    foreach path [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $path]} {
            scan_directory $path
            continue
        }

        set ext [string tolower [file extension $path]]

        switch -- $ext {
            ".v" {
                lappend verilog [file normalize $path]
            }
            ".sv" {
                lappend systemverilog [file normalize $path]
            }
            ".vhd" {
                lappend vhdl [file normalize $path]
            }
            ".sdc" {
                lappend constraints [file normalize $path]
            }
            ".tcl" {
                lappend tcl_files [file normalize $path]
            }
        }
    }
}

scan_directory $root

# Sort paths for deterministic output.
set verilog [lsort $verilog]
set systemverilog [lsort $systemverilog]
set vhdl [lsort $vhdl]
set constraints [lsort $constraints]
set tcl_files [lsort $tcl_files]

puts "===== RTL FILE CLASSIFIER ====="
puts "Root directory: $root"
puts ""

puts "Verilog (.v): [llength $verilog]"
foreach path $verilog {
    puts "  $path"
}

puts ""
puts "SystemVerilog (.sv): [llength $systemverilog]"
foreach path $systemverilog {
    puts "  $path"
}

puts ""
puts "VHDL (.vhd): [llength $vhdl]"
foreach path $vhdl {
    puts "  $path"
}

puts ""
puts "Constraints (.sdc): [llength $constraints]"
foreach path $constraints {
    puts "  $path"
}

puts ""
puts "Tcl (.tcl): [llength $tcl_files]"
foreach path $tcl_files {
    puts "  $path"
}

set total [expr {
    [llength $verilog] +
    [llength $systemverilog] +
    [llength $vhdl] +
    [llength $constraints] +
    [llength $tcl_files]
}]

puts ""
puts "Total classified files: $total"
