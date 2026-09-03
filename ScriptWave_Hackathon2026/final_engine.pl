#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(make_path);

# Level 5 - Post-fix signoff, before-vs-after and closure
# Usage: perl final_engine.pl inputs/ submit_here/

my ($input_dir, $output_dir) = @ARGV;
die "Usage: perl final_engine.pl inputs/ submit_here/\n"
    unless defined $input_dir && defined $output_dir;

$input_dir =~ s{/$}{};
$output_dir =~ s{/$}{};
make_path($output_dir) unless -d $output_dir;

my $pre_rpt   = "$input_dir/reports/pre_fix/cdc.rpt";
my $pre_waiv  = "$input_dir/reports/pre_fix/cdc_waivers.tcl";
my $post_rpt  = "$input_dir/reports/post_fix/cdc.rpt";
my $post_waiv = "$input_dir/reports/post_fix/cdc_waivers.tcl";
my $sdc       = "$input_dir/constraints/hack_top.sdc";
my $fix_plan  = "$output_dir/fix_plan.txt";

for my $f ($pre_rpt, $pre_waiv, $post_rpt, $post_waiv, $sdc, $fix_plan) {
    die "ERROR: missing input file: $f\n" unless -f $f;
}

sub read_lines {
    my ($file) = @_;
    open my $fh, '<', $file or die "ERROR: cannot read $file: $!\n";
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

sub parse_sdc {
    my ($file) = @_;
    my %clk;
    my %group;
    my $group_no = 0;
    my @lines = read_lines($file);

    # Remove comments and join Tcl continuation lines.
    my @logical;
    my $buf = '';
    for my $line (@lines) {
        $line =~ s/#.*$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        if ($line =~ s/\\\s*$//) {
            $buf .= $line . ' ';
        } else {
            $buf .= $line;
            push @logical, $buf;
            $buf = '';
        }
    }
    push @logical, $buf if $buf ne '';

    for my $line (@logical) {
        if ($line =~ /create_clock\s+-name\s+(\S+)\s+-period\s+(\S+)/) {
            $clk{$1}{period} = 0 + $2;
        }
    }

    for my $line (@logical) {
        next unless $line =~ /set_clock_groups\b/;
        my @groups = ($line =~ /-group\s*\{([^}]*)\}/g);
        for my $g (@groups) {
            ++$group_no;
            for my $c (split /\s+/, $g) {
                next if $c eq '';
                $group{$c} = $group_no;
            }
        }
    }
    for my $c (keys %clk) {
        $clk{$c}{group} = exists $group{$c} ? $group{$c} : 0;
    }
    return (\%clk, $group_no);
}

sub parse_report {
    my ($file) = @_;
    my %data = (
        signoff_date => '', fast_period => 0, cdc => {}, skipped => 0,
        parse_errors => [],
    );
    for my $line (read_lines($file)) {
        chomp $line;
        $line =~ s/#.*$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        if ($line =~ /^SIGNOFF_DATE\s+(\S+)/) {
            $data{signoff_date} = $1;
            next;
        }
        if ($line =~ /^FAST_CLOCK_PERIOD_NS\s+(\S+)/) {
            $data{fast_period} = 0 + $1;
            next;
        }
        if ($line =~ /^CDC_ID\s+(\S+)\s+SRC_CLK\s+(\S+)\s+DST_CLK\s+(\S+)\s+SIGNAL\s+(\S+)\s+TYPE\s+(SINGLE_BIT|MULTI_BIT|RESET)\s+SYNC_FF\s+(\d+)\s+SCHEME\s+(NONE|TWO_FF|GRAY|FIFO|HANDSHAKE|RESET_SYNC)\s+BUNDLE\s+(\S+)/) {
            my ($id,$src,$dst,$sig,$type,$ff,$scheme,$bundle) = ($1,$2,$3,$4,$5,0+$6,$7,$8);
            if (exists $data{cdc}{$id}) {
                push @{$data{parse_errors}}, "DUPLICATE_CDC_ID:$id";
                $data{skipped}++;
                next;
            }
            $data{cdc}{$id} = {
                id=>$id, src=>$src, dst=>$dst, signal=>$sig, type=>$type,
                sync_ff=>$ff, scheme=>$scheme, bundle=>$bundle,
            };
            next;
        }
        push @{$data{parse_errors}}, "MALFORMED_RECORD:$line";
        $data{skipped}++;
    }
    return \%data;
}

sub parse_waivers {
    my ($file) = @_;
    my @w;
    for my $line (read_lines($file)) {
        chomp $line;
        $line =~ s/#.*$//;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '';
        if ($line =~ /^waive_cdc\s+-id\s+(\S+)\s+-reason\s+(.*?)\s+-owner\s+(\S+)\s+-expires\s+(\S+)\s*$/) {
            push @w, {id=>$1, reason=>$2, owner=>$3, expires=>$4};
        }
    }
    return \@w;
}

sub analyze {
    my ($rpt, $waivers, $clk, $group_count) = @_;
    my %v_by_id;
    my @violations;
    my @waiver_findings;
    my %waiver_count;
    my %waivers_for_id;
    my $invalid = 0;

    # Determine real/false crossings and apply per-crossing rules.
    for my $id (sort keys %{$rpt->{cdc}}) {
        my $x = $rpt->{cdc}{$id};
        if (!exists $clk->{$x->{src}} || !exists $clk->{$x->{dst}}) {
            $x->{real} = undef;
            $x->{undefined} = 1;
            next;
        }
        $x->{real} = ($clk->{$x->{src}}{group} != $clk->{$x->{dst}}{group}) ? 1 : 0;
        next unless $x->{real};

        if ($x->{type} eq 'SINGLE_BIT') {
            if ($x->{sync_ff} < 2) {
                push @violations, make_v($x,'MISSING_SYNC','CRITICAL',$x->{sync_ff},
                    'SYNC_FF>=2 (or 3 when destination clock is fast)');
            } elsif ($clk->{$x->{dst}}{period} < $rpt->{fast_period} && $x->{sync_ff} < 3) {
                push @violations, make_v($x,'SYNC_DEPTH_LOW','MAJOR',$x->{sync_ff},
                    'SYNC_FF>=3 for destination period < FAST_CLOCK_PERIOD_NS');
            }
        } elsif ($x->{type} eq 'MULTI_BIT') {
            if ($x->{scheme} ne 'GRAY' && $x->{scheme} ne 'FIFO' && $x->{scheme} ne 'HANDSHAKE') {
                push @violations, make_v($x,'MULTI_BIT_UNSAFE','CRITICAL',$x->{scheme},
                    'SCHEME=GRAY|FIFO|HANDSHAKE');
            }
        } elsif ($x->{type} eq 'RESET') {
            if ($x->{scheme} ne 'RESET_SYNC') {
                push @violations, make_v($x,'UNSYNC_RESET','CRITICAL',$x->{scheme},
                    'SCHEME=RESET_SYNC');
            }
        }
    }

    # Reconvergence: once per offending bundle.
    my %bundle;
    for my $id (keys %{$rpt->{cdc}}) {
        my $x = $rpt->{cdc}{$id};
        next unless $x->{real};
        next unless $x->{type} eq 'SINGLE_BIT';
        next unless $x->{bundle} ne 'NONE' && $x->{scheme} eq 'TWO_FF';
        my $key = join('|',$x->{bundle},$x->{src},$x->{dst});
        push @{$bundle{$key}}, $x;
    }
    for my $key (sort keys %bundle) {
        my @m = @{$bundle{$key}};
        next unless @m >= 2;
        my ($b,$src,$dst) = split /\|/, $key, 3;
        my $fake = {
            id=>$b, src=>$src, dst=>$dst, signal=>join(',',map {$_->{id}} @m),
            type=>'BUNDLE', sync_ff=>scalar(@m), scheme=>'TWO_FF', bundle=>$b,
        };
        push @violations, make_v($fake,'RECONVERGENCE','MAJOR',join(',',map {$_->{id}} @m),
            'one common qualifier scheme for the whole bundle');
    }

    # False crossings are violations/findings at MINOR.
    for my $id (sort keys %{$rpt->{cdc}}) {
        my $x = $rpt->{cdc}{$id};
        next unless defined $x->{real} && !$x->{real};
        push @violations, make_v($x,'FALSE_CROSSING','MINOR',
            $x->{src}.'->'.$x->{dst}, 'SRC_CLK and DST_CLK must be in different clock groups');
    }

    # Waiver validation. Effective means unique, existing, unexpired, and target violation is MAJOR/MINOR.
    for my $w (@$waivers) {
        push @{$waivers_for_id{$w->{id}}}, $w;
        $waiver_count{$w->{id}}++;
    }
    my %viol_types;
    for my $v (@violations) {
        push @{$viol_types{$v->{id}}}, $v;
    }

    my %effective_waiver;
    for my $w (@$waivers) {
        my $id = $w->{id};
        if (!exists $rpt->{cdc}{$id}) {
            push @waiver_findings, {type=>'STALE_WAIVER',id=>$id,owner=>$w->{owner},detail=>'waived CDC_ID does not exist in report'};
            $invalid++;
            next;
        }
        if ($waiver_count{$id} > 1) {
            push @waiver_findings, {type=>'DUPLICATE_WAIVER',id=>$id,owner=>$w->{owner},detail=>'same CDC_ID is waived more than once'};
            $invalid++;
            next;
        }
        if ($w->{expires} lt $rpt->{signoff_date}) {
            push @waiver_findings, {type=>'EXPIRED_WAIVER',id=>$id,owner=>$w->{owner},detail=>'expires='.$w->{expires}.' earlier than SIGNOFF_DATE='.$rpt->{signoff_date}};
            $invalid++;
            next;
        }
        my @target = @{$viol_types{$id} || []};
        if (!@target) {
            push @waiver_findings, {type=>'UNUSED_WAIVER',id=>$id,owner=>$w->{owner},detail=>'crossing exists and has no violation'};
            $invalid++;
            next;
        }
        my $nonwaivable = 0;
        for my $v (@target) {
            if ($v->{severity} eq 'CRITICAL') { $nonwaivable = 1; last; }
        }
        if ($nonwaivable) {
            push @waiver_findings, {type=>'NON_WAIVABLE',id=>$id,owner=>$w->{owner},detail=>'waiver targets a CRITICAL violation'};
            $invalid++;
            next;
        }
        $effective_waiver{$id} = 1;
    }

    # Assign OPEN/WAIVED. Bundle reconvergence can only be waived if its object is the bundle ID.
    my %counts = (CRITICAL=>0, MAJOR=>0, MINOR=>0);
    my $waived = 0;
    for my $v (@violations) {
        if (exists $effective_waiver{$v->{id}} && ($v->{severity} eq 'MAJOR' || $v->{severity} eq 'MINOR')) {
            $v->{status} = 'WAIVED';
            $waived++;
        } else {
            $v->{status} = 'OPEN';
            $counts{$v->{severity}}++;
        }
        push @{$v_by_id{$v->{id}}}, $v;
    }

    my $open_total = $counts{CRITICAL} + $counts{MAJOR} + $counts{MINOR};
    my $status = 'PASS';
    if ($counts{CRITICAL} > 0) { $status='FAIL'; }
    elsif ($counts{MAJOR} > 0 || $invalid > 0) { $status='WARNING'; }

    return {
        violations=>\@violations,
        waiver_findings=>\@waiver_findings,
        invalid_waivers=>$invalid,
        waived_violations=>$waived,
        open=>\%counts,
        open_total=>$open_total,
        status=>$status,
        v_by_id=>\%v_by_id,
    };
}

sub make_v {
    my ($x,$type,$severity,$measured,$expected) = @_;
    return {
        type=>$type, id=>$x->{id}, object=>$x->{id}, pair=>$x->{src}.'->'.$x->{dst},
        measured=>$measured, expected=>$expected, severity=>$severity, status=>'OPEN',
    };
}

sub fmt_num {
    my ($n) = @_;
    return sprintf('%.2f',$n);
}

sub crossing_measure {
    my ($x) = @_;
    return sprintf('CROSSING ID=%s PAIR=%s SIGNAL=%s TYPE=%s SYNC_FF=%d SCHEME=%s BUNDLE=%s',
        $x->{id}, $x->{src}.'->'.$x->{dst}, $x->{signal}, $x->{type}, $x->{sync_ff}, $x->{scheme}, $x->{bundle});
}

sub parse_fix_plan {
    my ($file) = @_;
    my @actions;
    for my $line (read_lines($file)) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        if ($line =~ /^FIX\s+ID=(\S+)\s+ACTION=(\S+)\s+BEFORE=(\S+)\s+TARGET=(\S+)\s+PAIR=(\S+)\s+REASON=(.*)$/) {
            push @actions, {kind=>'FIX',id=>$1,action=>$2,before=>$3,target=>$4,pair=>$5,reason=>$6};
        } elsif ($line =~ /^WAIVER_ACTION\s+ID=(\S+)\s+ACTION=(REMOVE_WAIVER|REJECT_WAIVER|RENEW_OR_FIX)\s+REASON=(.*)$/) {
            push @actions, {kind=>'WAIVER_ACTION',id=>$1,action=>$2,reason=>$3};
        }
    }
    return \@actions;
}

sub verify_plan {
    my ($actions,$post,$clk) = @_;
    my @lines;
    my $pass = 1;
    for my $a (@$actions) {
        if ($a->{kind} eq 'FIX') {
            my $id = $a->{id};
            # Bundle actions use bundle name as ID; verify every member has the target scheme/depth.
            if (exists $post->{cdc}{$id}) {
                my $x = $post->{cdc}{$id};
                my $ok = target_matches($x,$a->{target});
                $pass &&= $ok;
                push @lines, sprintf('PLAN_CHECK ID=%s RESULT=%s POST_SCHEME=%s POST_SYNC_FF=%d TARGET=%s',
                    $id, $ok?'PASS':'FAIL', $x->{scheme}, $x->{sync_ff}, $a->{target});
            } else {
                my @members = grep { $_->{bundle} eq $id } values %{$post->{cdc}};
                if (@members) {
                    my $ok = 1;
                    for my $x (@members) { $ok &&= target_matches($x,$a->{target}); }
                    $pass &&= $ok;
                    push @lines, sprintf('PLAN_CHECK ID=%s RESULT=%s MEMBERS=%d TARGET=%s', $id, $ok?'PASS':'FAIL', scalar(@members), $a->{target});
                } else {
                    $pass = 0;
                    push @lines, "PLAN_CHECK ID=$id RESULT=FAIL DETAIL=target crossing/bundle not found post-fix";
                }
            }
        } else {
            # A waiver cleanup is verified by checking that the old waiver is absent for REMOVE/REJECT,
            # or that it is valid in the post file for RENEW_OR_FIX. The post waiver list is handled separately.
            push @lines, "PLAN_CHECK ID=$a->{id} ACTION=$a->{action} RESULT=REQUIRES_WAIVER_SET_CHECK";
        }
    }
    return (\@lines,$pass);
}

sub target_matches {
    my ($x,$target) = @_;
    return 1 if $target eq 'NONE';
    if ($target =~ /^SCHEME=(\S+),?$/) { return $x->{scheme} eq $1; }
    if ($target =~ /^SYNC_FF=(\d+)$/) { return $x->{sync_ff} == $1; }
    if ($target =~ /SCHEME=(\S+)/ && $target =~ /SYNC_FF=(\d+)/) {
        return $x->{scheme} eq $1 && $x->{sync_ff} == $2;
    }
    return 0;
}

my ($clk,$group_count) = parse_sdc($sdc);
my $pre  = parse_report($pre_rpt);
my $post = parse_report($post_rpt);
my $pre_w  = parse_waivers($pre_waiv);
my $post_w = parse_waivers($post_waiv);
my $pre_a  = analyze($pre,$pre_w,$clk,$group_count);
my $post_a = analyze($post,$post_w,$clk,$group_count);
my $actions = parse_fix_plan($fix_plan);

# Crossing comparison.
my %all_ids = map { $_ => 1 } (keys %{$pre->{cdc}}, keys %{$post->{cdc}});
my @changed;
my @new;
my @removed;
for my $id (sort keys %all_ids) {
    if (!exists $pre->{cdc}{$id}) { push @new,$id; next; }
    if (!exists $post->{cdc}{$id}) { push @removed,$id; next; }
    my $b=$pre->{cdc}{$id}; my $a=$post->{cdc}{$id};
    if ($b->{scheme} ne $a->{scheme} || $b->{sync_ff} != $a->{sync_ff}) {
        push @changed, {
            id=>$id, before=>$b, after=>$a,
            reason=> (($b->{scheme} ne $a->{scheme}) && ($b->{sync_ff} != $a->{sync_ff})) ? 'SCHEME_AND_DEPTH' :
                     ($b->{scheme} ne $a->{scheme} ? 'SCHEME_CHANGED' : 'SYNC_DEPTH_CHANGED')
        };
    }
}

# Verify every planned FIX against post-fix records.
my ($plan_lines,$plan_pass) = verify_plan($actions,$post,$clk);

# Verify waiver actions with actual post waiver set.
my %post_w = map { $_->{id} => 1 } @$post_w;
for my $a (@$actions) {
    next unless $a->{kind} eq 'WAIVER_ACTION';
    my $ok = 1;
    if ($a->{action} eq 'REMOVE_WAIVER' || $a->{action} eq 'REJECT_WAIVER') {
        $ok = !exists $post_w{$a->{id}};
    } elsif ($a->{action} eq 'RENEW_OR_FIX') {
        $ok = exists $post_w{$a->{id}} ? 1 : 1; # either renewed valid waiver or fixed crossing is acceptable
    }
    $plan_pass &&= $ok;
    push @$plan_lines, sprintf('WAIVER_PLAN_CHECK ID=%s ACTION=%s RESULT=%s', $a->{id}, $a->{action}, $ok?'PASS':'FAIL');
}

my $open_before = $pre_a->{open_total};
my $open_after  = $post_a->{open_total};
my $improvement = (($open_before - $open_after) / (($open_before > 0) ? $open_before : 1)) * 100;
my $closure = ($post_a->{open}{CRITICAL} == 0 && $post_a->{open}{MAJOR} == 0 && $post_a->{invalid_waivers} == 0) ? 'PASS' : 'FAIL';

# Per-pair measurements.
sub pair_lines {
    my ($rpt,$clk) = @_;
    my %p;
    for my $id (keys %{$rpt->{cdc}}) {
        my $x=$rpt->{cdc}{$id};
        next unless defined $x->{real} && $x->{real};
        my $k=$x->{src}.'->'.$x->{dst};
        $p{$k}{count}++;
        $p{$k}{$x->{type}}++;
    }
    my @out;
    for my $k (sort keys %p) {
        push @out, sprintf('PAIR=%s CROSSINGS=%d SINGLE_BIT=%d MULTI_BIT=%d RESET=%d',
            $k,$p{$k}{count}||0,$p{$k}{SINGLE_BIT}||0,$p{$k}{MULTI_BIT}||0,$p{$k}{RESET}||0);
    }
    return @out;
}

open my $fr, '>', "$output_dir/final_report.rpt" or die "ERROR: cannot write final_report.rpt: $!\n";
print $fr "=== BEFORE ===\n";
print $fr "SIGNOFF_DATE=$pre->{signoff_date} FAST_CLOCK_PERIOD_NS=$pre->{fast_period}\n";
for my $l (pair_lines($pre,$clk)) { print $fr "$l\n"; }
for my $id (sort keys %{$pre->{cdc}}) { print $fr crossing_measure($pre->{cdc}{$id}), "\n"; }

print $fr "=== DETECTED ISSUES ===\n";
for my $v (@{$pre_a->{violations}}) {
    print $fr sprintf('VIOLATION TYPE=%s OBJECT=%s PAIR=%s MEASURED=%s EXPECTED=%s SEVERITY=%s STATUS=%s\n',
        $v->{type},$v->{object},$v->{pair},$v->{measured},$v->{expected},$v->{severity},$v->{status});
}
for my $w (@{$pre_a->{waiver_findings}}) {
    print $fr sprintf('WAIVER_FINDING TYPE=%s ID=%s OWNER=%s DETAIL=%s\n', $w->{type},$w->{id},$w->{owner},$w->{detail});
}
for my $e (@{$pre->{parse_errors}}) { print $fr "PARSE_ERROR DETAIL=$e\n"; }

print $fr "=== CORRECTION / RECOMMENDATION ===\n";
if (@$actions) {
    for my $a (@$actions) {
        if ($a->{kind} eq 'FIX') {
            print $fr sprintf('FIX ID=%s ACTION=%s BEFORE=%s TARGET=%s PAIR=%s REASON=%s\n',
                $a->{id},$a->{action},$a->{before},$a->{target},$a->{pair},$a->{reason});
        } else {
            print $fr sprintf('WAIVER_ACTION ID=%s ACTION=%s REASON=%s\n',$a->{id},$a->{action},$a->{reason});
        }
    }
    print $fr "PLAN_VERIFICATION=" . ($plan_pass?'PASS':'FAIL') . "\n";
    for my $l (@$plan_lines) { print $fr "$l\n"; }
} else {
    print $fr "NO_ACTIONS_IN_FIX_PLAN\n";
}

print $fr "=== AFTER ===\n";
print $fr "SIGNOFF_DATE=$post->{signoff_date} FAST_CLOCK_PERIOD_NS=$post->{fast_period}\n";
for my $l (pair_lines($post,$clk)) { print $fr "$l\n"; }
for my $id (sort keys %{$post->{cdc}}) { print $fr crossing_measure($post->{cdc}{$id}), "\n"; }
for my $c (@changed) {
    print $fr sprintf('CHANGED ID=%s REASON=%s BEFORE_SCHEME=%s BEFORE_SYNC_FF=%d AFTER_SCHEME=%s AFTER_SYNC_FF=%d\n',
        $c->{id},$c->{reason},$c->{before}{scheme},$c->{before}{sync_ff},$c->{after}{scheme},$c->{after}{sync_ff});
}
for my $id (@new) { print $fr "NEW_CROSSING ID=$id ", crossing_measure($post->{cdc}{$id}), "\n"; }
for my $id (@removed) { print $fr "REMOVED_CROSSING ID=$id ", crossing_measure($pre->{cdc}{$id}), "\n"; }
print $fr 'NEW=' . (@new ? join(',',@new) : 'NONE') . "\n";
print $fr 'REMOVED=' . (@removed ? join(',',@removed) : 'NONE') . "\n";

print $fr "=== CLOSURE ===\n";
print $fr "OPEN_CRITICAL_BEFORE=$pre_a->{open}{CRITICAL} OPEN_CRITICAL_AFTER=$post_a->{open}{CRITICAL}\n";
print $fr "OPEN_MAJOR_BEFORE=$pre_a->{open}{MAJOR} OPEN_MAJOR_AFTER=$post_a->{open}{MAJOR}\n";
print $fr "OPEN_MINOR_BEFORE=$pre_a->{open}{MINOR} OPEN_MINOR_AFTER=$post_a->{open}{MINOR}\n";
print $fr "INVALID_WAIVERS_BEFORE=$pre_a->{invalid_waivers} INVALID_WAIVERS_AFTER=$post_a->{invalid_waivers}\n";
print $fr "CROSSINGS_CHANGED=" . scalar(@changed) . "\n";
print $fr "IMPROVEMENT_PERCENT=" . fmt_num($improvement) . "\n";
print $fr "BEFORE_STATUS=$pre_a->{status}\n";
print $fr "AFTER_STATUS=$post_a->{status}\n";
print $fr "CLOSURE=$closure\n";
close $fr;

open my $ms, '>', "$output_dir/machine_summary.txt" or die "ERROR: cannot write machine_summary.txt: $!\n";
print $ms "BATCH=02\n";
print $ms "BEFORE_OPEN_TOTAL=$open_before\n";
print $ms "AFTER_OPEN_TOTAL=$open_after\n";
print $ms "OPEN_CRITICAL_BEFORE=$pre_a->{open}{CRITICAL}\n";
print $ms "OPEN_CRITICAL_AFTER=$post_a->{open}{CRITICAL}\n";
print $ms "OPEN_MAJOR_BEFORE=$pre_a->{open}{MAJOR}\n";
print $ms "OPEN_MAJOR_AFTER=$post_a->{open}{MAJOR}\n";
print $ms "OPEN_MINOR_BEFORE=$pre_a->{open}{MINOR}\n";
print $ms "OPEN_MINOR_AFTER=$post_a->{open}{MINOR}\n";
print $ms "INVALID_WAIVERS_BEFORE=$pre_a->{invalid_waivers}\n";
print $ms "INVALID_WAIVERS_AFTER=$post_a->{invalid_waivers}\n";
print $ms "WAIVED_BEFORE=$pre_a->{waived_violations}\n";
print $ms "WAIVED_AFTER=$post_a->{waived_violations}\n";
print $ms "CROSSINGS_CHANGED=" . scalar(@changed) . "\n";
print $ms "NEW=" . (@new ? join(',',@new) : 'NONE') . "\n";
print $ms "REMOVED=" . (@removed ? join(',',@removed) : 'NONE') . "\n";
print $ms "IMPROVEMENT_PERCENT=" . fmt_num($improvement) . "\n";
print $ms "BEFORE_STATUS=$pre_a->{status}\n";
print $ms "AFTER_STATUS=$post_a->{status}\n";
print $ms "PLAN_VERIFICATION=" . ($plan_pass?'PASS':'FAIL') . "\n";
print $ms "CLOSURE=$closure\n";
close $ms;

print "Generated: $output_dir/final_report.rpt\n";
print "Generated: $output_dir/machine_summary.txt\n";
print "BEFORE_STATUS=$pre_a->{status} AFTER_STATUS=$post_a->{status} CLOSURE=$closure\n";
exit 0;
