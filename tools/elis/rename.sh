#!/bin/sh
# Renames agterm to Elis: tracked paths with git mv, then text file contents. skip.txt lists what stays.
# Usage: tools/elis/rename.sh [--dry-run | --check]   (--check is what check-names.sh runs)
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

my (@whole, @paths, @rules);
open my $sfh, '<', 'tools/elis/skip.txt' or die "tools/elis/skip.txt: $!\n";
while (my $l = <$sfh>) {
    chomp $l;
    next if $l =~ /^\s*(?:#|$)/;
    my ($g, $kind, $re) = split /\t/, $l;
    if (!defined $kind) { push @whole, glob_re($g); next }
    if ($kind eq 'path') { push @paths, glob_re($g); next }
    die "skip.txt:$.: kind must be path, or line or keep followed by a regex\n" unless $kind =~ /^(?:line|keep)$/ && defined $re;
    push @rules, { glob => glob_re($g), kind => $kind, re => qr/$re/, text => $l };
}
close $sfh;

sub skipped { my $p = shift; return grep { $p =~ $_ } @whole }
sub path_kept { my $p = shift; return skipped($p) || grep { $p =~ $_ } @paths }
sub git_list { my $out = `git @_`; return grep { length } split /\0/, $out }

# Order matters: a longer token must run before any token it contains. The bundle ids run first, ahead of the
# brief's order, so com.umputun.agtermTests is not split by agtermTests.
my @tokens = map { [split /=/] } qw(
    ua.naiksoftware.agterm2=ua.naiksoftware.elis com.umputun.agterm=ua.naiksoftware.elis
    AgtermServerKit=ElisServerKit AgtermResponsibility=ElisResponsibility
    agtermctlKitTests=elisctlKitTests agtermctlKit=elisctlKit agtermCoreTests=ElisCoreTests
    agtermCore=ElisCore agtermUITests=ElisUITests agtermTests=ElisTests
    agterm-session-host=elis-session-host agterm-server=elis-server agterm-qt=elis
    agterm_mobile=elis_mobile agtermctl=elisctl AGTERM_=ELIS_ Agterm2=Elis agterm2=elis
    AGTERM=ELIS Agterm=Elis agterm=elis
);
# The second name, Hangar, becomes Elis too, on line-rule lines as well: the rules protect agterm only.
my @hangar_tokens = map { [split /=/] } qw(HANGAR=ELIS Hangar=Elis hangar=elis);

# The app target folder macos/agterm becomes macos/Elis. A reference names one of its top-level entries
# exactly, or a glob such as agterm/AppActions*.swift.
my (%top, %stem);
for (git_list('ls-files -z -- macos/agterm macos/Hangar macos/Elis')) {
    next unless m{^macos/(?:agterm|Hangar|Elis)/([^/]+)};
    $top{$1} = 1;
    $stem{$1} = 1 if $1 =~ /^([A-Za-z]+)/;
}
my $entries = join '|', map { quotemeta } sort keys %top;
my $stems = join '|', sort keys %stem;

# Context rules run before the tokens. The last field limits a rule to one file.
my @pre = (
    ['umputun/agterm -> NaikSoftware/elis', qr{umputun/agterm(?![\w-])}, 'NaikSoftware/elis'],
    ['agterm.com -> naiksoftware.github.io/elis', qr{(?<![\w.-])agterm\.com(?![A-Za-z0-9])}, 'naiksoftware.github.io/elis'],
    ['agterm.app -> Elis.app', qr{(?<![\w.-])agterm\.app(?![A-Za-z0-9])}, 'Elis.app'],
    ['Contents/MacOS/agterm -> Elis', qr{Contents/MacOS/\Kagterm(?![\w.-])}, 'Elis'],
    ['agterm.xcodeproj -> Elis.xcodeproj', qr{(?<![\w.-])agterm(?=\.xcodeproj)}, 'Elis'],
    ['import agterm -> import Elis', qr{\bimport agterm(?!\w)}, 'import Elis'],
    # elisctl message read prints this; the skill references quote it in code spans.
    ['`from outside agterm` -> `from outside Elis`', qr{`from outside \Kagterm(?=`)}, 'Elis'],
    ['agterm.debug.dylib -> Elis.debug.dylib', qr{(?<![\w.-])agterm(?=\.debug\.dylib)}, 'Elis'],
    ['process name (open -a, pgrep -x, pkill, killall) -> Elis',
        qr{(?:open -n?a|pgrep -x|pkill|killall) \Kagterm(?![\w.-])}, 'Elis'],
    ['-scheme agterm -> -scheme Elis', qr{-scheme \Kagterm(?![\w.-])}, 'Elis'],
    ['bundleIdPrefix com.umputun -> ua.naiksoftware', qr{bundleIdPrefix: \Kcom\.umputun\b}, 'ua.naiksoftware', 'macos/project.yml'],
    ['test bundle ids com.umputun.* -> ua.naiksoftware.*', qr{\bcom\.umputun\.(?=(?:hosttest|clienttest|fishseam|seamtest)\.)}, 'ua.naiksoftware.'],
    ['app folder agterm/<entry> -> Elis/', qr{(?<![\w.~-])agterm/(?=(?:$entries)(?![\w.+-])|(?:$stems)[\w+]*\*)}, 'Elis/'],
    ['project.yml target/product name -> Elis', qr{^\s*(?:-\s+)?(?:name|path|target|TEST_TARGET_NAME|PRODUCT_NAME):\s+\Kagterm(?=\s*$)}, 'Elis', 'macos/project.yml'],
    ['project.yml target/scheme key -> Elis', qr{^\s*\Kagterm(?=:)}, 'Elis', 'macos/project.yml'],
    # Elis starts with a vowel. Not after a dash (open -a Hangar) or inside a word.
    ['article a -> an', qr{(?<![^\s(>*"])[Aa]\K (?=[`*"(\[]*(?i:agterm|hangar))}, 'n '],
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
    $line = hangar_line($line);
    $line =~ s/\x00(\d+)\x00/$masked[$1]/g;
    return $line;
}

sub hangar_line {
    my $line = shift;
    for my $t (@hangar_tokens) { bump("$t->[0] -> $t->[1]", scalar($line =~ s/\Q$t->[0]\E/$t->[1]/g)) }
    return $line;
}

sub map_segment { my $s = shift; $s =~ s/\Q$_->[0]\E/$_->[1]/g for @tokens, @hangar_tokens; return $s }

if ($mode eq '--check') { exit check() }

# Phase A: paths. Deepest first, each move renames only its last segment, so parents still carry old names.
my @files = git_list('ls-files -z');
my (%moves, %target);
for my $f (@files) {
    next if path_kept($f);
    my @s = split m{/}, $f;
    my @n = map { map_segment($_) } @s;
    $n[1] = 'Elis' if @s > 2 && $s[0] eq 'macos' && $s[1] eq 'agterm';
    for my $i (0 .. $#s) {
        next if $n[$i] eq $s[$i];
        $moves{ join '/', @s[0 .. $i] } = join '/', @s[0 .. $i - 1], $n[$i];
    }
    my $new = join '/', @n;
    die "path collision: $target{lc $new} and $f both become $new\n" if $target{lc $new} && $target{lc $new} ne $f;
    $target{lc $new} = $f;
}
for my $f (@files) {
    next unless path_kept($f);
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

# Product-name casing runs after the tokens: a lowercase elis that names the product in prose or UI text
# becomes Elis. Identifiers, paths, commands and code spans keep it lowercase.
# Not before " --" (a command). After a quote only when a sentence follows: "elis would like…", not 'elis'.
# Not after "= " (a config value such as theme = elis).
my $product = qr/(?<!= )(?:(?<![\w.\/~\$\@:#%{\\='"-])elis(?![\w\/\@=-]|\.\w|:\/\/| --)|(?<=['"])elis(?= [a-z]))/;
# In code literals "dark: elis" and "* elis" print a theme name, not the product.
my $product_code = qr/(?<!: |\* )(?:$product)/;
sub case_scope {
    my $p = shift;
    return '' if $p =~ m{(?:^|/)(?:CMakeLists|robots)\.txt$};
    return 'prose' if $p =~ /\.(?:md|html|txt)$/;
    return 'code' if $p =~ /\.(?:swift|cpp|h|dart|qml)$/;
    return 'plist' if $p =~ /\.plist$/;
    return 'desktop' if $p =~ /\.desktop(?:\.in)?$/;
    return '';
}
sub masked {
    my ($s, $mask, $f) = @_;
    my @m;
    $s =~ s/$mask/push @m, $&; "\x01$#m\x01"/ge;
    $s = $f->($s);
    $s =~ s/\x01(\d+)\x01/$m[$1]/g;
    return $s;
}
sub product_case {
    my ($s, $re) = @_;
    $re //= $product;
    bump('product name elis -> Elis', scalar($s =~ s/$re/Elis/g));
    return $s;
}
# Only literals that read as a sentence (they hold a space). An interpolation is code, but a literal nested
# in it ("\(x ?? "outside elis")") is a literal too. A `# >>> … >>>` marker is matched in users' rc files,
# so it keeps its exact text.
my $interp = qr/\\\((?:[^()"]|"(?:[^"\\]|\\.)*"|\([^()]*\))*\)/;
sub case_literals {
    return $_[0] =~ s{"((?:$interp|[^"\\]|\\.)*)"}{
        my $body = $1 =~ s/$interp/case_literals($&)/ger;
        '"' . ($body =~ / / && $body !~ />>>|<<<|name: elis/ ? masked($body, $interp, sub { product_case($_[0], $product_code) }) : $body) . '"'
    }ger;
}
sub case_file {
    my ($path, $lines) = @_;
    my $scope = case_scope($path) or return;
    my ($front, $fence, $block, $multi) = (0, 0, 0, 0);
    for my $i (0 .. $#$lines) {
        my $l = $lines->[$i];
        if ($scope eq 'prose') {
            if ($i == 0 && $l =~ /^---\s*$/) { $front = 1; next }
            # Front matter: only the description and its indented continuation lines are prose.
            if ($front) { $front = 0 if $l =~ /^---\s*$/; next unless $l =~ /^(?:description:|\s+\S)/ }
            if ($l =~ /^\s*(?:```|~~~)/) { $fence = !$fence; next }
            next if $fence;
            # Markdown mentions `<pre>` in code spans; only HTML opens a block with it.
            if ($path =~ /\.html$/ && $l =~ /<(?:pre|script|style)\b/i) { $block = 1 }
            if ($block) { $block = 0 if $l =~ m{</(?:pre|script|style)>}i; next }
            next unless $l =~ /elis/;
            $l =~ s{\b((?:content|alt|title|aria-label)=")([^"]*)"}{my ($k, $v) = ($1, $2); $k . ($v =~ / / ? product_case($v) : $v) . '"'}ge;
            $l = masked($l, qr{`[^`]*`|<code\b.*?</code>|<kbd\b.*?</kbd>|<[^>]*>|\]\([^)]*\)}, \&product_case);
        } elsif ($scope eq 'code') {
            # Multi-line and raw literals carry embedded scripts; comments are not UI text.
            my $toggles = () = $l =~ /"""/g;
            # Inside one, a `# …` line is the comment prose of a generated config file (the keymap starter).
            if ($multi && !$toggles && $l =~ /^\s*#\s+\S/) { $lines->[$i] = product_case($l, $product_code); next }
            if ($multi || $toggles) { $multi = !$multi if $toggles % 2; next }
            # `#expect` and other `#` macros are code; `#include` paths hold no space, so they are left anyway.
            next if $l =~ m{^\s*(?://|/\*|\*(?:\s|/|$))} || $l =~ /#"/ || $l !~ /elis/;
            $l = case_literals($l);
        } elsif ($scope eq 'plist') {
            $l =~ s{<string>([^<]* [^<]*)</string>}{'<string>' . product_case($1) . '</string>'}ge;
        } elsif ($l =~ /^((?:Name|GenericName|Comment)(?:\[[^\]]*\])?=)(.*)/s) {
            my ($k, $v) = ($1, $2);
            $l = $k . product_case($v);
        }
        $lines->[$i] = $l;
    }
}

# Phase B: contents of text files (git grep -I drops binaries). Files already renamed still get the casing pass.
my $changed = 0;
my %seen;
for my $f (grep { !$seen{$_}++ } git_list('grep -z -I -l -i -E "agterm|hangar"'), grep { case_scope($_) } git_list('grep -z -I -l -w elis')) {
    next if skipped($f);
    my @lines = applicable($f, 'line');
    my @keeps = applicable($f, 'keep');
    open my $in, '<:raw', $f or die "$f: $!\n";
    my $text = do { local $/; <$in> };
    close $in;
    my @out = map {
        my $l = $_;
        (grep { $l =~ $_->{re} } @lines) ? hangar_line($l) : rename_line($l, $f, \@keeps)
    } split /(?<=\n)/, $text;
    case_file($f, \@out);
    my $out = join '', @out;
    next if $out eq $text;
    $changed++;
    next if $dry;
    open my $o, '>:raw', $f or die "$f: $!\n";
    print $o $out;
    close $o or die "$f: $!\n";
}
print "== content matches per rule, in order\n";
printf "  %6d  %s\n", $count{$_} // 0, $_ for (map { $_->[0] } @pre), (map { "$_->[0] -> $_->[1]" } @tokens, @hangar_tokens), 'product name elis -> Elis';
print "== files ", ($dry ? 'to change' : 'changed'), ": $changed\n";

if (!$dry) {
    # xcodegen regenerates it as Elis.xcodeproj; the renamed .gitignore no longer ignores the old ones.
    -d $_ and system('rm', '-rf', $_) for 'macos/agterm.xcodeproj', 'macos/Hangar.xcodeproj';
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

# agterm may stay where skip.txt says; hangar may stay only in whole-file skips.
sub check {
    my $bad = 0;
    my $report = sub { $bad++; print "  $_[0]\n" };
    my @all = git_list('ls-files -z');
    print "== unexpected agterm or hangar paths\n";
    $report->($_) for grep { (/agterm/i && !path_kept($_)) || (/hangar/i && !skipped($_)) } @all;
    my %text = map { $_ => 1 } git_list('grep -z -I -l -i -E "agterm|hangar"');
    print "== binary files matching agterm or hangar\n";
    $report->($_) for grep { !$text{$_} && !skipped($_) } git_list('grep -z -l -i -E "agterm|hangar"');
    print "== unexpected agterm or hangar lines\n";
    for my $f (grep { !skipped($_) } sort keys %text) {
        my @lines = applicable($f, 'line');
        my @keeps = applicable($f, 'keep');
        open my $in, '<:raw', $f or die "$f: $!\n";
        while (my $l = <$in>) {
            my $rest = $l;
            if (grep { $l =~ $_->{re} } @lines) { $rest =~ s/agterm//gi } else { $rest =~ s/$_->{re}//g for @keeps }
            $report->("$f:$.: " . substr($l =~ s/\s+$//r, 0, 160)) if $rest =~ /agterm|hangar/i;
        }
    }
    print "== skip.txt rules that match nothing (a lost credit)\n";
    for my $r (@rules) {
        my $found = 0;
        for my $f (grep { $_ =~ $r->{glob} && -f $_ } @all) {
            open my $in, '<:raw', $f or next;
            while (<$in>) { if ($_ =~ $r->{re}) { $found = 1; last } }
            last if $found;
        }
        $report->($r->{text}) unless $found;
    }
    print "== doubled or suffixed names (eliselis, elis2), and a/A before Elis\n";
    for my $f (grep { !skipped($_) } git_list('grep -z -I -l -i -E "eliselis|elis2"')) { $report->($f) }
    for my $f (grep { !skipped($_) } git_list(q{grep -z -I -l -P '(?<![^\s(>*"])[Aa] [`*"(\[]*(?i:elis)\b'})) { $report->("article: $f") }
    my $hits = `git grep -I -i -c -E 'agterm|hangar' | awk -F: '{s+=\$NF} END {print s+0}'`;
    chomp $hits;
    print $bad ? "FAIL: $bad problems ($hits agterm/hangar matches in total, skip list included)\n"
               : "PASS: only skip-list matches remain ($hits)\n";
    return $bad ? 1 : 0;
}
