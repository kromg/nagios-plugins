#!/usr/bin/perl
# vim: se ts=4 et syn=perl:

# check_via_elasticsearch.pl - query elasticsearch and check results.
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
#       2017-07-04T15:03:27+02:00
#           v 0.0.1 - start of work.
#
#   TODO:
#       - pagination of results is not supported.
#

use strict;
use warnings;
use version; our $VERSION = qv(0.0.1);
use v5.010.001;
use utf8;
use File::Basename qw(basename);
use POSIX qw(strftime);
use Monitoring::Plugin;
use JSON::XS;


use constant                DEFAULT_SCHEME          =>      'http';
use constant                DEFAULT_HOST            =>      '127.0.0.1';
use constant                DEFAULT_PORT            =>      9200;
use constant                DEFAULT_ENDPOINT        =>      '_search';

use subs qw(
    debug
);





# ------------------------------------------------------------------------------
#  Globals
# ------------------------------------------------------------------------------
my $plugin_name = basename( $0 );
my $proxy_spec   = '[<scheme>://][<user>:<password>@]<proxy>[:<port>]';




# ------------------------------------------------------------------------------
#  Command line initialization
# ------------------------------------------------------------------------------

# This plugin's initialization - see https://metacpan.org/pod/Monitoring::Plugin
#   --verbose, --help, --usage, --timeout and --host are defined automatically.
my $np = Monitoring::Plugin->new(
    usage => "Usage: %s [-v|--verbose] [-t <timeout>] [-d|--debug] "
            . "[-h|--help] [-M|--manual] [-N|--name=<check name>] "
            . "[-H|--host <host>] [-p|--port <port>] [-S] [-e|--endpoint <search endpoint>] "
            . "[-a|--auth <USER:PASSWORD>] "
            . "[--proxy=$proxy_spec] [-P|useEnvProxy]"
            . "-c|--critical=INTEGER:INTEGER -w|--warning=INTEGER:INTEGER "
            . "{-q <query> | -Q <query file>} "
            . "{--count|--check=<field name>}",
    version => $VERSION,
    blurb   => "This plugin uses LWP::UserAgent to query Elasticsearch and then parses the output"
                . " according to the given options.",
);

# Command line options
$np->add_arg(
    spec => 'critical|c=s',
    help => qq{-c, --critical=INTEGER:INTEGER\n}
          . qq{   Critical threshold (in days) for certificate expiration.\n}
          . qq{   Don't forget the colon (see manual).\n}
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
    spec    => 'name|N=s',
    help    => qq{-N, --name=<check name>\n   Show this check name in output.},
    default => $plugin_name,
);

$np->add_arg(
    spec    => 'endpoint|e=s',
    help    => qq{-e, --endpoint=<search endpoint>\n   Use this search endpoint. Default: } . DEFAULT_ENDPOINT,
    default => DEFAULT_ENDPOINT,
);

$np->add_arg(
    spec     => 'host|H=s',
    help     => qq{-H, --host=<host>\n   Connect to this host. Default: } . DEFAULT_HOST,
    default => DEFAULT_HOST,
);

$np->add_arg(
    spec     => 'port|p=i',
    help     => qq{-p, --port=<port>\n   Connect to this port. Default: } . DEFAULT_PORT,
    default => DEFAULT_PORT,
);

$np->add_arg(
    spec     => 'auth|a=s',
    help     => qq{-a, --auth=<USER:PASSWORD>\n   Specify authenitcation for elasticsearch.},
    default => DEFAULT_PORT,
);

# TODO: specify alternative API endpoint (_bulk/_msearch) for query

$np->add_arg(
    spec => 'proxy=s',
    help => qq{--proxy=$proxy_spec\n   Use this proxy to connect to the final endpoint(s).},
);

$np->add_arg(
    spec => 'useEnvProxy|P',
    help => qq{-P, --useEnvProxy\n}
          . qq{   Get proxy configuration from environment variables.},
);

$np->add_arg(
    spec => 'S',
    help => qq{-S,\n}
          . qq{   Connect to Elasticsearch through https.},
);

$np->add_arg(
    spec => 'warning|w=s',
    help => qq{-w, --warning=INTEGER:INTEGER\n}
          . qq{   Warning threshold (in days) for certificate expiration.\n}
          . qq{   Don't forget the colon (see manual).\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);

$np->add_arg(
    spec => 'query|q=s',
    help => qq{-q, --query=<query string>\n}
          . qq{   Use the specified query string.},
);

$np->add_arg(
    spec => 'queryfile|Q=s',
    help => qq{-q, --queryfile=<query file>\n}
          . qq{   Read the query string from the specified file.},
);

$np->add_arg(
    spec => 'count',
    help => qq{--count\n}
          . qq{   Apply thresholds to the number of hits returned by the query.},
);

$np->add_arg(
    spec => 'check=s',
    help => qq{--check=<field name>\n}
          . qq{   Apply thresholds to the field named <field name>, which must be a valid field in the query output.},
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

# Set plugin short name if given on command line
if ($opts->name()) {
    $np->shortname($opts->name());
}

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


# Check that a query was specified
my $query;
if ($opts->query()) {
    $query = $opts->query();
} elsif ($opts->queryfile()) {
    $query = File::Slurp->slurp($opts->queryfile());
} else {
    $np->plugin_die('You must specify one (and only one) of -q or -Q.');
}

# Check that the check type was specified
$np->plugin_die('You must specify one (and only one) of --count or --check.')
    unless ($opts->count() || $opts->check());

# Check that thresholds were specified
$np->plugin_die('Critical threshold is mandatory')
    unless defined $opts->critical();

$np->plugin_die('Warning threshold is mandatory')
    unless defined $opts->warning();

# Prepare useragent for the query
my $ua = Local::Entirelyunlike::ESHTTPRequester->new(
    check_options   => $opts,
    check_query     => $query,
);

# Query Elasticsearch
my $response = $ua->query_elasticsearch();


# Verify no errors happened
if (! $response->is_success) {
    $np->plugin_die("Query failed: " . $response->status_line );
}


# Everything's OK, check results
my $data = JSON::XS::decode_json( $response->decoded_content );
debug ddump( [$data] );

if ($opts->count()) {
    #
    # Check that the count of hits is inside thresholds
    #
    my $total = $data->{hits}{total};
    $np->plugin_exit(
        $np->check_threshold(check => $total, warning => $opts->warning(), critical => $opts->critical()),
        sprintf( "TOTAL: %d;%d;%d;;", $total, $opts->warning(), $opts->critical() ),
        );
} else {
    my $field = $opts->check();

    my $criticals = 0;
    my $warnings  = 0;
    my $ok        = 0;

    for my $item (@{ $data->{hits}{hits} }) {
        my $val = $item->{_source}{$field};

        debug "$field: $val";

        # Cardinality of results might be important, we can't output all the results.
        # It's better to summarize:
        my $status = $np->check_threshold(check => $val, warning => $opts->warning(), critical => $opts->critical());
        if ($status == CRITICAL) {
            $criticals++;
        } elsif ($status == WARNING) {
            $warnings++;
        } elsif ($status == UNKNOWN){
            $np->plugin_die("Error checking value: $val");
        } else {
            $ok++;
        }
    }

    my $final_status = $criticals ? CRITICAL :
                            $warnings ? WARNING :
                                OK;

    $np->plugin_exit($final_status, "Criticals: $criticals; Warnings: $warnings; OK: $ok");
}


# ------------------------------------------------------------------------------
#  End of main
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------


###############################################################################
## HTTP Request wrapper
###############################################################################

package Local::Entirelyunlike::ESHTTPRequester;

use strict;
use warnings;
use v5.010.001;
use LWP::UserAgent;
use HTTP::Request;
use LWP::UserAgent;
use JSON::XS;

use parent qw(LWP::UserAgent);

use constant                DEFAULT_PROXY_SCHEMES   =>      ['http', 'https'];

sub new {
my ($class, %args) = @_;

    my $opts  = delete $args{ check_options };
    my $query = delete $args{ check_query };

    my $self = $class->SUPER::new(
        agent      => $opts->name(),
        keep_alive => 0,
        %args,
    );

    # Honor proxy as required on command line
	if (my $proxy = $opts->proxy()) {
	    main::debug "Proxy setup: ", $proxy =~ s{//.*?:.*?\@}{//XXXXXX:XXXXXX\@}r;
	    $self->proxy(DEFAULT_PROXY_SCHEMES, $proxy);
	} elsif ($opts->useEnvProxy()) {
	    main::debug "Proxy setup: using environment variables for proxy.";
	    $self->env_proxy();
	}

	# Store these for later use
	$self->{_check_options} = $opts;
	$self->{_check_query}   = $query;

    return $self;
}


sub query_elasticsearch() {
    # The user agent
    my $self = shift;

    # Get the options
    my $opts = $self->{_check_options};

    # Get the query
    my $query = $self->{_check_query};

    # Build the url for the request
	my $url = $opts->S() ? 'https' : 'http';
	$url .= '://' . $opts->host() . ':' . $opts->port() . '/' . $opts->endpoint();
	main::debug "Using url: $url";

	# Adding/modifying "size" inside the query
	$query = JSON::XS::decode_json($query);
	$query->{size} = 10000;        # default index.max_result_window (max size + from)
	$query->{from} = 0;
	$query = JSON::XS::encode_json($query);

	# Adding newlines at the end of the query
	$query .= "\n\n";
	main::debug "Using query: $query";

	# Preparing http request
	my $req = HTTP::Request->new( 'GET', $url );
	$req->header( 'Content-Type' => 'application/json' );
	$req->content( $query );
	# Adding authentication if specified
	if ($opts->auth()) {
	    my ($user, $password) = split(':', $opts->auth(), 2);
	    $req->authorization_basic($user, $password);
	}

	# Performing request and returning result
	return $self->request($req);
}








###############################################################################
## MANUAL
###############################################################################

=pod

=head1 NAME

check_via_elasticsearch.pl - .


=head1 VERSION

This is the documentation for check_via_elasticsearch.pl v0.0.1


=head1 MANUAL HAS TO BE WRITTEN

This is the manual of another check. Manual for check_via_elasticsearch.pl
has yet to be written.



=head1 SYNOPSYS

    # Check one or more target specifying how many days before certificate
    # expiration a warning or a critical must be issued; with --verify the
    # certificates common name and chain are also checked for validity:

    check_certificates.pl [--verify] -c INTEGER:INTEGER -w INTEGER:INTEGER \
        HOST[:PORT] [HOST[:PORT] ... ]


    # If you have to check a service behind a proxy, you can use environment
    # variables or specify a proxy:

    check_certificates.pl --proxy http://[user:password@]proxy[:port]/ \
        HOST[:PORT] [HOST[:PORT] ... ]

    export http_proxy=http://[user:password@]proxy[:port]/
    check_certificates.pl --useEnvProxy HOST[:PORT] [HOST[:PORT] ... ]


=head1 DESCRITPION

C<check_certificates.pl> is a simple plugin to verify when SSL certificates
will expire. Optionally, the validity of the certificates can be verified.
C<check_certificates.pl> supports checking through a proxy and using STARTTLS.


=head1 THRESHOLDS (don't forget the colon, see below)

See L<https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>
for threshold formats. In the simplest case:

    check_certificates.pl -c crit_days: -w warn_days: <targets>

will issue a warning if any one of the target certificates will expire less
than <warn_days> from now, or a critical if any one of the target certificates
will expire less than <crit_days> from now.

B<DON'T FORGET THE TRAILING COLON (:)>: if
you specify a threshold without the colon at the end, an error will be reported
if expiration days are above, and not below, the number of days you specified.
For the most general threshold syntax see the above link.


=head1 OPTIONS

=head2 B<--proxyForScheme>

Use the specified proxy for the named scheme (e.g. 'http', 'https').
The default scheme is 'http' (and it should be enough). This is equivalent to
setting environment variables C<http_proxy>, C<https_proxy> and so on. This
option can be specified multiple times, e.g.:

    ... --proxyForScheme http --proxyForScheme https ...


=head2 B<-P|--useEnfProxy>

Get proxy configuration from environmen variables:

    http_proxy
    https_proxy


=head2 B<--verify>

Perform a verification of the certificate using L<IO::Socket::SSL>'s
SSL_VERIFY_PEER verify mode.


=head2 B<--proxy [scheme]://[user:password@]proxy[:port]/>

Perform checks by CONNECTing targets through this proxy (with optional
authentication).


=head2 <-S|--starttls>

Perform a STARTTLS onto the socket before doing SSL handshake.


=head1 PREREQUISITES

Reuired modules:

=over 4

=item * parent (pragma)

=item * IO::Socket::INET6

=item * IO::Socket::SSL

=item * IO::Socket::SSL::Utils

=item * LWP::UserAgent

=item * Monitoring::Plugin

=back

for debugging:

=over 4

=item * Data::Dumper

=back




=head1 AUTHOR

Giacomo Montagner, <kromg at entirelyunlike.net>,
<kromg.kromg at gmail.com> >

=head1 BUGS AND CONTRIBUTIONS

Please report any bug at L<https://github.com/kromg/nagios-plugins/issues>. If
you have any patch/contribution, feel free to fork git repository and submit a
pull request with your modifications.


=head2 Contributors:

* Matteo Guadrini



=head1 LICENSE AND COPYRIGHT

Copyright (C) 2017 Giacomo Montagner <giacomo@entirelyunlike.net>

This program is free software: you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See http://dev.perl.org/licenses/ for more information.


=head1 AVAILABILITY

Latest sources are available from L<https://github.com/kromg/nagios-plugins>

=cut
