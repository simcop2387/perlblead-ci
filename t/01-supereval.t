#!/usr/bin/env perl

use v5.20;
use feature qw/postderef/;

use strict;
use warnings;
no warnings 'experimental';

use Data::Dumper;
use JSON::MaybeXS;
use IPC::Run qw/run timeout/;
use utf8;
use open ':std', ':encoding(utf8)';
use Test::More;
use List::Util qw/reduce shuffle/;


my $tests = do {local $/; open(my $fh, "<t/filtered.json"); decode_json <$fh>};
my $fulltests = reduce {[@$a, @$b]} map {$tests->{$_}} keys $tests->%*;

my $numtests = int(0.10 * @$fulltests);
my @testindexes = (shuffle (0..$#$fulltests))[1..$numtests];

plan tests => 2*$numtests;

    for my $tn (@testindexes) {
        my ($c_out, $c_err);
        my $test = $fulltests->[$tn];
        my $code = $test->{code};

        my $c_in = "perl $code";

        my $cmd = ['sudo', './runeval.sh'];
        
#        print STDERR "${fn}[$rand]: $code";
        eval {run $cmd, \$c_in, \$c_out, \$c_err, timeout(30);};

        my $mapsub = sub {
            $c_err =~ s/\(eval \d+\)/(eval 1)/g;
            $c_out =~ s/\(eval \d+\)/(eval 1)/g;
        };
        $mapsub->();

        unless ($@) {
            is($c_err, $test->{err}, "STDERR for: $code");
            is($c_out, $test->{out}, "STDOUT for: $code");
        } else {
            diag "Eval failed, $@";
        }
    }

#done_testing();
