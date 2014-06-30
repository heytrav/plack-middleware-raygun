use strict;
use warnings;

package Plack::Middleware::Raygun;

use parent qw(Plack::Middleware);

use Devel::StackTrace;
use Devel::StackTrace::AsHTML;
use Try::Tiny;
use Plack::Util::Accessor qw( force no_print_errors );

use WebService::Raygun;

our $StackTraceClass = "Devel::StackTrace";

# Optional since it needs PadWalker
if (
    try {
        require Devel::StackTrace::WithLexicals;
        Devel::StackTrace::WithLexicals->VERSION(0.08);
        1;
    })
{
    $StackTraceClass = "Devel::StackTrace::WithLexicals";
}

sub call {
    my ($self, $env) = @_;

    my $trace;
    local $SIG{__DIE__} = sub {
        $trace = $StackTraceClass->new(
            indent         => 1,
            message        => munge_error($_[0], [caller]),
            ignore_package => __PACKAGE__,
        );
        die @_;
    };

    my $caught;
    my $res = try {
        $self->app->($env);
    }
    catch {
        $caught = $_;
        [
            500,
            [ "Content-Type", "text/plain; charset=utf-8" ],
            [ no_trace_error(utf8_safe($caught)) ] ];
    };

    if (
        $trace
        && ($caught
            || ($self->force && ref $res eq 'ARRAY' && $res->[0] == 500)))
    {
        my $text = $trace->as_string;
        my $html = $trace->as_html;
        $env->{'plack.stacktrace.text'} = $text;
        $env->{'plack.stacktrace.html'} = $html;
        $env->{'psgi.errors'}->print($text) unless $self->no_print_errors;
        if (($env->{HTTP_ACCEPT} || '*/*') =~ /html/) {
            $res = [
                500,
                [ 'Content-Type' => 'text/html; charset=utf-8' ],
                [ utf8_safe($html) ] ];
        }
        else {
            $res = [
                500,
                [ 'Content-Type' => 'text/plain; charset=utf-8' ],
                [ utf8_safe($text) ] ];
        }
    }

    # break $trace here since $SIG{__DIE__} holds the ref to it, and
    # $trace has refs to Standalone.pm's args ($conn etc.) and
    # prevents garbage collection to be happening.
    undef $trace;

    return $res;
}

sub no_trace_error {
    my $msg = shift;
    chomp($msg);

    return <<EOF;
The application raised the following error:

  $msg

and the StackTrace middleware couldn't catch its stack trace, possibly because your application overrides \$SIG{__DIE__} by itself, preventing the middleware from working correctly. Remove the offending code or module that does it: known examples are CGI::Carp and Carp::Always.
EOF
}

sub munge_error {
    my ($err, $caller) = @_;
    return $err if ref $err;

    # Ugly hack to remove " at ... line ..." automatically appended by perl
    # If there's a proper way to do this, please let me know.
    $err =~ s/ at \Q$caller->[1]\E line $caller->[2]\.\n$//;

    return $err;
}

sub utf8_safe {
    my $str = shift;

    # NOTE: I know messing with utf8:: in the code is WRONG, but
    # because we're running someone else's code that we can't
    # guarantee which encoding an exception is encoded, there's no
    # better way than doing this. The latest Devel::StackTrace::AsHTML
    # (0.08 or later) encodes high-bit chars as HTML entities, so this
    # path won't be executed.
    if (utf8::is_utf8($str)) {
        utf8::encode($str);
    }

    $str;
}

1;

1;