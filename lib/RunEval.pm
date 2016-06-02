package RunEval;
use v5.20;
use strict;
use warnings;

use IPC::Run qw/run timeout/;
use Future;
use Encode qw/encode decode/;
use utf8;
use Data::Dumper;

sub debug {say @_ if $ENV{DEBUG}};

sub common_transforms {
    my $input = "".shift();
  
    # If this dies on decoding, it means that things went differently in the eval and it's already decoded.  some weird evals do that, so handle this non-fatally
    my $uinput = "$input"; # make a copy...
    Encode::_utf8_on($uinput);
    $input = eval {decode("utf8", $uinput)} // $input;
    # Pretend every (eval \d+) is eval 1.  might cause it to miss some things but nothing important
    $input =~ s/\(eval \d+\)/(eval 1)/g;

    # Who the fuck did this?  I want to kill them.
    $input =~ s/[\x{D800}-\x{DFFF}]/\x{FFFD}/g;

    # TODO recorgnize paths to perlbrew/perl here and turn them all into PERLBREW_ROOT/perls/PERL_VERSION/...

    return $input;
}

sub compare_res {
    my ($res1, $res2) = @_;
    my $code = $res1->{code};

    # This test likely timed out in one or both branches, dump it
    if (grep {!defined} map {($_->{code}, $_->{out}, $_->{err})} ($res1, $res2)) {
        return {};
    }

    if ((length $res1->{out} == length $res2->{out}) &&
        (length $res1->{err} == length $res2->{err})) {

        debug "RES1 OUT: ", $res1->{out};
        debug "RES2 OUT: ", $res2->{out};

        debug "RES1 ERR: ", $res1->{err};
        debug "RES2 ERR: ", $res2->{err};

        # We need to decode these, so that ^ works properly on them in perl 5.24+
        my $stderr_mask = encode("utf8", $res1->{err}) ^ encode("utf8", $res2->{err});
        my $stdout_mask = encode("utf8", $res1->{out}) ^ encode("utf8", $res2->{out});

        # turn everything except \0 into \xFF and anythign else into \0.
        $stderr_mask =~ s/(.)/$1 eq "\0" ? "\xFF" : "\0"/egsi;
        $stdout_mask =~ s/(.)/$1 eq "\0" ? "\xFF" : "\0"/egsi;

        # blob close matches together, likely the same digit in the same place kind of thing, we should try to compensate
        $stderr_mask =~ s/\x00\xFF\x00/\x00\x00\x00/g;
        $stderr_mask =~ s/\x00\xFF\xFF\x00/\x00\x00\x00\x00/g;
        $stderr_mask =~ s/\x00\x00\xFF$/\x00\x00\x00/; # take care of a trailing digit usually
        $stderr_mask =~ s/^\xFF\x00\x00/\x00\x00\x00/; # similarly take care of leading digits

        $stdout_mask =~ s/\x00\xFF\x00/\x00\x00\x00/g;
        $stdout_mask =~ s/\x00\xFF\xFF\x00/\x00\x00\x00\x00/g;
        $stdout_mask =~ s/\x00\x00\xFF$/\x00\x00\x00/; # take care of a trailing digit usually
        $stdout_mask =~ s/^\xFF\x00\x00/\x00\x00\x00/; # similarly take care of leading digits

        return {
            code => $code,
            out => $res1->{out},
            err => $res1->{err},
            out_mask => unpack("H*", $stdout_mask),
            err_mask => unpack("H*", $stderr_mask),
        }
    } else {
        $res1->{volatile} = 1;
        return $res1;
    }
}

# Takes a code segment, returns a future that finishes when all results are ready
sub make_async {
    my ($code, $loop) = @_;

    debug "Making Async";

    my $first_future  = runner_async($code, $loop);
    my $second_future = runner_async($code, $loop);

    debug "Spawned procs, creating Future->needs_all";

    my $final_future = Future->needs_all($first_future, $second_future);

    debug "Returning";
#    $final_future->on_ready(\&future_to_result);

    return $final_future;
}

sub future_to_result {
    my ($final_future) = @_;

    my ($first_future, $second_future) = $final_future->done_futures;

    # unwrap the futures, pretending they gave empty hashes if they failed
    my $res1 = eval {$first_future->get} // {};
    my $res2 = eval {$second_future->get} // {};

    return compare_res($res1, $res2);
}

sub runner_async {
    my ($code, $loop) = @_;

    my $c_in = "perl $code";

    $c_in = encode("utf8", $c_in); # we need to treat it as a raw byte stream because of a bug

    my $cmd = ['sudo', './runeval.sh'];
 
    debug "Code out is << $c_in >>";
    debug "cmd is", @$cmd;

    my $proc_future = $loop->new_future();
    my $child_pid = $loop->run_child(command => $cmd, stdin => $c_in, on_finish => sub {
            my ($pid, $exitcode, $stdout, $stderr) = @_;

            $stdout = common_transforms $stdout;
            $stderr = common_transforms $stderr;

            $proc_future->done({code => $code, out => $stdout, err => $stderr});
        });

    debug "Child pid is $child_pid";

    my $killmepls = sub {
            kill 9, $child_pid; # Attempt to kill off the child, might need to do weird shit with root for this to work.
    };
    $proc_future->on_cancel($killmepls);
    $proc_future->on_fail($killmepls);

    debug "Procfuture filled out";

    my $timeout_future = $loop->timeout_future(after => 30);
    $timeout_future->on_fail(sub {$proc_future->cancel}); # make sure we cancel the proc future.

    debug "timeout filled out";

    return Future->wait_any($proc_future, $timeout_future);
}

sub runner_ipc {
    my ($code) = @_;
    my ($c_out, $c_err);

    my $c_in = "perl $code";

    $c_in = encode("utf8", $c_in); # we need to treat it as a raw byte stream because of a bug
    my $cmd = ['sudo', './runeval.sh'];
    
    my $res = eval {run $cmd, \$c_in, \$c_out, \$c_err, timeout(30);};

    $c_out = common_transforms $c_out;
    $c_err = common_transforms $c_err;

    return {code => $code, out => $c_out, err => $c_err};
}

sub make_result {
    my ($code) = @_;

    # run it twice, record both results
    my $res1 = run_eval($code);
    my $res2 = run_eval($code);

    return compare_res($res1, $res2);
}

1;
