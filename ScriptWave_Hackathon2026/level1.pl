#!/usr/bin/perl
#
# level1.pl - CDC Signoff Automation, Level 1: Parse + inventory
#
# Usage:
#   perl level1.pl <input_dir> <output_dir>
#
# Reads (read-only, never modified):
#   <input_dir>/reports/pre_fix/cdc.rpt
#   <input_dir>/reports/pre_fix/cdc_waivers.tcl
#   <input_dir>/constraints/hack_top.sdc
#
# Writes:
#   <output_dir>/level1_baseline.rpt
#
use strict;
use warnings;

# ---------------------------------------------------------------------------
# 0. Arguments and input file existence
# ---------------------------------------------------------------------------
my ($input_dir, $output_dir) = @ARGV;

if (!defined $input_dir || !defined $output_dir) {
    print STDERR "Usage: perl level1.pl <input_dir> <output_dir>\n";
    exit 1;
}

my $rpt_file    = "$input_dir/reports/pre_fix/cdc.rpt";
my $waiver_file = "$input_dir/reports/pre_fix/cdc_waivers.tcl";
my $sdc_file    = "$input_dir/constraints/hack_top.sdc";

for my $f ($rpt_file, $waiver_file, $sdc_file) {
    unless (-e $f) {
        print STDERR "ERROR: required input file not found: $f\n";
        exit 1;
    }
}

unless (-d $output_dir) {
    mkdir $output_dir
        or do { print STDERR "ERROR: cannot create output dir $output_dir: $!\n"; exit 1; };
}

my $input_status = 'PASS';   # downgraded to FAIL below if something fundamental is missing

# ---------------------------------------------------------------------------
# helper: read a file into an array of comment-stripped, chomped lines
# ---------------------------------------------------------------------------
sub read_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or do {
        print STDERR "ERROR: cannot open $path: $!\n";
        exit 1;
    };
    my @lines;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*$//;          # strip comments
        push @lines, $line;
    }
    close $fh;
    return @lines;
}

# helper: join backslash-continued physical lines into logical lines
sub join_continuations {
    my (@raw) = @_;
    my @logical;
    my $acc;
    for my $line (@raw) {
        if (!defined $acc) {
            next unless $line =~ /\S/;   # skip blank lines between records
            $acc = $line;
        } else {
            $acc .= ' ' . $line;
        }
        if ($acc =~ /\\\s*$/) {
            $acc =~ s/\\\s*$//;         # strip trailing backslash, keep accumulating
        } else {
            push @logical, $acc;
            $acc = undef;
        }
    }
    push @logical, $acc if defined $acc;
    return @logical;
}

# helper: pull "KEY value" out of a logical line, KEY match is whole-word
sub extract {
    my ($text, $key) = @_;
    return $1 if $text =~ /(?:^|\s)\Q$key\E\s+(\S+)/;
    return undef;
}

# ---------------------------------------------------------------------------
# 1. Parse hack_top.sdc: create_clock (name, period) + set_clock_groups
# ---------------------------------------------------------------------------
my @sdc_logical = join_continuations(read_lines($sdc_file));

my %clk_period;   # clock -> period (string, printed as-is)
my %clk_group;    # clock -> group number
my $group_counter = 0;

for my $line (@sdc_logical) {
    next unless $line =~ /\S/;

    if ($line =~ /create_clock\b/) {
        my ($name)   = $line =~ /-name\s+\{?([^\s{}]+)\}?/;
        my ($period) = $line =~ /-period\s+\{?([^\s{}]+)\}?/;
        if (defined $name && defined $period) {
            $clk_period{$name} = $period;
        }
    }

    if ($line =~ /set_clock_groups\b/) {
        while ($line =~ /-group\s*\{([^}]*)\}/g) {
            $group_counter++;
            for my $c (split(/\s+/, $1)) {
                next unless length $c;
                $clk_group{$c} = $group_counter;
            }
        }
    }
}

# Any clock that was create_clock'd but never placed in an explicit -group
# is asynchronous to everything else: give it its own singleton group.
for my $c (sort keys %clk_period) {
    unless (exists $clk_group{$c}) {
        $group_counter++;
        $clk_group{$c} = $group_counter;
    }
}

my $clocks_defined = scalar keys %clk_period;
my %distinct_groups = map { $_ => 1 } values %clk_group;
my $clock_groups_count = scalar keys %distinct_groups;

if ($clocks_defined == 0) {
    $input_status = 'FAIL';
}

# ---------------------------------------------------------------------------
# skipped_records is shared by both the waiver parser and the cdc.rpt parser:
# "any record that cannot be parsed" applies to either file.
# ---------------------------------------------------------------------------
my $skipped_records = 0;

# ---------------------------------------------------------------------------
# 2. Parse cdc_waivers.tcl into a proper list of waivers: id, reason, owner,
#    expires. (Validating each waiver's legitimacy -- stale/duplicate/expired/
#    non-waivable/unused -- is Level 2's job; here we only build the list.)
# ---------------------------------------------------------------------------
my @waiver_lines = read_lines($waiver_file);
my @waiver;   # list of { id, reason, owner, expires }

for my $line (@waiver_lines) {
    next unless $line =~ /\S/;
    next unless $line =~ /waive_cdc\b/;

    my ($id)      = $line =~ /-id\s+(\S+)/;
    my ($reason)  = $line =~ /-reason\s+"([^"]*)"/;
    ($reason)     = $line =~ /-reason\s+(\S+)/ unless defined $reason;
    my ($owner)   = $line =~ /-owner\s+(\S+)/;
    my ($expires) = $line =~ /-expires\s+(\S+)/;

    unless (defined $id && defined $reason && defined $owner && defined $expires) {
        $skipped_records++;
        print STDERR "WARNING: skipping malformed waiver record: $line\n";
        next;
    }

    push @waiver, { id => $id, reason => $reason, owner => $owner, expires => $expires };
}

my $waivers_in_file = scalar @waiver;

# ---------------------------------------------------------------------------
# 3. Parse cdc.rpt: SIGNOFF_DATE, FAST_CLOCK_PERIOD_NS, CDC_ID records
# ---------------------------------------------------------------------------
my @rpt_logical = join_continuations(read_lines($rpt_file));

my $signoff_date        = undef;
my $fast_clock_period   = undef;
my %cdc;                 # id -> { src, dst, signal, type, sync_ff, scheme, bundle }
my %undefined_clocks;    # clock name -> 1
my $total_crossings      = 0;

for my $line (@rpt_logical) {
    next unless $line =~ /\S/;

    if ($line =~ /(?:^|\s)SIGNOFF_DATE\s+(\S+)/) {
        $signoff_date = $1;
        next;
    }

    if ($line =~ /(?:^|\s)FAST_CLOCK_PERIOD_NS\s+(\S+)/) {
        $fast_clock_period = $1;
        next;
    }

    if ($line =~ /(?:^|\s)CDC_ID\s+/) {
        $total_crossings++;

        my $id      = extract($line, 'CDC_ID');
        my $src     = extract($line, 'SRC_CLK');
        my $dst     = extract($line, 'DST_CLK');
        my $signal  = extract($line, 'SIGNAL');
        my $type    = extract($line, 'TYPE');
        my $sync_ff = extract($line, 'SYNC_FF');
        my $scheme  = extract($line, 'SCHEME');
        my $bundle  = extract($line, 'BUNDLE');

        my $ok = 1;
        $ok = 0 unless defined $id && defined $src && defined $dst
                    && defined $signal && defined $type
                    && defined $sync_ff && defined $scheme && defined $bundle;
        $ok = 0 if defined $type && $type !~ /^(SINGLE_BIT|MULTI_BIT|RESET)$/;
        $ok = 0 if defined $sync_ff && $sync_ff !~ /^\d+$/;
        $ok = 0 if defined $scheme
                 && $scheme !~ /^(NONE|TWO_FF|GRAY|FIFO|HANDSHAKE|RESET_SYNC)$/;
        $ok = 0 if defined $id && exists $cdc{$id};   # duplicate CDC_ID

        unless ($ok) {
            $skipped_records++;
            print STDERR "WARNING: skipping malformed/duplicate record: $line\n";
            next;
        }

        for my $clk ($src, $dst) {
            $undefined_clocks{$clk} = 1 unless exists $clk_period{$clk};
        }

        $cdc{$id} = {
            src => $src, dst => $dst, signal => $signal, type => $type,
            sync_ff => $sync_ff, scheme => $scheme, bundle => $bundle,
        };
        next;
    }

    # any other non-blank logical line in cdc.rpt is unrecognized
    $skipped_records++;
    print STDERR "WARNING: skipping unrecognized line: $line\n";
}

if (!defined $signoff_date || !defined $fast_clock_period) {
    $input_status = 'FAIL';
}
$signoff_date      = 'UNKNOWN' unless defined $signoff_date;
$fast_clock_period = 'UNKNOWN' unless defined $fast_clock_period;

# ---------------------------------------------------------------------------
# 4. Classify real vs. false crossings; tally per-type and per-pair counts
# ---------------------------------------------------------------------------
my $real_crossings  = 0;
my $single_bit = 0;
my $multi_bit  = 0;
my $reset_cnt  = 0;

# pair -> { crossings, single_bit, multi_bit, reset }
my %pair;

for my $id (keys %cdc) {
    my $rec = $cdc{$id};

    $single_bit++ if $rec->{type} eq 'SINGLE_BIT';
    $multi_bit++  if $rec->{type} eq 'MULTI_BIT';
    $reset_cnt++  if $rec->{type} eq 'RESET';

    # A crossing whose clock isn't in the SDC can't be classified real/false.
    next if $undefined_clocks{$rec->{src}} || $undefined_clocks{$rec->{dst}};

    my $src_group = $clk_group{$rec->{src}};
    my $dst_group = $clk_group{$rec->{dst}};
    my $is_real = ($src_group != $dst_group) ? 1 : 0;

    $rec->{real} = $is_real;
    $real_crossings++ if $is_real;

    next unless $is_real;   # pair table is defined over real crossings only

    my $key = "$rec->{src}->$rec->{dst}";
    $pair{$key}{crossings}++;
    $pair{$key}{single_bit}++ if $rec->{type} eq 'SINGLE_BIT';
    $pair{$key}{multi_bit}++  if $rec->{type} eq 'MULTI_BIT';
    $pair{$key}{reset}++      if $rec->{type} eq 'RESET';
}

# Spec formula, verbatim: FALSE_CROSSINGS = TOTAL_CROSSINGS - REAL_CROSSINGS.
# This deliberately folds skipped/malformed records and crossings with an
# undefined clock into the "false" bucket, since only REAL_CROSSINGS is
# independently defined; SKIPPED_RECORDS and UNDEFINED_CLOCKS are still
# reported separately so nothing is hidden.
my $false_crossings = $total_crossings - $real_crossings;

my $clock_pairs = scalar keys %pair;

# ---------------------------------------------------------------------------
# 5. Emit submit_here/level1_baseline.rpt
# ---------------------------------------------------------------------------
my $out_file = "$output_dir/level1_baseline.rpt";
open(my $out, '>', $out_file) or do {
    print STDERR "ERROR: cannot write $out_file: $!\n";
    exit 1;
};

my $undef_str = %undefined_clocks
    ? join(',', sort keys %undefined_clocks)
    : 'NONE';

print $out "BATCH=02\n";
print $out "INPUT_STATUS=$input_status\n";
print $out "SIGNOFF_DATE=$signoff_date\n";
print $out "FAST_CLOCK_PERIOD_NS=$fast_clock_period\n";
print $out "CLOCKS_DEFINED=$clocks_defined\n";
print $out "CLOCK_GROUPS=$clock_groups_count\n";
print $out "TOTAL_CROSSINGS=$total_crossings\n";
print $out "REAL_CROSSINGS=$real_crossings\n";
print $out "FALSE_CROSSINGS=$false_crossings\n";
print $out "CLOCK_PAIRS=$clock_pairs\n";
print $out "SINGLE_BIT=$single_bit MULTI_BIT=$multi_bit RESET=$reset_cnt\n";
print $out "WAIVERS_IN_FILE=$waivers_in_file\n";
print $out "UNDEFINED_CLOCKS=$undef_str\n";
print $out "SKIPPED_RECORDS=$skipped_records\n";
print $out "\n";
print $out "# one line per clock, sorted by name\n";
for my $c (sort keys %clk_period) {
    print $out "CLOCK=$c PERIOD=$clk_period{$c} GROUP=$clk_group{$c}\n";
}
print $out "\n";
print $out "# one line per clock pair, sorted by name\n";
for my $p (sort keys %pair) {
    my $r = $pair{$p};
    printf $out "PAIR=%s CROSSINGS=%d SINGLE_BIT=%d MULTI_BIT=%d RESET=%d\n",
        $p, $r->{crossings}, $r->{single_bit} // 0, $r->{multi_bit} // 0, $r->{reset} // 0;
}

close $out;

print "Level 1 complete: wrote $out_file\n";
exit 0;
