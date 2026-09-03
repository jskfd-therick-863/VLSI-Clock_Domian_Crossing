#!/usr/bin/perl
#
# level2.pl - CDC Signoff Automation, Level 2: apply CDC rules, validate waivers
#
# Usage:
#   perl level2.pl <input_dir> <output_dir>
#
# Reads (read-only, never modified):
#   <input_dir>/reports/pre_fix/cdc.rpt
#   <input_dir>/reports/pre_fix/cdc_waivers.tcl
#   <input_dir>/constraints/hack_top.sdc
#
# Writes:
#   <output_dir>/level2_violations.rpt
#
use strict;
use warnings;

# ---------------------------------------------------------------------------
# Severity assignment (not fully pinned down by the spec, so fixed here and
# applied consistently):
#   MISSING_SYNC     CRITICAL  - no synchronizer at all, direct metastability risk
#   UNSYNC_RESET     CRITICAL  - unsynchronized async reset, direct metastability risk
#   SYNC_DEPTH_LOW   MAJOR     - synchronizer present but shallow for a fast dest
#   MULTI_BIT_UNSAFE MAJOR     - bus crossing without a safe multi-bit scheme
#   RECONVERGENCE    MAJOR     - independently synced bits can recombine w/ skew
#   FALSE_CROSSING   MINOR     - not a real crossing at all; informational only
# Only MAJOR/MINOR violations are waivable (per section 5 step 3 of the spec);
# a waiver targeting a CRITICAL violation is therefore NON_WAIVABLE.
# ---------------------------------------------------------------------------
my %SEVERITY = (
    MISSING_SYNC     => 'CRITICAL',
    UNSYNC_RESET      => 'CRITICAL',
    SYNC_DEPTH_LOW    => 'MAJOR',
    MULTI_BIT_UNSAFE  => 'MAJOR',
    RECONVERGENCE     => 'MAJOR',
    FALSE_CROSSING    => 'MINOR',
);

# ---------------------------------------------------------------------------
# 0. Arguments and input file existence
# ---------------------------------------------------------------------------
my ($input_dir, $output_dir) = @ARGV;

if (!defined $input_dir || !defined $output_dir) {
    print STDERR "Usage: perl level2.pl <input_dir> <output_dir>\n";
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
            next unless $line =~ /\S/;
            $acc = $line;
        } else {
            $acc .= ' ' . $line;
        }
        if ($acc =~ /\\\s*$/) {
            $acc =~ s/\\\s*$//;
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

my %clk_period;
my %clk_group;
my $group_counter = 0;

for my $line (@sdc_logical) {
    next unless $line =~ /\S/;

    if ($line =~ /create_clock\b/) {
        my ($name)   = $line =~ /-name\s+\{?([^\s{}]+)\}?/;
        my ($period) = $line =~ /-period\s+\{?([^\s{}]+)\}?/;
        $clk_period{$name} = $period if defined $name && defined $period;
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

for my $c (sort keys %clk_period) {
    unless (exists $clk_group{$c}) {
        $group_counter++;
        $clk_group{$c} = $group_counter;
    }
}

# ---------------------------------------------------------------------------
# 2. Parse cdc_waivers.tcl into an ordered list: id, reason, owner, expires
# ---------------------------------------------------------------------------
my @waiver_lines = read_lines($waiver_file);
my @waiver;   # ordered list of { id, reason, owner, expires }

for my $line (@waiver_lines) {
    next unless $line =~ /\S/;
    next unless $line =~ /waive_cdc\b/;

    my ($id)      = $line =~ /-id\s+(\S+)/;
    my ($reason)  = $line =~ /-reason\s+"([^"]*)"/;
    ($reason)     = $line =~ /-reason\s+(\S+)/ unless defined $reason;
    my ($owner)   = $line =~ /-owner\s+(\S+)/;
    my ($expires) = $line =~ /-expires\s+(\S+)/;

    unless (defined $id && defined $reason && defined $owner && defined $expires) {
        print STDERR "WARNING: skipping malformed waiver record: $line\n";
        next;
    }

    push @waiver, { id => $id, reason => $reason, owner => $owner, expires => $expires };
}

# ---------------------------------------------------------------------------
# 3. Parse cdc.rpt: SIGNOFF_DATE, FAST_CLOCK_PERIOD_NS, CDC_ID records
# ---------------------------------------------------------------------------
my @rpt_logical = join_continuations(read_lines($rpt_file));

my $signoff_date      = undef;
my $fast_clock_period = undef;
my %cdc;   # id -> { src, dst, signal, type, sync_ff, scheme, bundle }
my @cdc_order;   # preserve first-seen order for stable output

for my $line (@rpt_logical) {
    next unless $line =~ /\S/;

    if ($line =~ /(?:^|\s)SIGNOFF_DATE\s+(\S+)/) { $signoff_date = $1; next; }
    if ($line =~ /(?:^|\s)FAST_CLOCK_PERIOD_NS\s+(\S+)/) { $fast_clock_period = $1; next; }

    if ($line =~ /(?:^|\s)CDC_ID\s+/) {
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
        $ok = 0 if defined $id && exists $cdc{$id};

        unless ($ok) {
            print STDERR "WARNING: skipping malformed/duplicate record: $line\n";
            next;
        }

        $cdc{$id} = {
            src => $src, dst => $dst, signal => $signal, type => $type,
            sync_ff => $sync_ff, scheme => $scheme, bundle => $bundle,
        };
        push @cdc_order, $id;
        next;
    }

    print STDERR "WARNING: skipping unrecognized line: $line\n";
}

unless (defined $signoff_date && defined $fast_clock_period) {
    print STDERR "ERROR: cdc.rpt missing SIGNOFF_DATE or FAST_CLOCK_PERIOD_NS\n";
    exit 1;
}

# ---------------------------------------------------------------------------
# 4. Classify real vs false, apply structural rules to real crossings
# ---------------------------------------------------------------------------
# violations: ordered list of { type, object, pair, measured, expected,
#                                severity, status, target_id (or undef) }
my @violations;
# violations_by_id: CDC_ID -> list of indices into @violations (for waiver lookup)
my %violations_by_id;

sub add_violation {
    my (%v) = @_;
    $v{status} = 'OPEN' unless defined $v{status};
    push @violations, { %v };
    if (defined $v{target_id}) {
        push @{ $violations_by_id{$v{target_id}} }, $#violations;
    }
}

# 4a. FALSE_CROSSING + real-crossing structural rules
for my $id (@cdc_order) {
    my $rec = $cdc{$id};

    # Crossings naming a clock absent from the SDC cannot be classified.
    next unless exists $clk_group{ $rec->{src} } && exists $clk_group{ $rec->{dst} };

    my $is_real = ($clk_group{ $rec->{src} } != $clk_group{ $rec->{dst} }) ? 1 : 0;
    my $pair = "$rec->{src}->$rec->{dst}";

    unless ($is_real) {
        add_violation(
            type => 'FALSE_CROSSING', object => $id, pair => $pair,
            measured => "GROUP=$clk_group{$rec->{src}}",
            expected => 'FALSE_CROSSING',
            severity => $SEVERITY{FALSE_CROSSING},
            target_id => $id,
        );
        next;
    }

    if ($rec->{type} eq 'SINGLE_BIT') {
        if ($rec->{sync_ff} < 2) {
            add_violation(
                type => 'MISSING_SYNC', object => $id, pair => $pair,
                measured => "SYNC_FF=$rec->{sync_ff}", expected => 'SYNC_FF>=2',
                severity => $SEVERITY{MISSING_SYNC}, target_id => $id,
            );
        }
        else {
            my $dst_period = $clk_period{ $rec->{dst} };
            my $dst_is_fast = (defined $dst_period && $dst_period < $fast_clock_period) ? 1 : 0;
            if ($dst_is_fast && $rec->{sync_ff} < 3) {
                add_violation(
                    type => 'SYNC_DEPTH_LOW', object => $id, pair => $pair,
                    measured => "SYNC_FF=$rec->{sync_ff}", expected => 'SYNC_FF>=3',
                    severity => $SEVERITY{SYNC_DEPTH_LOW}, target_id => $id,
                );
            }
        }
    }
    elsif ($rec->{type} eq 'MULTI_BIT') {
        if ($rec->{scheme} !~ /^(GRAY|FIFO|HANDSHAKE)$/) {
            add_violation(
                type => 'MULTI_BIT_UNSAFE', object => $id, pair => $pair,
                measured => "SCHEME=$rec->{scheme}", expected => 'SCHEME=GRAY|FIFO|HANDSHAKE',
                severity => $SEVERITY{MULTI_BIT_UNSAFE}, target_id => $id,
            );
        }
    }
    elsif ($rec->{type} eq 'RESET') {
        if ($rec->{scheme} ne 'RESET_SYNC') {
            add_violation(
                type => 'UNSYNC_RESET', object => $id, pair => $pair,
                measured => "SCHEME=$rec->{scheme}", expected => 'SCHEME=RESET_SYNC',
                severity => $SEVERITY{UNSYNC_RESET}, target_id => $id,
            );
        }
    }

    $rec->{real} = 1;
    $rec->{pair} = $pair;
}

# 4b. RECONVERGENCE: real SINGLE_BIT crossings grouped by (bundle, src, dst)
my %recv_group;   # "bundle|src|dst" -> list of ids
for my $id (@cdc_order) {
    my $rec = $cdc{$id};
    next unless $rec->{real};
    next unless $rec->{type} eq 'SINGLE_BIT';
    next if $rec->{bundle} eq 'NONE';
    my $key = "$rec->{bundle}|$rec->{src}|$rec->{dst}";
    push @{ $recv_group{$key} }, $id;
}

for my $key (sort keys %recv_group) {
    my @members = @{ $recv_group{$key} };
    next unless @members >= 2;
    next unless !grep { $cdc{$_}{scheme} ne 'TWO_FF' } @members;

    my ($bundle, $src, $dst) = split /\|/, $key;
    add_violation(
        type => 'RECONVERGENCE', object => $bundle, pair => "$src->$dst",
        measured => 'MEMBERS=' . join(',', sort @members),
        expected => 'RECONVERGENCE',
        severity => $SEVERITY{RECONVERGENCE},
        target_id => undef,   # bundle-level; no CDC_ID waiver can target it directly
    );
}

# ---------------------------------------------------------------------------
# 5. Validate waivers: stale, duplicate, expired, non-waivable, unused
# ---------------------------------------------------------------------------
my @waiver_findings;   # { type, id, owner, detail }
my %seen_waiver_id;
my %effective_waiver_for_id;   # CDC_ID -> 1 if it has an effective waiver

for my $w (@waiver) {
    my @findings;

    my $is_stale = !exists $cdc{ $w->{id} };
    push @findings, 'STALE' if $is_stale;

    my $is_dup = exists $seen_waiver_id{ $w->{id} };
    push @findings, 'DUPLICATE' if $is_dup;
    $seen_waiver_id{ $w->{id} } = 1;

    my $is_expired = ($w->{expires} lt $signoff_date);
    push @findings, 'EXPIRED' if $is_expired;

    my $is_nonwaivable = 0;
    my $is_unused = 0;
    unless ($is_stale) {
        my @target_viol = @{ $violations_by_id{ $w->{id} } || [] };
        if (!@target_viol) {
            $is_unused = 1;
            push @findings, 'UNUSED';
        }
        else {
            # non-waivable if ANY targeted violation is CRITICAL
            if (grep { $violations[$_]{severity} eq 'CRITICAL' } @target_viol) {
                $is_nonwaivable = 1;
                push @findings, 'NON_WAIVABLE';
            }
        }
    }

    for my $f (@findings) {
        push @waiver_findings, {
            type => $f, id => $w->{id}, owner => $w->{owner}, detail => $w->{reason},
        };
    }

    my $is_effective = !$is_stale && !$is_dup && !$is_expired
                     && !$is_nonwaivable && !$is_unused;
    $effective_waiver_for_id{ $w->{id} } = 1 if $is_effective;
}

# ---------------------------------------------------------------------------
# 6. Apply WAIVED/OPEN status, tally counts, set BASELINE_STATUS
# ---------------------------------------------------------------------------
my ($open_crit, $open_major, $open_minor, $waived) = (0, 0, 0, 0);

for my $v (@violations) {
    if (defined $v->{target_id} && $effective_waiver_for_id{ $v->{target_id} }) {
        $v->{status} = 'WAIVED';
    }
    if ($v->{status} eq 'WAIVED') {
        $waived++;
    }
    else {
        $open_crit++  if $v->{severity} eq 'CRITICAL';
        $open_major++ if $v->{severity} eq 'MAJOR';
        $open_minor++ if $v->{severity} eq 'MINOR';
    }
}

my $invalid_waivers = 0;
my %invalid_waiver_ids;
for my $wf (@waiver_findings) {
    $invalid_waiver_ids{ $wf->{id} } = 1;
}
$invalid_waivers = scalar keys %invalid_waiver_ids;

my $baseline_status;
if ($open_crit > 0) {
    $baseline_status = 'FAIL';
}
elsif ($open_major > 0 || $invalid_waivers > 0) {
    $baseline_status = 'WARNING';
}
else {
    $baseline_status = 'PASS';
}

my $total_violations = scalar @violations;

# ---------------------------------------------------------------------------
# 7. Emit submit_here/level2_violations.rpt
# ---------------------------------------------------------------------------
my $out_file = "$output_dir/level2_violations.rpt";
open(my $out, '>', $out_file) or do {
    print STDERR "ERROR: cannot write $out_file: $!\n";
    exit 1;
};

for my $v (@violations) {
    print $out "VIOLATION TYPE=$v->{type} OBJECT=$v->{object} PAIR=$v->{pair} "
             . "MEASURED=$v->{measured} EXPECTED=$v->{expected} "
             . "SEVERITY=$v->{severity} STATUS=$v->{status}\n";
}
print $out "\n";
for my $wf (@waiver_findings) {
    print $out "WAIVER_FINDING TYPE=$wf->{type} ID=$wf->{id} OWNER=$wf->{owner} DETAIL=$wf->{detail}\n";
}
print $out "\n";
print $out "TOTAL_VIOLATIONS=$total_violations\n";
print $out "OPEN_CRITICAL=$open_crit OPEN_MAJOR=$open_major OPEN_MINOR=$open_minor\n";
print $out "WAIVED_VIOLATIONS=$waived\n";
print $out "INVALID_WAIVERS=$invalid_waivers\n";
print $out "BASELINE_STATUS=$baseline_status\n";

close $out;

print "Level 2 complete: wrote $out_file\n";
exit 0;
