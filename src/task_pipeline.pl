#!/usr/bin/env perl

use strict;
use warnings;
use File::Spec;
use File::Basename;
use Getopt::Long;
use Cwd 'abs_path';

my ($scriptname, $scriptdir) = fileparse($0);
my $reapr_dir = abs_path(File::Spec->catfile($scriptdir, File::Spec->updir()));
my $reapr = File::Spec->catfile($reapr_dir, 'reapr');

my %options = (fcdcut => 0);

my $usage = qq/[options] <assembly.fa> <in.bam> <out directory> [perfectmap prefix]

where 'perfectmap prefix' is optional and should be the prefix used when task
perfectmap was run.

It is assumed that reads in in.bam are 'innies', i.e. the correct orientation
is reads in a pair pointing towards each other (---> <---).

Options:

-stats|fcdrate|score|break option=value
\tYou can pass options to stats, fcdrate, score or break
\tif you want to change the default settings. These
\tcan be used multiple times to use more than one option. e.g.:
\t\t-stats i=100 -stats j=1000
\tIf an option has no value, use 1. e.g.
\t\t-break b=1
-fcdcut <float>
\tSet the fcdcutoff used when running score. Default is to
\trun fcdrate to determine the cutoff. Using this option will
\tskip fcdrate and use the given value.
-x
\tBy default, a bash script is written to run all
\tthe pipeline stages. Using this option stops the
\tscript from being run.
/;

my $ERROR_PREFIX = '[REAPR pipeline]';

my $ops_ok = GetOptions(
    \%options,
    'wrapperhelp',
    'stats=s%',
    'fcdrate=s%',
    'score=s%',
    'break=s%',
    'x',
    'fcdcut=f',
);

if ($options{wrapperhelp}) {
    print STDERR "$usage\n";
    exit(1);
}

if (!($ops_ok) or $#ARGV < 2) {
    print STDERR "usage:\n$scriptname $usage\n";
    exit(1);
}

my $ref = $ARGV[0];
my $bam = $ARGV[1];
my $dir = $ARGV[2];
my $version = '1.0.18';
my $bash_script = "$dir.run-pipeline.sh";
my $stats_prefix = '01.stats';
my $fcdrate_prefix = '02.fcdrate';
my $score_prefix = '03.score';
my $break_prefix = '04.break';
my $summary_prefix = '05.summary';

my $perfect_prefix = "";
if ($#ARGV == 3) {
    $perfect_prefix = File::Spec->rel2abs($ARGV[3]);
}

# make a bash script that runs all the pipeline commands
my %commands;
$commands{facheck} = "$reapr facheck $ref";
$commands{preprocess} = "$reapr preprocess $ref $bam $dir";

if ($perfect_prefix) {
    $commands{stats} = "$reapr stats " . hash_to_ops($options{stats}) . " -p $perfect_prefix.perfect_cov.gz ./ $stats_prefix";
    $commands{score} = "$reapr score " . hash_to_ops($options{score}) . " -P 5 00.assembly.fa.gaps.gz 00.in.bam $stats_prefix \$fcdcutoff $score_prefix";
}
else {
    $commands{stats} = "$reapr stats " . hash_to_ops($options{stats}) . " ./ $stats_prefix";
    $commands{score} = "$reapr score " . hash_to_ops($options{score}) . " 00.assembly.fa.gaps.gz 00.in.bam $stats_prefix \$fcdcutoff $score_prefix";
}

if ($options{fcdcut} == 0) {
    $commands{fcdrate} = "$reapr fcdrate " . hash_to_ops($options{fcdrate}) . " ./ $stats_prefix $fcdrate_prefix\n"
                           . "fcdcutoff=`tail -n 1 $fcdrate_prefix.info.txt | cut -f 1`";
}
else {
    $commands{fcdrate} = "echo \"$ERROR_PREFIX ... skipping. User provided cutoff: $options{fcdcut}\"\n"
                            . "fcdcutoff=$options{fcdcut}";
}

my $break_ops = hash_to_ops($options{break});
$break_ops =~ s/\-a 1/-a/;
$break_ops =~ s/-b 1/-b/;
$commands{break} = "$reapr break $break_ops 00.assembly.fa $score_prefix.errors.gff.gz $break_prefix";
$commands{summary} = "$reapr summary 00.assembly.fa $score_prefix $break_prefix $summary_prefix";

open F, ">$bash_script" or die "$ERROR_PREFIX Error opening file for writing '$bash_script'";
print F "set -e\n"
. "file_ok(){ [ -s \"\$1\" ]; }\n"
. "tbi_ok(){ file_ok \"\$1\" && file_ok \"\$1.tbi\"; }\n"
. "echo \"Running reapr version $version pipeline:\"\n"
. "echo \"$reapr " . join(' ', @ARGV) . "\"\n\n";

# facheck (cheap; always run)
print F "echo \"$ERROR_PREFIX Running facheck\"\n"
    . "$commands{facheck}\n\n";

# preprocess (skip if output dir already populated)
print F "if [ -d \"$dir\" ]; then\n"
    . "  if file_ok \"$dir/00.assembly.fa.gaps.gz\" && file_ok \"$dir/00.in.bam\" && file_ok \"$dir/00.Sample/insert.stats.txt\"; then\n"
    . "    echo \"$ERROR_PREFIX Skipping preprocess (outputs present)\"\n"
    . "  else\n"
    . "    echo \"$ERROR_PREFIX ERROR: preprocess dir exists but looks incomplete: $dir\"; exit 1\n"
    . "  fi\n"
    . "else\n"
    . "  echo \"$ERROR_PREFIX Running preprocess\"\n"
    . "  $commands{preprocess}\n"
    . "fi\n"
    . "cd \"$dir\"\n\n";

# stats
print F "if tbi_ok \"$stats_prefix.per_base.gz\" && file_ok \"$stats_prefix.global_stats.txt\"; then\n"
    . "  echo \"$ERROR_PREFIX Skipping stats (outputs present)\"\n"
    . "else\n"
    . "  echo \"$ERROR_PREFIX Running stats\"\n"
    . "  $commands{stats}\n"
    . "fi\n\n";

# fcdrate (or cutoff)
if ($options{fcdcut} == 0) {
    print F "if file_ok \"$fcdrate_prefix.info.txt\"; then\n"
        . "  echo \"$ERROR_PREFIX Skipping fcdrate (outputs present)\"\n"
        . "  fcdcutoff=`tail -n 1 $fcdrate_prefix.info.txt | cut -f 1`\n"
        . "else\n"
        . "  echo \"$ERROR_PREFIX Running fcdrate\"\n"
        . "  $commands{fcdrate}\n"
        . "fi\n\n";
}
else {
    print F "echo \"$ERROR_PREFIX Using user-provided FCD cutoff: $options{fcdcut}\"\n"
        . "$commands{fcdrate}\n\n";
}

# score
print F "if tbi_ok \"$score_prefix.per_base.gz\" && tbi_ok \"$score_prefix.errors.gff.gz\"; then\n"
    . "  echo \"$ERROR_PREFIX Skipping score (outputs present)\"\n"
    . "else\n"
    . "  echo \"$ERROR_PREFIX Running score\"\n"
    . "  $commands{score}\n"
    . "fi\n\n";

# break
print F "if file_ok \"$break_prefix.broken_assembly.fa\"; then\n"
    . "  echo \"$ERROR_PREFIX Skipping break (outputs present)\"\n"
    . "else\n"
    . "  echo \"$ERROR_PREFIX Running break\"\n"
    . "  $commands{break}\n"
    . "fi\n\n";

# summary
print F "if file_ok \"$summary_prefix.stats.tsv\" && file_ok \"$summary_prefix.report.txt\" && file_ok \"$summary_prefix.report.tsv\"; then\n"
    . "  echo \"$ERROR_PREFIX Skipping summary (outputs present)\"\n"
    . "else\n"
    . "  echo \"$ERROR_PREFIX Running summary\"\n"
    . "  $commands{summary}\n"
    . "fi\n\n";

close F;

$options{x} or exec "bash $bash_script" or die $!;

sub hash_to_ops {
    my $h = shift;
    my $s = '';
    for my $k (keys %{$h}) {
        $s .= " -$k " . $h->{$k}
    }
    $s =~ s/^\s+//;
    return $s;
}
