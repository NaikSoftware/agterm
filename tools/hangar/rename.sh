#!/bin/sh
# Renames agterm to Hangar: tracked paths with git mv, then text file contents. skip.txt lists what stays.
# Usage: tools/hangar/rename.sh [--dry-run | --check]   (--check is what check-names.sh runs)
script="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(git rev-parse --show-toplevel)" || exit 1
exec perl -x "$script" "$@"
#!perl
use strict;
use warnings;

my $mode = $ARGV[0] // '';
die "usage: rename.sh [--dry-run | --check]\n" if @ARGV > 1 || ($mode ne '' && $mode !~ /^--(?:dry-run|check)$/);
my $dry = $mode eq '--dry-run';

sub glob_re {
    my $g = quotemeta shift;
    $g =~ s/\\\*\\\*/.*/g;
    $g =~ s/\\\*/[^\/]*/g;
    return qr/^$g$/;
}

my (@whole, @rules);
open my $sfh, '<', 'tools/hangar/skip.txt' or die "tools/hangar/skip.txt: $!\n";
while (my $l = <$sfh>) {
    chomp $l;
    next if $l =~ /^\s*(?:#|$)/;
    my ($g, $kind, $re) = split /\t/, $l;
    if (!defined $kind) { push @whole, glob_re($g); next }
    die "skip.txt:$.: kind must be line or keep, followed by a regex\n" unless $kind =~ /^(?:line|keep)$/ && defined $re;
    push @rules, { glob => glob_re($g), kind => $kind, re => qr/$re/, text => $l };
}
close $sfh;

sub skipped { my $p = shift; return grep { $p =~ $_ } @whole }
sub git_list { my $out = `git @_`; return grep { length } split /\0/, $out }

# Order matters: a longer token must run before any token it contains. The bundle ids run first, ahead of the
# brief's order, so com.umputun.agtermTests is not split by agtermTests.
my @tokens = map { [split /=/] } qw(
    ua.naiksoftware.agterm2=ua.naiksoftware.hangar com.umputun.agterm=ua.naiksoftware.hangar
    AgtermServerKit=HangarServerKit AgtermResponsibility=HangarResponsibility
    agtermctlKitTests=hangarctlKitTests agtermctlKit=hangarctlKit agtermCoreTests=HangarCoreTests
    agtermCore=HangarCore agtermUITests=HangarUITests agtermTests=HangarTests
    agterm-session-host=hangar-session-host agterm-server=hangar-server agterm-qt=hangar
    agterm_mobile=hangar_mobile agtermctl=hangarctl AGTERM_=HANGAR_ Agterm2=Hangar agterm2=hangar
    AGTERM=HANGAR Agterm=Hangar agterm=hangar
);

# The app target folder macos/agterm becomes macos/Hangar. A reference names one of its top-level entries
# exactly, or a glob such as agterm/AppActions*.swift.
my (%top, %stem);
for (git_list('ls-files -z -- macos/agterm macos/Hangar')) {
    next unless m{^macos/(?:agterm|Hangar)/([^/]+)};
    $top{$1} = 1;
    $stem{$1} = 1 if $1 =~ /^([A-Za-z]+)/;
}
my $entries = join '|', map { quotemeta } sort keys %top;
my $stems = join '|', sort keys %stem;

# Context rules run before the tokens. The last field limits a rule to one file.
my @pre = (
    ['umputun/agterm -> NaikSoftware/hangar', qr{umputun/agterm(?![\w-])}, 'NaikSoftware/hangar'],
    ['agterm.com -> naiksoftware.github.io/hangar', qr{(?<![\w.-])agterm\.com(?![A-Za-z0-9])}, 'naiksoftware.github.io/hangar'],
    ['agterm.app -> Hangar.app', qr{(?<![\w.-])agterm\.app(?![A-Za-z0-9])}, 'Hangar.app'],
    ['Contents/MacOS/agterm -> Hangar', qr{Contents/MacOS/\Kagterm(?![\w.-])}, 'Hangar'],
    ['agterm.xcodeproj -> Hangar.xcodeproj', qr{(?<![\w.-])agterm(?=\.xcodeproj)}, 'Hangar'],
    ['import agterm -> import Hangar', qr{\bimport agterm(?!\w)}, 'import Hangar'],
    ['-scheme agterm -> -scheme Hangar', qr{-scheme \Kagterm(?![\w.-])}, 'Hangar'],
    ['bundleIdPrefix com.umputun -> ua.naiksoftware', qr{bundleIdPrefix: \Kcom\.umputun\b}, 'ua.naiksoftware', 'macos/project.yml'],
    ['test bundle ids com.umputun.* -> ua.naiksoftware.*', qr{\bcom\.umputun\.(?=(?:hosttest|clienttest|fishseam|seamtest)\.)}, 'ua.naiksoftware.'],
    ['app folder agterm/<entry> -> Hangar/', qr{(?<![\w.~-])agterm/(?=(?:$entries)(?![\w.+-])|(?:$stems)[\w+]*\*)}, 'Hangar/'],
    ['project.yml target/product name -> Hangar', qr{^\s*(?:-\s+)?(?:name|path|target|TEST_TARGET_NAME|PRODUCT_NAME):\s+\Kagterm(?=\s*$)}, 'Hangar', 'macos/project.yml'],
    ['project.yml target/scheme key -> Hangar', qr{^\s*\Kagterm(?=:)}, 'Hangar', 'macos/project.yml'],
);

my %count;
sub bump { $count{$_[0]} += $_[1] }

sub applicable { my ($path, $kind) = @_; return grep { $_->{kind} eq $kind && $path =~ $_->{glob} } @rules }

sub rename_line {
    my ($line, $path, $keeps) = @_;
    my @masked;
    for my $r (@$keeps) { $line =~ s/$r->{re}/push @masked, $&; "\x00$#masked\x00"/ge }
    for my $p (@pre) {
        next if defined $p->[3] && $path ne $p->[3];
        bump($p->[0], scalar($line =~ s/$p->[1]/$p->[2]/g));
    }
    for my $t (@tokens) { bump("$t->[0] -> $t->[1]", scalar($line =~ s/\Q$t->[0]\E/$t->[1]/g)) }
    $line =~ s/\x00(\d+)\x00/$masked[$1]/g;
    return $line;
}

sub map_segment { my $s = shift; $s =~ s/\Q$_->[0]\E/$_->[1]/g for @tokens; return $s }

if ($mode eq '--check') { exit check() }

# Phase A: paths. Deepest first, each move renames only its last segment, so parents still carry old names.
my @files = git_list('ls-files -z');
my (%moves, %target);
for my $f (@files) {
    next if skipped($f);
    my @s = split m{/}, $f;
    my @n = map { map_segment($_) } @s;
    $n[1] = 'Hangar' if @s > 2 && $s[0] eq 'macos' && $s[1] eq 'agterm';
    for my $i (0 .. $#s) {
        next if $n[$i] eq $s[$i];
        $moves{ join '/', @s[0 .. $i] } = join '/', @s[0 .. $i - 1], $n[$i];
    }
    my $new = join '/', @n;
    die "path collision: $target{lc $new} and $f both become $new\n" if $target{lc $new} && $target{lc $new} ne $f;
    $target{lc $new} = $f;
}
for my $f (@files) {
    next unless skipped($f);
    for my $d (keys %moves) { die "skipped $f lies under moved $d\n" if index($f, "$d/") == 0 }
}
my @moves = sort { ($b =~ tr{/}{}) <=> ($a =~ tr{/}{}) || $a cmp $b } keys %moves;
print "== path moves: ", scalar(@moves), "\n";
for my $old (@moves) {
    my $new = $moves{$old};
    print "  $old -> $new\n";
    next if $dry;
    # A rerun after git reset --hard finds ignored files (symlinked build artifacts) already under the new name.
    merge_back($new, $old) if -d $new && !-l $new && !git_list("ls-files -z -- '$new'");
    system('git', 'mv', $old, $new) == 0 or die "git mv $old $new failed\n";
}

# Phase B: contents of text files (git grep -I drops binaries).
my $changed = 0;
for my $f (git_list('grep -z -I -l -i agterm')) {
    next if skipped($f);
    my @lines = applicable($f, 'line');
    my @keeps = applicable($f, 'keep');
    open my $in, '<:raw', $f or die "$f: $!\n";
    my $text = do { local $/; <$in> };
    close $in;
    my $out = join '', map {
        my $l = $_;
        (grep { $l =~ $_->{re} } @lines) ? $l : rename_line($l, $f, \@keeps)
    } split /(?<=\n)/, $text;
    next if $out eq $text;
    $changed++;
    next if $dry;
    open my $o, '>:raw', $f or die "$f: $!\n";
    print $o $out;
    close $o or die "$f: $!\n";
}
print "== content matches per rule, in order\n";
printf "  %6d  %s\n", $count{$_} // 0, $_ for (map { $_->[0] } @pre), map { "$_->[0] -> $_->[1]" } @tokens;
print "== files ", ($dry ? 'to change' : 'changed'), ": $changed\n";

if (!$dry) {
    # xcodegen regenerates it as Hangar.xcodeproj; the renamed .gitignore no longer ignores the old one.
    system('rm', '-rf', 'macos/agterm.xcodeproj') if -d 'macos/agterm.xcodeproj';
    system('git', 'add', '-u') == 0 or die "git add failed\n";
}
exit 0;

sub merge_back {
    my ($from, $to) = @_;
    for my $e (glob("'$from'/* '$from'/.[!.]*")) {
        (my $back = $e) =~ s/^\Q$from\E/$to/;
        if (-d $e && !-l $e && -d $back && !-l $back) { merge_back($e, $back) }
        elsif (-e $back || -l $back) { die "$back exists; cannot move $e back\n" }
        else { rename $e, $back or die "move $e back: $!\n" }
    }
    rmdir $from or die "rmdir $from: $!\n";
}

sub check {
    my $bad = 0;
    my $report = sub { $bad++; print "  $_[0]\n" };
    print "== unexpected agterm paths\n";
    $report->($_) for grep { /agterm/i && !skipped($_) } git_list('ls-files -z');
    my %text = map { $_ => 1 } git_list('grep -z -I -l -i agterm');
    print "== binary files matching agterm\n";
    $report->($_) for grep { !$text{$_} && !skipped($_) } git_list('grep -z -l -i agterm');
    print "== unexpected agterm lines\n";
    for my $f (grep { !skipped($_) } sort keys %text) {
        my @lines = applicable($f, 'line');
        my @keeps = applicable($f, 'keep');
        open my $in, '<:raw', $f or die "$f: $!\n";
        while (my $l = <$in>) {
            next unless $l =~ /agterm/i;
            next if grep { $l =~ $_->{re} } @lines;
            my $rest = $l;
            $rest =~ s/$_->{re}//g for @keeps;
            $report->("$f:$.: " . substr($l =~ s/\s+$//r, 0, 160)) if $rest =~ /agterm/i;
        }
    }
    print "== skip.txt rules that match nothing (a lost credit)\n";
    my @all = git_list('ls-files -z');
    for my $r (@rules) {
        my $found = 0;
        for my $f (grep { $_ =~ $r->{glob} && -f $_ } @all) {
            open my $in, '<:raw', $f or next;
            while (<$in>) { if ($_ =~ $r->{re}) { $found = 1; last } }
            last if $found;
        }
        $report->($r->{text}) unless $found;
    }
    print "== doubled or suffixed names (hangarhangar, hangar2)\n";
    for my $f (grep { !skipped($_) } git_list('grep -z -I -l -i -E "hangarhangar|hangar2"')) { $report->($f) }
    my $hits = `git grep -I -i -c agterm | awk -F: '{s+=\$NF} END {print s+0}'`;
    chomp $hits;
    print $bad ? "FAIL: $bad problems ($hits agterm matches in total, skip list included)\n"
               : "PASS: only skip-list matches remain ($hits)\n";
    return $bad ? 1 : 0;
}
