#!/usr/bin/perl
# vim: se ts=4 et syn=perl:

# check_certificates.pl - Verify expiration dates of SSL certificates.
#
#     Copyright (C) 2017 Giacomo Montagner <giacomo@entirelyunlike.net>
#
#     This program is free software: you can redistribute it and/or modify
#     it under the same terms as Perl itself, either Perl version 5.8.4 or,
#     at your option, any later version of Perl 5 you may have available.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
#
#
#   CHANGELOG:
#
#       2017-02-18T22:52:37+01:00
#           v 0.1.0 released.
#               TODO: write manual.
#

use strict;
use warnings;
use version; our $VERSION = qv(0.1.0);
use v5.010.001;
use utf8;
use File::Basename qw(basename);

use Monitoring::Plugin;
use IO::Socket::SSL;
use IO::Socket::SSL::Utils;
use LWP::UserAgent;
use POSIX qw(strftime);

use constant                DEFAULT_PORT    =>       443;

use constant                PROXY_PORT      =>      8080;
use constant                PROXY_SCHEMES   =>      [ qw( http https ) ];

use subs qw(
    debug
);








# ------------------------------------------------------------------------------
#  Globals
# ------------------------------------------------------------------------------
our $plugin_name = basename( $0 );
my $proxy_spec   = '[<scheme>://][<user>:<password>@]<proxy>[:<port>]';




# ------------------------------------------------------------------------------
#  Command line initialization
# ------------------------------------------------------------------------------

# This plugin's initialization - see https://metacpan.org/pod/Monitoring::Plugin
#   --verbose, --help, --usage, --timeout and --host are defined automatically.
my $np = Monitoring::Plugin::CheckCerts->new(
    usage => "Usage: %s [-v|--verbose] [-t <timeout>] [-d|--debug] "
            . "[-h|--help] [-M|--manual] "
            . "[-P|--useEnvProxy] [--proxy=$proxy_spec] [--proxyForScheme=<scheme>] "
            . "[--verify]"
            . "[-c|--critical=<threshold>] [-w|--warning=<threshold>] "
            . "HOST[:PORT] [HOST[:PORT] [...]]",
    version => $VERSION,
    blurb   => "This plugin uses IO::Socket::SSL to check the validity of an SSL"
                . " certificate by connecting to the specified HOST[:PORT].",
);

# Command line options
$np->add_arg(
    spec => 'critical|c=s',
    help => qq{-c, --critical=INTEGER:INTEGER\n}
          . qq{   Critical threshold (in days) for certificate expiration.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable). },
);

$np->add_arg(
    spec => 'debug|d',
    help => qq{-d, --debug\n   Print debugging messages to STDERR. }
          . qq{Package Data::Dumper is required for debug.},
);

$np->add_arg(
    spec => 'manual|M',
    help => qq{-M, --manual\n   Show plugin manual (requires perldoc executable).},
);

$np->add_arg(
    spec => 'proxy=s',
    help => qq{--proxy=$proxy_spec\n   Use this proxy to connect to the final endpoint(s).},
);

$np->add_arg(
    spec => 'proxyForScheme=s@',
    help => qq{--proxyForScheme=<scheme>\n   Specify to which scheme(s) the }
          . qq{proxy applies. This option can be specified multiple times. }
          . qq{The default is to use proxy for https, as if 'https_proxy' }
          . qq{environment variable was set.},
);

$np->add_arg(
    spec => 'useEnvProxy|P',
    help => qq{-P, --useEnvProxy\n}
          . qq{   Get proxy configuration from environment variables.},
);

$np->add_arg(
    spec => 'verify',
    help => qq{--verify\n}
          . qq{   Enable certificate validity verification.\n}
          . qq{   If certificate and certificate chain are not valid, a }
          . qq{critical event is issued. The default is to NOT validate }
          . qq{certificates automatically.},
);

$np->add_arg(
    spec => 'warning|w=s',
    help => qq{-w, --warning=INTEGER:INTEGER\n}
          . qq{   Warning threshold (in days) for certificate expiration.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);



# It would be easy to do this and then die() peacefully from everywhere it's
# required, but it would break any eval{} in the code from here to everywhere,
# so it cannot be done. I document it here so no one else is tempted to do
# this.
# $SIG{ __DIE__ } = sub {
#   $np->plugin_die(@_);
# };



# ------------------------------------------------------------------------------
#  Command line parsing
# ------------------------------------------------------------------------------

# Parse @ARGV and process standard arguments (e.g. usage, help, version)
$np->getopts();
my $opts = $np->opts();

if ($opts->manual()) {
    exec(qq{\$(which perldoc) $0});
}

if ($opts->debug()) {
    require Data::Dumper;
    *debug = sub { say STDERR "DEBUG :: ", @_; };
    *ddump = sub { Data::Dumper->Dump( @_ ); };
} else {
    *debug = sub { return; };
    *ddump = *debug;
}

unless(@ARGV) {
    $np->plugin_die("No targets specified on command line");
}

# Set the verification method to be used when getting the certificate
my $verification_method =
    $opts->verify()         ?
        SSL_OCSP_FULL_CHAIN :
        SSL_VERIFY_NONE     ;
debug("Using verification method: ", $verification_method);



# ------------------------------------------------------------------------------
#  If a proxy is configured, prepare user agent for the probe
# ------------------------------------------------------------------------------

my $ua;
if (my $proxy = $opts->proxy()) {

    # Avoid printing credentials in debug
    debug "Proxy setup: ", $proxy =~ s{//.*?:.*?\@}{//XXXXXX:XXXXXX\@}r;

	$ua = LWP::UserAgent->new(
        agent      => $plugin_name,
        keep_alive => 0,
    );

    my $proxy_schemes = $opts->proxyForScheme() || PROXY_SCHEMES;

    debug "Using proxy for schemes: @$proxy_schemes";

	$ua->proxy( $proxy_schemes, $proxy );
}


# ------------------------------------------------------------------------------
#  Probe all targets
# ------------------------------------------------------------------------------

TARGET: for my $target (@ARGV) {

    # Get the target
    my ($host, $port) = split(':', $target);
    $port //= DEFAULT_PORT;

    # Get the SSL socket.
    my $client;

    if ($ua) {

        debug "Using proxy";

        # connect to the proxy
        my $req = HTTP::Request->new(
            CONNECT => "http://$host:$port/" );
        my $res = $ua->request($req);

        # authentication failed
        $res->is_success()
            or $np->plugin_die(
                "CONNECT failed through proxy for target $host:$port: ["
                . $res->code. "] ". $res->message());

	    unless ($client = IO::Socket::SSL->start_SSL($res->{client_socket}) ) {
            $np->add_critical("target=$target, error=$!, ssl_error=$SSL_ERROR");
            next TARGET;
        }

    } else {

        unless (
            $client = IO::Socket::SSL->new(
                PeerAddr        => $host,
                PeerPort        => $port,
                SSL_verify_mode => $verification_method,
            )
        ) {
            $np->add_critical("target=$target, error=$!, ssl_error=$SSL_ERROR");
            next TARGET;
        }
    }

    # Connection has been established, now check the certificate:
    my $cert = CERT_asHash( $client->peer_certificate() );

    # debug( Data::Dumper->Dump([$cert], [$target]) );

    my $days_to_expiration = int( ( $cert->{ not_after } - time() ) / 86400 );

    my $status = $np->check_threshold(
        check => $days_to_expiration,
        warning => $opts->warning(),
        critical => $opts->critical()
    );

    my $expiry_date = strftime("%a %d %b %Y %H:%M:%S %Z", localtime( $cert->{ not_after } ) );

    if ($status == OK) {
        $np->add_ok( "target=$target, expires=$expiry_date ($days_to_expiration days)" );
    } elsif ($status == WARNING) {
        $np->add_warning( "target=$target, expires=$expiry_date ($days_to_expiration days)" );
    } elsif ($status == CRITICAL) {
        $np->add_critical( "target=$target, expires=$expiry_date ($days_to_expiration days)" );
    }

    close($client);

}

# Build final message
my $msg;
my @crits = $np->criticals();
$msg .= "CRITICAL: ". join("; ", @crits). "; "
    if @crits;

my @warns = $np->warnings();
$msg .= "WARNING: ". join("; ", @warns). "; "
    if @warns;

my @oks = $np->oks();
$msg .= "OK: ". join("; ", @oks). "; "
    if @oks;

# Finally, exit
$np->plugin_exit( $np->status(), $msg );





###############################################################################
## Monitoring::Plugin extension
###############################################################################
package Monitoring::Plugin::CheckCerts;

use strict;
use warnings;
use Monitoring::Plugin;
use parent qw(
    Monitoring::Plugin
);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{_checkcerts_status} = 0;
    $self->{_checkcerts_oks} = [];
    $self->{_checkcerts_warnings} = [];
    $self->{_checkcerts_criticals} = [];

    return $self;
}

sub raise_status {
    my ($self, $newStatus) = @_;
    $self->{_checkcerts_status} = $newStatus
        if $self->{_checkcerts_status} < $newStatus;
}

sub add_warning {
    my $self = shift;

    push @{ $self->{_checkcerts_warnings} }, @_;

    $self->raise_status( WARNING );
}

sub add_critical {
    my $self = shift;

    push @{ $self->{_checkcerts_criticals} }, @_;

    $self->raise_status( CRITICAL );
}

sub add_ok {
    my $self = shift;

    push @{ $self->{_checkcerts_oks} }, @_;
}

sub add_status {
    my ($self, $status, $reason) = @_;

    if ($status == OK) {
        $self->add_ok( $reason );
    } elsif ($status == WARNING) {
        $self->add_warning( $reason );
    } elsif ($status == CRITICAL) {
        $self->add_critical( $reason );
    }
}

sub status {
    return $_[0]->{_checkcerts_status};
}

sub oks {
    return wantarray                    ?
        @{ $_[0]->{_checkcerts_oks} } :
           $_[0]->{_checkcerts_oks}   ;
}

sub warnings {
    return wantarray                    ?
        @{ $_[0]->{_checkcerts_warnings} } :
           $_[0]->{_checkcerts_warnings}   ;
}

sub criticals {
    return wantarray                    ?
        @{ $_[0]->{_checkcerts_criticals} } :
           $_[0]->{_checkcerts_criticals}   ;
}


