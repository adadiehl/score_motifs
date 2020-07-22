\#!/usr/bin/perl
## score_motifs.pl, version 0.1
## Written by Adam Diehl, 02/20/2017

##---------------------------------------------------------------------------##
##  File:
##      @(#) score_motifs.pl
##  Author:
##      Adam G. Diehl   adadiehl@umich.edu
##  Description:
##      A script to generate motif match scores based on a PWM and
##      background model.
##
#******************************************************************************
#* Copyright (C) Adam Diehl
#*
#* This work is licensed under the Open Source License v2.1.  To view a copy
#* of this license, visit http://www.opensource.org/licenses/osl-2.1.php or
#* see the license.txt file contained in this distribution.
#*
#******************************************************************************
###############################################################################
#
# To Do:
#

=head1 NAME

score_motifs.pl - Generate motif match scores and/or motif predictions at a
                  given score threshold.

=head1 SYNOPSIS

  score_motifs.pl [-version] [] <PWM file> <fasta file>

    <PWM file>
    A text file containing one or more motif models in MEME format.

    <fasta file>
    Fasta sequences to score for motif(s) in <PWM file>.

=head1 DESCRIPTION

  A script to generate motif scores from a PWM and a sequence file and/or
  sets of predictions exceeding a specified score threshold.

The options are:

=over 4

=item -version

Displays the version of the program

=back

=over 4

=item -help

Show this message

=back

=over 4

=item -scores

Print out base-wise window scores for all position in the input sequences in a
bed-like text format with one line per input sequence.

=back

=over 4

=item -wig-scores

Print out base-wise scores in fixed-step wig format, with a file for each motif
and a separate record for each input sequence in each file. (Implies -scores)

=back

=over 4

=item -prefix <prefix>

String to append to the beginning of each output file name. May include a
relative or absolute path to the desired output directory.
Default = "score_motifs"

=back

=over 4

-item -predictions

Report windows with scores above a give threshold as predicted motif matches.

=back

=over 4

=item -thresh <thresh>

Threshold score value to predict a motif match.

=back

=over 4

=item -bg_f <file>

NOT CURRENTLY IMPLEMENTED!

File containing background model tuple frequencies, specified as tab-delimited
key-value pairs, with a separate nucleotide/tuple on each line.
May be single-order (i.e., based on single-nucleotide observed or expected
frequencies) or any Nth-order model (i.e., based on observed or expected
frequences each possible N-tuple). Higher-order models must also include all
lower-order models to account for edge cases. The model order will be
inferred from the longest N-tuples given in the model file.

=back

=over 4

=item -pseudo <pseudocount>

Add the given pseudocount value to each entry in all PWMs and renormalize the
matrix.

=back

=over 4

=item -nthreads <N>

Number of threads to launch. Default = 1

=back

=over 4

=item -genomic_bed

Report results in a genome-referenced bed format, meaning that source sequences
are assumed to be whole-genome fasta sequences, and output coordinates are framed
as zero-based genomic coordinates. In this mode, the first three columns of the
bed output describe the actual genomic location of the motif prediction, not the
genomic coordinates of the parent sequence, as in the default mode.

=back

=head1 COPYRIGHT

Copyright 2017 Adam Diehl

=head1 AUTHOR

Adam Diehl <adadiehl@umich.edu>

=cut

#
# Module Dependence
#
use strict;
use Getopt::Long;
use Bio::Seq;
use Bio::SeqIO;
use threads;

my $sttime = time;

srand( (time ^ $$ ^ unpack "%32L*", 'ps wwaxl | gzip') );

#
# Version
#
my $Version = 0.4;
my $DEBUG   = 0;


# Parameter defaults;
my $thresh = 0;
my $scores = 0;
my $pred = 0;
my $bg_order = 0;
my $bg_f;
my $pseudo = 0;
my $as_wig = 0;
my $prefix = "score_motifs";
my $nthreads = 1;
my $gbed = 0;

#
# Option processing
#  e.g.
#   -t: Single letter binary option
#   -t=s: String parameters
#   -t=i: Number parameters
#
my @getopt_args = (
    '-version',     # print out the version and exit
    '-help',        # print help information and exit
    '-debug' => \$DEBUG, # Print various debug messages
    '-thresh=f' => \$thresh, # threshold for calling a motif prediction
    '-predictions' => \$pred, # report predictions for wins with score >= thresh
    '-scores' => \$scores, # print position-wise scores for all windows
    '-bg_f=s' => \$bg_f, # bg model file
    '-pseudo=f' => \$pseudo, # Pseudocount for PWMs
    '-wig-scores' => \$as_wig,
    '-prefix=s' => \$prefix,
    '-nthreads=i' => \$nthreads,
    '-genomic_bed' => \$gbed
);

my %options = ();
Getopt::Long::config( "noignorecase", "bundling_override" );
unless ( GetOptions( \%options, @getopt_args ) ) {
  usage();
}

if ( $options{'version'} ) {
  print "$Version\n";
  exit 0;
}

if ( $options{'help'} ||
     $#ARGV+1 < 2 ) {
    usage();
    exit 0;
}

if ( $options{'bg_order'} && !$options{'bg_f'} ) {
    die "ERROR: -bg_order requires a background model supplied with -bg_f.\n"
}

if ($as_wig) {
    $scores = 1;
}

if (!$pred && !$scores) {
    print STDERR "No output mode specified. Defaulting to predictions.\n";
    $pred = 1;
}


# Read command line args
my ($motif_f, $seq_f) = @ARGV;

# Default single-order background model based on approx. average
# genomic nucleotide frequencies.
my $bg_mod = to_log(
    {
	'A' => 0.3,
	'C' => 0.2,
	'G' => 0.2,
	'T' => 0.3
    }
    );

if ($bg_f) {
    # Read in specfied background model
    print STDERR "WARNING: -bg_f is not currently implemented. Ignoring and using single nucleotide bacground model.\n";
}

# Read in motif model(s)
print STDERR "Loading motif models...\n";
my %motifs = load_motifs($motif_f, $pseudo);

# Prepare output file handle(s)
my $SCORES_F;
my $PRED_F;
if ($scores && !$as_wig) {
    my $out_fname = join '.', ($prefix, "motif_scores", "txt");
    open $SCORES_F, '>', $out_fname;
}
if ($pred) {
    my $out_fname = join '.', ($prefix, "motif_predictions", "bed");
    open $PRED_F, '>', $out_fname;
}

# Score sequences for each motif
foreach my $key (sort(keys(%motifs))) {
    print STDERR "Scoring sequences for motif $key...\n";
    score_motif($seq_f, $motifs{$key}, $bg_mod,
		$thresh, $key, $scores, $pred,
		$PRED_F, $SCORES_F, $prefix,
		$as_wig, $nthreads, $gbed);
}

# Close file handles
if ($scores && !$as_wig) {
    close $SCORES_F;
}
if ($pred) {
    close $PRED_F;
}

# Print elapsed time
print STDERR "Elapsed time : ", time - $sttime, " seconds.\n";


############
# Subroutines

sub usage {
    print "$0 - $Version\n";
    exec "pod2text $0";
    exit( 1 );
}

sub load_motifs {
    # Load a set of position weight matrices from a meme file.
    # TO-DO: Add validation for motif models, including row
    # normalization and correct format.
    
    my ($motif_f, $pseudo) = @_;

    my %motifs;

    open my $IN, '<', $motif_f || die "Cannot read $motif_f: $!\n";

    my $pwm;
    my $name;
    my $is_score = 0;
    while (<$IN>) {
	if ($_ =~ m/MOTIF (\S+)/) {
	    # Motif name
	    $name = $1;
	    next;
	} elsif ($_ =~ m/^letter/) {
	    # PWM header line
	    $is_score = 1;
	    $pwm = [];
	    next;
	} elsif ($_ =~ m/^URL/) {
	    # End of motif block
	    $is_score = 0;
	    if ($pseudo) {
		add_pseudo($pwm, $pseudo);
	    }
	    to_log($pwm);
	    $motifs{$name} = $pwm;
	    next;
	} else {	   
	    if ($is_score) {
		$_ =~ s/^\s+//g;
		$_ =~ s/\s+$//g;
		my @tmp = split /\s+/, $_;
		push @{$pwm}, \@tmp;
	    } else {
		next;
	    }
	}
    }
    
    return %motifs;
}

sub add_pseudo {
    # Add a given pseudocount to every entry in a matrix and
    # renormalize the rows.

    my ($motif, $pseudo) = @_;

    foreach my $row (@{$motif}) {
	my $rowsum = 0;
	for (my $i = 0; $i <= $#{$row}; $i++) {
	    $row->[$i] += $pseudo;
	    $rowsum += $row->[$i];
	}
	for(my $i = 0; $i <= $#{$row}; $i++) {
	    $row->[$i] /= $rowsum;
	}
    }
}

sub print_motifs {
    my ($motifs) = @_;

    foreach my $key (keys(%{$motifs})) {
	print STDERR "$key\n";
	foreach my $row (@{$motifs->{$key}}) {
	    print STDERR "@{$row}\n";
	}
	print STDERR "\n";
    }
}

sub score_motif_thr {
    # Score/predict motif for a single sequence/thread
    my ($seq, $motif, $bg_mod, $mname, $do_scores, $do_pred, $as_wig) = @_;

    my $mlen = $#{$motif};

    my %idx = (
	'A' => 0,
	'C' => 1,
	'G' => 2,
	'T' => 3      
	);
        
    my $d = $seq->desc;
    my @fields = split /\W/, $d;
    my $chr = $fields[1];
    my $chromStart = $fields[2];
    my $chromEnd = $fields[3];
    my $id = $seq->id;

    if (!defined($chr)) {  # Try to set rational defaults
	# Chromosome is usually given in the id field
	$chr = $id;
	# Set the start and end based on the sequence length.
	# We will guess that the sequence given represents the
	# whole sequence for the given chromosome.
	$chromStart = 0;
	$chromEnd = $seq->length();
    }

    my $tmp_f;
    my $TMP;
    if ($do_scores) {
	$tmp_f = rand(100000000) .
	    (time ^ $$ ^ unpack "%32L*", 'ps wwaxl | gzip') .
	    '.tmp';
	#print STDERR "$tmp_f\n";
	open $TMP, '>', $tmp_f;
    }
    
    my @matches;
    
    for (my $i = 1; $i <= $seq->length() - $mlen; $i++) {
	my $score;
	my $win = uc $seq->subseq($i, $i+$mlen);
	my $rwin = Bio::Seq->new( -seq => $win, -alphabet => 'dna' )->revcom()->seq();
	my ($mscore_f, $mscore_r, $bgscore_f, $bgscore_r) = (0, 0, 0, 0);
	for (my $j = 0; $j <= $mlen; $j++) {
	    # + strand
	    my $char = substr($win, $j, 1);
	    next if ($char eq 'N');
	    $mscore_f += $motif->[$j]->[$idx{$char}];
	    $bgscore_f += $bg_mod->{$char};
	    # - strand
	    $char = substr($rwin, $j, 1);
	    next if ($char eq 'N');
	    $mscore_r += $motif->[$j]->[$idx{$char}];
	    $bgscore_r += $bg_mod->{$char};
	}
	my $score_f = $mscore_f - $bgscore_f;
	my $score_r = $mscore_r - $bgscore_r;
	if ($do_scores) {
	    if ($score_f > $score_r) {
		$score = sprintf("%.6f", $score_f);
	    } else {
		$score = sprintf("%.6f", $score_r);
	    }
	    print $TMP "$score\n";	    
	}
	if ($do_pred) {
	    if ($score_f > $thresh) {
		push @matches, [$mname,
				{
				    'chr' => $chr,
				    'chromStart' => $chromStart,
				    'chromEnd'=> $chromEnd,
				    'id' => $id
				},
				[
				 $chr,
				 $chromStart + $i,
				 $chromStart + $i + $mlen,
				 join(':', ($id, $mname)),
				 "+",
				 $score_f
				]
		];
	    }
	    if ($score_r > $thresh) {
		push @matches, [$mname,
				{
				    'chr' => $chr,
				    'chromStart' => $chromStart,
				    'chromEnd'=> $chromEnd,
				    'id' => $id
				},
				[
				 $chr,
				 $chromStart + $i,
				 $chromStart + $i + $mlen,
				 join(':', ($id, $mname)),
				 "-",
				 $score_r
				]
		];
	    }
	}
    }

    if ($do_scores) {
	close $TMP;
    }
    
    return {
	'tmp_f' => $tmp_f,
	'matches' => \@matches,
	'id' => $id,
	'chr' => $chr,
	'chromStart' => $chromStart,
	'chromEnd' => $fields[3],
	'desc' => $d
    };
}

sub score_motif {
    # Score a set of sequences for a given motif model
    my ($seq_f, $motif, $bg_mod, $thresh, $mname, $do_scores, $do_pred,
	$PRED_F, $TXT_F, $prefix, $as_wig, $nthreads, $gbed) = @_;

    my %results;
    
    my $seqio = Bio::SeqIO->new(-file => $seq_f, -format => "fasta");

    my $WIG_F;
    if ($as_wig) {
	my $out_fname = join '.', ($prefix, $mname, "wig");	
	open $WIG_F, '>', $out_fname;
    }

    # For some reason the threads code doesn't play nicely when only one thread
    # is allocated. Handle this case separately...
    if ($nthreads == 1) {
	my $seqio = Bio::SeqIO->new(-file => $seq_f, -format => "fasta");
	while (my $seq = $seqio->next_seq) {

	    # Check to see if the fasta file has all the required information
	    
	    my $res = score_motif_thr($seq, $motif, $bg_mod,
				      $mname, $do_scores, $do_pred);
	    print_result($res, $mname, $do_scores, $do_pred,
			 $as_wig, $PRED_F, $TXT_F, $WIG_F, $gbed);
	}
    } else {
	# Multithreaded case with >= 2 threads
	
	# Pre-scan the file to get the number of sequences (maybe there's a more
	# efficient way??)
	my $count = 0;
	my $seqio = Bio::SeqIO->new(-file => $seq_f, -format => "fasta");
	while (my $seq = $seqio->next_seq) {
	    $count++;
	}
	
	# Reset the file
	$seqio = Bio::SeqIO->new(-file => $seq_f, -format => "fasta");
	
	my $processed = 0;
	my @running = ();
	my @Threads;
	
	# Each loop checks the # of running threads and creates new threads as
	# needed to keep the number of running threads as close as possible to
	# $nthreads.
	while ($processed < $count) {

	    # Check the threads list for running/completed threads, and launch
	    # new threads as needed, until all sequences are exhausted
	    for (my $j = 0; $j < $nthreads; $j++) {
		my $thr = $Threads[$j];

		if (!defined($thr)) {
		    # No thread running at this index: start one.
		    my $seq = $seqio->next_seq();
		    next if (!defined($seq));
		    
		    my $thread = threads->create('score_motif_thr',
						 $seq, $motif, $bg_mod,
						 $mname, $do_scores,
						 $do_pred);
		    $Threads[$j] = $thread;
		    $processed++;
		    #print STDERR "$processed processed, $count total\n";

		} elsif ($thr->is_running()) {
		    # Still running...
		    next;

		} elsif ($thr->is_joinable()) {
		    # Thread is finished. Print the result and launch a new
		    # thread.
		    my $res = $thr->join;
		    print_result($res, $mname, $do_scores, $do_pred,
				 $as_wig, $PRED_F, $TXT_F, $WIG_F, $gbed);

		    my $seq = $seqio->next_seq();
		    next if (!defined($seq));
		    my $thread = threads->create('score_motif_thr',
						 $seq, $motif, $bg_mod,
						 $mname, $do_scores,
						 $do_pred);
		    $Threads[$j] = $thread;
		    $processed++;
		    #print STDERR "$processed processed, $count total\n";
		}
	    }

	    # Update the list of running threads
	    @running = threads->list(threads::running);	    
	}
	
	# Wait for all threads to complete after the main loop exits.
	while (scalar @running != 0) {
	    @running = threads->list(threads::running);
	    #	    foreach my $thr (@Threads) {
	    foreach my $thr (@Threads) {
		# Print results as each thread finishes working
		if ($thr->is_joinable()) {
		    my $res = $thr->join;
		    print_result($res, $mname, $do_scores, $do_pred,
				 $as_wig, $PRED_F, $TXT_F, $WIG_F, $gbed);
		}
	    }
	}
    }
    
    if ($as_wig) {
	close $WIG_F;
    }
    return 0;
}

sub to_log {
    my ($mod) = @_;

    if (ref($mod) eq "ARRAY") {
	foreach my $row (@{$mod}) {
	    for (my $i = 0; $i <= $#{$row}; $i++) {
		$row->[$i] = log($row->[$i]);
	    }
	}
    } elsif (ref($mod) eq "HASH") {
	for my $key (keys(%{$mod})) {
	    $mod->{$key} = log($mod->{$key});
	}
    }
    return $mod;
}

sub print_result {
    my ($res, $mname, $do_scores, $do_pred, $as_wig,
	$PRED_F, $TXT_F, $WIG_F, $gbed) = @_;

    if ($do_pred) {
	foreach my $row (@{$res->{matches}}) {
	    print_pred_line(@{$row}, $PRED_F, $gbed);
	}
    }
    if ($do_scores) {
	if ($as_wig) {
	    print_score_line_wig($res, $WIG_F);
	} else {
	    print_score_line_text($res, $mname, $TXT_F);
	}
    }   
}

sub print_wig_header {
    # Print the header line for a wig file
    # Print a single wig record
    my ($seq, $OUT) = @_;

    my $chr = "NA";
    if (defined($seq->{chr})) {
	$chr = $seq->{chr};
    } elsif (defined($seq->{id}) &&
	     $seq->{id} =~ m/chr/) {
	$chr = $seq->{id};
    }
    
    # Wig coordinates are 1-based
    my $start = 1;
    if (defined($seq->{chromStart})) {
	$start = $seq->{chromStart}+1;
    }    

    print $OUT "fixedStep chrom=$chr start=$start step=1\n";
    if (defined($seq->{desc})) {
	print $OUT "#name=$seq->{id} $seq->{desc}\n";
    }
}

sub print_score_line_wig {
    # Print a single wig record
    my ($seq, $OUT) = @_;

    print_wig_header($seq, $OUT);

    open my $TMP, '<', $seq->{tmp_f};    
    while (<$TMP>) {
	print $OUT "$_";
    }
    print $OUT "\n";
    close $TMP;
    unlink $seq->{tmp_f};
    
    return 0;
}

sub print_score_line_text {
    # Print a score set for a single record.
    my ($seq, $motif, $OUT) = @_;

    my $chr = "NA";
    if (defined($seq->{chr})) {
	$chr = $seq->{chr};
    } elsif (defined($seq->{id}) &&
	     $seq->{id} =~ m/chr/) {
	$chr = $seq->{id};
    }
    my $chromStart = 0;
    if (defined($seq->{chromStart})) {
	$chromStart = $seq->{chromStart}+1;
    }
    my $chromEnd = '.';
    if (defined($seq->{chromEnd})) {
	$chromEnd = $seq->{chromEnd};
    }
    my $id = $seq->{id};
    
    print $OUT join "\t", $chr, $chromStart, $chromEnd, $id, $motif;
    print $OUT "\t";
    
    my $i = 0;
    open my $TMP, '<', $seq->{tmp_f};
    while (<$TMP>) {
	chomp;
	if ($i > 0) {
	    print $OUT ",";
	}
	print $OUT "$_";
	$i++;
    }
    print $OUT "\n";
    close $TMP;
    unlink $seq->{tmp_f};
    
    return 0;
}

sub print_pred_line {
    my ($motif, $seq, $row, $OUT, $gbed) = @_;

    my $res;
    if ($gbed) {
	$res = [ $seq->{chr},
		 $seq->{chromStart} + $row->[1],
		 $seq->{chromStart} + $row->[2],
		 $seq->{id},
		 $motif,
		 $row->[4],
		 $row->[5] ];
    } else {
	$res = [ $seq->{chr},
		 $seq->{chromStart},
		 $seq->{chromEnd},
		 $seq->{id},
		 $motif,
		 $row->[1],
		 $row->[2],
		 $row->[4],
		 $row->[5] ];
    }
    
    print_array($res, "\t", $OUT);
}

sub dump_results {
    my ($results) = @_;

    foreach my $motif (keys(%{$results})) {
	foreach my $seq (keys(%{$results->{$motif}})) {
	    print STDERR "@{$results->{$motif}->{$seq}->{scores}}\n";
	    foreach my $row (@{$results->{$motif}->{$seq}->{matches}}) {
		print STDERR "@{$row}\n";
	    }
	}
    }
}

sub print_array {
    my ($array, $delim, $fh, $term, $nd_char) = @_;
    # input array, delimiter char, filehandle, terminator char, not-defined char
    if (!defined($delim)) {
        $delim = "\t";
    }
    if (!defined($term)) {
        $term = "\n";
    }

    if (defined($fh)) {
        select $fh;
    } else {
        select STDOUT;
    }

    for (my $i = 0; $i < $#{$array}; $i++) {
        if (defined(${$array}[$i])) {
            print "${$array}[$i]$delim";
        } else {
            if (defined($nd_char)) {
                print "$nd_char$delim";
            } else {
                print STDERR "WARNING: Some fields in array not defined with no default. Skipping!\n";
                next;
            }
        }
    }
    if (defined(${$array}[$#{$array}])) {
        print "${$array}[$#{$array}]$term";
    } else {
        if (defined($nd_char)) {
            print "$nd_char$term";
        } else {
            print STDERR "WARNING: Some fields in array not defined with no default. Skipping!\n";
            print "$term";
        }
    }

    if (defined($fh)) {
        select STDOUT;
    }
    return 0;
}


1;

