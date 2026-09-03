#!/usr/bin/perl
#
# level4.pl - CDC Signoff Automation, Level 4: fix plan + waiver cleanup
#
# Usage:
#   perl level4.pl <input_dir> <output_dir>
#
# Reads (read-only, never modified):
#   <input_dir>/reports/pre_fix/cdc.rpt
#   <input_dir>/reports/pre_fix/cdc_waivers.tcl
#   <input_dir>/constraints/hack_top.sdc
#
# Writes:
#   <output_dir>/level4_fix_plan.rpt
#   <output_dir>/fix_plan.txt
#
# Re-runs the same rule engine as level2.pl/level3.pl (parsing + structural
# rules + waiver validation are duplicated here, matching the standalone-
# script layout of level1-3). Any change to the rules must be made
# identically everywhere.
#
use strict;
use warnings;

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
    print STDERR "Usage: perl level4.pl <input_dir> <output_dir>\n";
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
# helpers (same as level1-3)
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
        $line =~ s/#.*$//;
        push @lines, $line;
    }
    close $fh;
    return @lines;
}

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

sub extract {
    my ($text, $key) = @_;
    return $1 if $text =~ /(?:^|\s)\Q$key\E\s+(\S+)/;
    return undef;
}

# ---------------------------------------------------------------------------
# 1. Parse hack_top.sdc
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
# 2. Parse cdc_waivers.tcl
# ---------------------------------------------------------------------------
my @waiver_lines = read_lines($waiver_file);
my @waiver;

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
# 3. Parse cdc.rpt
# ---------------------------------------------------------------------------
my @rpt_logical = join_continuations(read_lines($rpt_file));

my $signoff_date      = undef;
my $fast_clock_period = undef;
my %cdc;
my @cdc_order;

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
# 4. Structural rules -> @violations (identical logic to level2.pl/level3.pl)
# ---------------------------------------------------------------------------
my @violations;
my %violations_by_id;

sub add_violation {
    my (%v) = @_;
    $v{status} = 'OPEN' unless defined $v{status};
    push @violations, { %v };
    if (defined $v{target_id}) {
        push @{ $violations_by_id{$v{target_id}} }, $#violations;
    }
}

for my $id (@cdc_order) {
    my $rec = $cdc{$id};
    next unless exists $clk_group{ $rec->{src} } && exists $clk_group{ $rec->{dst} };

    my $is_real = ($clk_group{ $rec->{src} } != $clk_group{ $rec->{dst} }) ? 1 : 0;
    my $pair = "$rec->{src}->$rec->{dst}";

    unless ($is_real) {
        add_violation(
            type => 'FALSE_CROSSING', object => $id, pair => $pair,
            severity => $SEVERITY{FALSE_CROSSING}, target_id => $id,
        );
        $rec->{real} = 0;
        $rec->{pair} = $pair;
        next;
    }

    if ($rec->{type} eq 'SINGLE_BIT') {
        if ($rec->{sync_ff} < 2) {
            add_violation(
                type => 'MISSING_SYNC', object => $id, pair => $pair,
                severity => $SEVERITY{MISSING_SYNC}, target_id => $id,
            );
        }
        else {
            my $dst_period = $clk_period{ $rec->{dst} };
            my $dst_is_fast = (defined $dst_period && $dst_period < $fast_clock_period) ? 1 : 0;
            if ($dst_is_fast && $rec->{sync_ff} < 3) {
                add_violation(
                    type => 'SYNC_DEPTH_LOW', object => $id, pair => $pair,
                    severity => $SEVERITY{SYNC_DEPTH_LOW}, target_id => $id,
                );
            }
        }
    }
    elsif ($rec->{type} eq 'MULTI_BIT') {
        if ($rec->{scheme} !~ /^(GRAY|FIFO|HANDSHAKE)$/) {
            add_violation(
                type => 'MULTI_BIT_UNSAFE', object => $id, pair => $pair,
                severity => $SEVERITY{MULTI_BIT_UNSAFE}, target_id => $id,
            );
        }
    }
    elsif ($rec->{type} eq 'RESET') {
        if ($rec->{scheme} ne 'RESET_SYNC') {
            add_violation(
                type => 'UNSYNC_RESET', object => $id, pair => $pair,
                severity => $SEVERITY{UNSYNC_RESET}, target_id => $id,
            );
        }
    }

    $rec->{real} = 1;
    $rec->{pair} = $pair;
}

# RECONVERGENCE
my %recv_group;
for my $id (@cdc_order) {
    my $rec = $cdc{$id};
    next unless $rec->{real};
    next unless $rec->{type} eq 'SINGLE_BIT';
    next if $rec->{bundle} eq 'NONE';
    my $key = "$rec->{bundle}|$rec->{src}|$rec->{dst}";
    push @{ $recv_group{$key} }, $id;
}

my %bundle_members;   # bundle -> [ids]  (for MERGE_BUNDLE action detail)
for my $key (sort keys %recv_group) {
    my @members = @{ $recv_group{$key} };
    next unless @members >= 2;
    next unless !grep { $cdc{$_}{scheme} ne 'TWO_FF' } @members;

    my ($bundle, $src, $dst) = split /\|/, $key;
    $bundle_members{$bundle} = [ sort @members ];
    add_violation(
        type => 'RECONVERGENCE', object => $bundle, pair => "$src->$dst",
        severity => $SEVERITY{RECONVERGENCE}, target_id => undef,
    );
}

# ---------------------------------------------------------------------------
# 5. Waiver validation (identical logic to level2.pl/level3.pl)
# ---------------------------------------------------------------------------
my @waiver_findings;   # { type, id, owner, reason(original), expires }
my %seen_waiver_id;
my %effective_waiver_for_id;

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
        elsif (grep { $violations[$_]{severity} eq 'CRITICAL' } @target_viol) {
            $is_nonwaivable = 1;
            push @findings, 'NON_WAIVABLE';
        }
    }

    for my $f (@findings) {
        push @waiver_findings, { type => $f, id => $w->{id}, owner => $w->{owner},
                                  reason => $w->{reason}, expires => $w->{expires} };
    }

    my $is_effective = !$is_stale && !$is_dup && !$is_expired
                     && !$is_nonwaivable && !$is_unused;
    $effective_waiver_for_id{ $w->{id} } = 1 if $is_effective;
}

for my $v (@violations) {
    $v->{status} = (defined $v->{target_id} && $effective_waiver_for_id{ $v->{target_id} })
                 ? 'WAIVED' : 'OPEN';
}

# ---------------------------------------------------------------------------
# 6. Corrective-action decision table
# ---------------------------------------------------------------------------
# MULTI_BIT_UNSAFE scheme choice: justified from the signal's base name (with
# any [msb:lsb] bit-range stripped) and its width. This is a heuristic - not
# specified numerically in the doc - documented here so it can be reviewed:
#   name matches /cnt|count|addr|index|ptr/  -> GRAY  (monotonic, one-bit-at-
#       a-time changes are exactly what Gray coding is safe for)
#   name matches /data|stream|payload|bus|pkt|packet/ -> FIFO (wide payload,
#       needs a buffered handoff)
#   otherwise -> HANDSHAKE (sporadic/control signal; a request/ack pair is
#       the simplest correct option)
sub choose_multibit_scheme {
    my ($signal) = @_;
    my ($base, $msb, $lsb) = $signal =~ /^(.*)\[(\d+):(\d+)\]$/;
    $base = $signal unless defined $base;
    my $width = (defined $msb && defined $lsb) ? abs($msb - $lsb) + 1 : 1;

    if ($base =~ /cnt|count|addr|index|ptr/i) {
        return ('GRAY', "signal '$signal' ($width-bit) is counter/address-like; "
                       . "Gray coding guarantees only one bit changes per transition");
    }
    elsif ($base =~ /data|stream|payload|bus|pkt|packet/i) {
        return ('FIFO', "signal '$signal' ($width-bit) is a data payload bus; "
                       . "an async FIFO gives a safe buffered handoff for streaming data");
    }
    else {
        return ('HANDSHAKE', "signal '$signal' ($width-bit) looks like a sporadic/control "
                            . "transfer; a request/ack handshake is the simplest correct option");
    }
}

my @fixes;   # { id, action, before, target, pair, reason }

for my $v (@violations) {
    next unless $v->{status} eq 'OPEN';

    if ($v->{type} eq 'MISSING_SYNC') {
        my $rec = $cdc{ $v->{object} };
        my $dst_period = $clk_period{ $rec->{dst} };
        my $fast = (defined $dst_period && $dst_period < $fast_clock_period) ? 1 : 0;
        my $target_ff = $fast ? 3 : 2;
        push @fixes, {
            id => $v->{object}, action => 'ADD_SYNC',
            before => "SCHEME=$rec->{scheme},SYNC_FF=$rec->{sync_ff}",
            target => "SCHEME=TWO_FF,SYNC_FF=$target_ff",
            pair => $v->{pair},
            reason => "SYNC_FF=$rec->{sync_ff} is below the minimum synchronizer depth"
                    . ($fast ? " (destination clock is fast, needs $target_ff flops)"
                             : " (needs $target_ff flops)")
                    . ". Expected post-fix: SYNC_FF=$target_ff, MISSING_SYNC cleared.",
        };
    }
    elsif ($v->{type} eq 'SYNC_DEPTH_LOW') {
        my $rec = $cdc{ $v->{object} };
        push @fixes, {
            id => $v->{object}, action => 'DEEPEN_SYNC',
            before => "SYNC_FF=$rec->{sync_ff}",
            target => 'SYNC_FF=3',
            pair => $v->{pair},
            reason => "destination clock is fast (period < FAST_CLOCK_PERIOD_NS); "
                    . "deepen synchronizer from $rec->{sync_ff} to 3 flops. "
                    . "Expected post-fix: SYNC_FF=3, SYNC_DEPTH_LOW cleared.",
        };
    }
    elsif ($v->{type} eq 'MULTI_BIT_UNSAFE') {
        my $rec = $cdc{ $v->{object} };
        my ($scheme, $why) = choose_multibit_scheme($rec->{signal});
        push @fixes, {
            id => $v->{object}, action => 'CONVERT_SCHEME',
            before => "SCHEME=$rec->{scheme}",
            target => "SCHEME=$scheme",
            pair => $v->{pair},
            reason => "$why; converting from SCHEME=$rec->{scheme}. "
                    . "Expected post-fix: SCHEME=$scheme, MULTI_BIT_UNSAFE cleared.",
        };
    }
    elsif ($v->{type} eq 'UNSYNC_RESET') {
        my $rec = $cdc{ $v->{object} };
        push @fixes, {
            id => $v->{object}, action => 'ADD_RESET_SYNC',
            before => "SCHEME=$rec->{scheme}",
            target => 'SCHEME=RESET_SYNC',
            pair => $v->{pair},
            reason => "asynchronous reset crossing has no reset synchronizer. "
                    . "Expected post-fix: SCHEME=RESET_SYNC, UNSYNC_RESET cleared.",
        };
    }
    elsif ($v->{type} eq 'RECONVERGENCE') {
        my $bundle = $v->{object};
        my @members = @{ $bundle_members{$bundle} || [] };
        push @fixes, {
            id => $bundle, action => 'MERGE_BUNDLE',
            before => 'SCHEME=TWO_FF (independent per-signal, members '
                    . join(',', @members) . ')',
            target => 'SCHEME=HANDSHAKE (single bundle-wide qualifier)',
            pair => $v->{pair},
            reason => "members " . join(',', @members) . " are synchronized "
                    . "independently and can recombine with a one-cycle skew; "
                    . "replace with one common HANDSHAKE qualifier for the whole bundle. "
                    . "Expected post-fix: single shared qualifier, RECONVERGENCE cleared.",
        };
    }
    elsif ($v->{type} eq 'FALSE_CROSSING') {
        my $rec = $cdc{ $v->{object} };
        push @fixes, {
            id => $v->{object}, action => 'DOCUMENT',
            before => 'UNDOCUMENTED',
            target => 'WAIVE_PERMANENT',
            pair => $v->{pair},
            reason => "SRC_CLK and DST_CLK are in the same synchronous clock group, "
                    . "so this is not a true CDC; add a permanent, owned waiver "
                    . "(or remove the record) so it is not re-flagged. "
                    . "Expected post-fix: crossing documented, no longer analyzed as a CDC.",
        };
    }
}

my @waiver_actions;   # { id, action, reason }
for my $wf (@waiver_findings) {
    if ($wf->{type} eq 'STALE') {
        push @waiver_actions, { id => $wf->{id}, action => 'REMOVE_WAIVER',
            reason => "waiver targets CDC_ID=$wf->{id}, which no longer exists in cdc.rpt; delete it" };
    }
    elsif ($wf->{type} eq 'DUPLICATE') {
        push @waiver_actions, { id => $wf->{id}, action => 'REMOVE_WAIVER',
            reason => "duplicate waiver entry for CDC_ID=$wf->{id}; keep the first occurrence, delete this one" };
    }
    elsif ($wf->{type} eq 'EXPIRED') {
        push @waiver_actions, { id => $wf->{id}, action => 'RENEW_OR_FIX',
            reason => "waiver expired $wf->{expires} (before signoff date $signoff_date); "
                    . "fix the underlying crossing (see the matching FIX action) and delete this waiver" };
    }
    elsif ($wf->{type} eq 'NON_WAIVABLE') {
        push @waiver_actions, { id => $wf->{id}, action => 'REJECT_WAIVER',
            reason => "waiver targets a CRITICAL violation on CDC_ID=$wf->{id}, which cannot be waived; "
                    . "delete the waiver and fix the crossing" };
    }
    elsif ($wf->{type} eq 'UNUSED') {
        # Not in the decision table (which lists STALE/DUPLICATE/EXPIRED/
        # NON_WAIVABLE only) - treated as a cleanup case in the same spirit
        # as STALE/DUPLICATE, since the waiver is dead weight.
        push @waiver_actions, { id => $wf->{id}, action => 'REMOVE_WAIVER',
            reason => "waiver for CDC_ID=$wf->{id} has no matching open violation to waive; safe to remove" };
    }
}

# ---------------------------------------------------------------------------
# 7. Emit submit_here/level4_fix_plan.rpt
# ---------------------------------------------------------------------------
my $rpt_out = "$output_dir/level4_fix_plan.rpt";
open(my $out, '>', $rpt_out) or do {
    print STDERR "ERROR: cannot write $rpt_out: $!\n";
    exit 1;
};

for my $f (@fixes) {
    print $out "FIX ID=$f->{id} ACTION=$f->{action} BEFORE=$f->{before} "
             . "TARGET=$f->{target} PAIR=$f->{pair} REASON=$f->{reason}\n";
}
print $out "\n";
for my $wa (@waiver_actions) {
    print $out "WAIVER_ACTION ID=$wa->{id} ACTION=$wa->{action} REASON=$wa->{reason}\n";
}
print $out "\n";

my $total_actions = scalar(@fixes) + scalar(@waiver_actions);
print $out "TOTAL_ACTIONS=$total_actions\n";
print $out "EXPECTED_OPEN_CRITICAL_AFTER=0\n";
print $out "EXPECTED_OPEN_MAJOR_AFTER=0\n";
print $out "EXPECTED_INVALID_WAIVERS_AFTER=0\n";

close $out;

# ---------------------------------------------------------------------------
# 8. Emit submit_here/fix_plan.txt - one action per line, sorted by CDC_ID,
#    machine-readable so Level 5 can verify each action against the post-fix
#    dataset.
# ---------------------------------------------------------------------------
my @plan_lines;
for my $f (@fixes) {
    push @plan_lines, { id => $f->{id}, line => "ID=$f->{id} ACTION=$f->{action} TARGET=$f->{target}" };
}
for my $wa (@waiver_actions) {
    push @plan_lines, { id => $wa->{id}, line => "ID=$wa->{id} ACTION=$wa->{action} TARGET=DELETE_WAIVER" };
}

my $txt_out = "$output_dir/fix_plan.txt";
open(my $txt, '>', $txt_out) or do {
    print STDERR "ERROR: cannot write $txt_out: $!\n";
    exit 1;
};
for my $p (sort { $a->{id} cmp $b->{id} } @plan_lines) {
    print $txt "$p->{line}\n";
}
close $txt;

print "Level 4 complete: wrote $rpt_out and $txt_out\n";
exit 0;
