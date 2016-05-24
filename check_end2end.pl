#!/usr/bin/perl
# vim: se ts=4 et syn=perl:

# check_end2end.pl - Simple configurable end-to-end probe plugin for Nagios
#
#     Copyright (C) 2016 Giacomo Montagner <giacomo@entirelyunlike.net>
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
#       2016-05-19T08:46:55+0200
#           First release.
#
#       2016-05-24T11:13:44+0200 v1.0.1
#           - Removed "Export" as parent to Monitoring::Plugin::End2end;
#           - Added TODO to make steps optional
#


use strict;
use warnings;
use version; our $VERSION = qv(1.0.1);
use v5.010.001;
use utf8;
use File::Basename qw(basename);

use Config::General;
use Monitoring::Plugin;
use LWP::UserAgent;
use Time::HiRes qw(time);

use subs qw(
    debug
);








# ------------------------------------------------------------------------------
#  Globals
# ------------------------------------------------------------------------------
my $plugin_name = basename( $0 );




# ------------------------------------------------------------------------------
#  Command line initialization and parsing
# ------------------------------------------------------------------------------

# This plugin's initialization - see https://metacpan.org/pod/Monitoring::Plugin
#   --verbose, --help, --usage, --timeout and --host are defined automatically.
my $np = Monitoring::Plugin::End2end->new(
    usage => "Usage: %s [-v|--verbose] [-t <timeout>] [-d|--debug] [-M|--manual] "
          . "[-c|--critical=<threshold>] [-w|--warning=<threshold>] "
          . "[-C|--totcritical=<threshold>] [-W|--totwarning=<threshold>] "
          . "-f|--configFile=<cfgfile>",
    version => $VERSION,
    blurb   => "This plugin uses LWP::UserAgent to fake a website navigation"
                . " as configured in the named configuration file.",
);

# Command line options
$np->add_arg(
    spec => 'debug|d',
    help => qq{-d, --debug\n   Print debugging messages to STDERR. }
          . qq{Package Data::Dumper is required for debug.},
);

$np->add_arg(
    spec => 'warning|w=s',
    help => qq{-w, --warning=INTEGER:INTEGER\n}
          . qq{   Warning threshold for each single step.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);

$np->add_arg(
    spec => 'critical|c=s',
    help => qq{-c, --critical=INTEGER:INTEGER\n}
          . qq{   Critical threshold for each single step.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable). },
);

$np->add_arg(
    spec => 'totwarning|W=s',
    help => qq{-W, --totwarning=INTEGER:INTEGER\n}
          . qq{   Warning threshold for the whole process.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable).},
);

$np->add_arg(
    spec => 'totcritical|C=s',
    help => qq{-C, --totcritical=INTEGER:INTEGER\n}
          . qq{   Critical threshold for the whole process.\n}
          . qq{   See https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT }
          . qq{for the threshold format, or run $plugin_name -M (requires perldoc executable). },
);

$np->add_arg(
    spec => 'configFile|f=s',
    help => qq{-f, --configFile=/path/to/file.\n   Configuration }
          . qq{of the steps to be performed by this plugin. }
          . qq{See "perldoc $plugin_name" for details con configuration format, }
          . qq{or run $plugin_name -M},
);

$np->add_arg(
    spec => 'manual|M',
    help => qq{-M, --manual\n   Show plugin manual (requires perldoc executable).},
);

# Parse @ARGV and process standard arguments (e.g. usage, help, version)
$np->getopts;
my $opts = $np->opts();

if ($opts->manual()) {
    exec(qq{\$(which perldoc) $0});
}

if ($opts->debug) {
    require Data::Dumper;
    *debug = sub { say STDERR "DEBUG :: ", @_; };
    *ddump = sub { Data::Dumper->Dump( @_ ); };
} else {
    *debug = sub { return; };
    *ddump = *debug;
}

unless ($opts->configFile()) {
    $np->plugin_die("Missing mandatory option: --configFile|-f");
}


# ------------------------------------------------------------------------------
#  External configuration loading
# ------------------------------------------------------------------------------

# Read configuration file
my $conf = Config::General->new(
    -ConfigFile => $opts->configFile(),
    -InterPolateVars => 1,
    -InterPolateEnv => 0,                   # TODO: be configurable
    -StrictVars => 1,                       # TODO: be configurable
    -ExtendedAccess => 1,
);

if ($conf->exists("Monitoring::Plugin::shortname")) {
    $np->shortname( $conf->value("Monitoring::Plugin::shortname") );
}





# ------------------------------------------------------------------------------
#  MAIN :: Do the check
# ------------------------------------------------------------------------------

# Perform each configured step
my $ua = LWP::UserAgent->new(
    agent      => $conf->exists("LWP::UserAgent::agent") ? $conf->value("LWP::UserAgent::agent") : "$plugin_name",
    cookie_jar => { },
    # TODO: be more configurable
);

my $steps = Steps->new( $conf->hash("Step") );

# Check for thresholds before performing steps
my @step_names = $steps->list();
my $num_steps = @step_names;

my $warns = Thresholds->new( $opts->warning(),  @step_names );
debug "WARNING THRESHOLDS: ", ddump([$warns]);
my $crits = Thresholds->new( $opts->critical(), @step_names );
debug "CRITICAL THRESHOLDS: ", ddump([$crits]);


# Now for the real check
if ($opts->timeout()) {
    $SIG{ALRM} = sub {
        $np->plugin_die("Operation timed out after ". $opts->timeout(). "s" );
    };

    alarm $opts->timeout();
}

# TODO: make steps optional by specifying some configuration variable like
# "on_failure = WARNING"

my $totDuration = 0;
for my $step_name ( @step_names ) {

    debug "Performing step: ", $step_name;

    my $step = $steps->step( $step_name )
        or $np->plugin_die("Malformed configuration file -- cannot proceed on step $step_name");

    debug "URL: ", $step->url();
    debug "Data: ", ddump([ $step->data() ])
        if $step->data();
    debug "Method: ", $step->method();

    my $response;
    my $method = $step->method();

    my $before = time();
    if (defined( $step->data() )) {
        $response = $ua->$method(
            $step->url(),
            $step->data(),
        );
    } else {
        $response = $ua->$method( $step->url() );
    }
    my $after = time();

    my $duration = sprintf("%.3f", $after - $before);
    $totDuration += $duration;
    my $warn = $warns->get( $step_name );
    my $crit = $crits->get( $step_name );

    if ($response->is_success) {
        $np->add_perfdata( label => "Step_${step_name}_duration", value => $duration, uom => "s", warning => $warn, critical => $crit );
        my $status = $np->check_threshold( check => $duration, warning => $warn, critical => $crit );

        if ($status == OK) {
            $np->add_ok( "Step $step_name took ${duration}s" );
        } elsif ($status == WARNING) {
            $np->add_warning( "Step $step_name took ${duration}s > ${warn}s" );
        } elsif ($status == CRITICAL) {
            $np->add_critical( "Step $step_name took ${duration}s > ${crit}s" );
        }
    }
    else {
        $np->plugin_exit(CRITICAL, plugin_message( "Step $step_name failed (". $response->status_line(). ")" ));
    }

}



# Prepare for exit
my $msg = 'Check complete. ';

# Check total duration time against thresholds
my $tc = $opts->totcritical() || '';
my $tw = $opts->totwarning()  || '';
$np->add_perfdata( label => "Total_duration", value => $totDuration, uom => "s", warning => $tw, critical => $tc );

my $status = $np->check_threshold( check => $totDuration, warning => $tw, critical => $tc );

if ( $status == CRITICAL ) {
    $msg .= "CRITICAL: Total duration was ${totDuration}s > ${tc}s; ";
    $np->raise_status( CRITICAL );
} elsif ( $status == WARNING ) {
    $msg .= "WARNING Total duration was ${totDuration}s > ${tw}s; ";
    $np->raise_status( WARNING );
}

# Build final message
my @crits = $np->criticals();
$msg .= "CRITICAL steps: ". join("; ", @crits). "; "
    if @crits;

my @warns = $np->warnings();
$msg .= "WARNING steps: ". join("; ", @warns). "; "
    if @warns;

my @oks = $np->oks();
$msg .= "Steps OK: ". join("; ", @oks). "; "
    if @oks;

# Finally, exit
$np->plugin_exit( $np->status(), $msg );













###############################################################################
## Monitoring::Plugin extension
###############################################################################
package Monitoring::Plugin::End2end;

use strict;
use warnings;
use Monitoring::Plugin;
use parent qw(
    Monitoring::Plugin
);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{_end2end_status} = 0;
    $self->{_end2end_oks} = [];
    $self->{_end2end_warnings} = [];
    $self->{_end2end_criticals} = [];

    return $self;
}


sub add_warning {
    my $self = shift;

    push @{ $self->{_end2end_warnings} }, @_;

    $self->{_end2end_status} = WARNING
        unless $self->{_end2end_status} && $self->{_end2end_status} > WARNING;
}

sub add_critical {
    my $self = shift;

    push @{ $self->{_end2end_criticals} }, @_;

    $self->{_end2end_status} = CRITICAL
        unless $self->{_end2end_status} && $self->{_end2end_status} > CRITICAL;
}

sub add_ok {
    my $self = shift;

    push @{ $self->{_end2end_oks} }, @_;
}

sub status {
    return $_[0]->{_end2end_status};
}

sub raise_status {
    my ($self, $newStatus) = @_;
    $self->{_end2end_status} = $newStatus
        if $self->{_end2end_status} < $newStatus;
}

sub oks {
    return wantarray                    ?
        @{ $_[0]->{_end2end_oks} } :
           $_[0]->{_end2end_oks}   ;
}

sub warnings {
    return wantarray                    ?
        @{ $_[0]->{_end2end_warnings} } :
           $_[0]->{_end2end_warnings}   ;
}

sub criticals {
    return wantarray                    ?
        @{ $_[0]->{_end2end_criticals} } :
           $_[0]->{_end2end_criticals}   ;
}





###############################################################################
## DATA HANDLER
###############################################################################

package Data;

use strict;
use warnings;
use URI::URL;

sub new {
    my $class = shift;
    my $url = URI::URL->new("?".$_[0]);

    return bless( { $url->query_form() }, $class );
}



###############################################################################
## STEP HANDLER
###############################################################################

package Step;

use strict;
use warnings;

sub new {
    my $class = shift;
    return unless ref( $_[0] ) && ref( $_[0] ) eq 'HASH';

    my $step = {};

    return unless $step->{url} = delete $_[0]->{url};

    if (defined( my $data = delete $_[0]->{binary_data})) {
        return unless $step->{data} = Data->new( $data );
    }

    $step->{method} = $_[0]->{method} ? lc( $_[0]->{method} ) : 'get';

    return bless( $step, $class );
}


sub url {
    return $_[0]->{url};
}

sub data {
    return unless $_[0]->{data};
    my %data = %{ $_[0]->{data} };
    return \%data;
}

sub method {
    return $_[0]->{method};
}


###############################################################################
## STEPS HANDLER
###############################################################################

package Steps;

use strict;
use warnings;

sub new {
    my $class = shift;
    return bless({ @_ }, $class);
}


sub step {
    return Step->new( $_[0]->{ $_[1] } );
}

sub list {
    return wantarray                 ?
        sort( keys( %{ $_[0] } ) )    :
        [ sort( keys( %{ $_[0] } ) ) ];
}






###############################################################################
## THRESHOLDS HANDLER
###############################################################################

package Thresholds;

sub new {
    my $class = shift;
    my $val   = shift || '';
    my @names = @_;

    my %thr;
    if ($val =~ /,/) {
        my @thr = split(/\s*,\s*/, $val);
        %thr = map { $names[ $_ ] => (defined( $thr[ $_ ] ) ? $thr[ $_ ] : '') } 0..$#names;
    } else {
        %thr = map { $names[ $_ ] => $val } 0..$#names;
    }

    return bless( \%thr, $class );
}




sub get {
    return $_[0]->{ $_[1] };
}






###############################################################################
## MANUAL
###############################################################################

=pod

=head1 NAME

check_end2end.pl - Simple configurable end-to-end probe plugin for Nagios


=head1 VERSION

This is the documentation for check_end2end.pl v1.0.1


=head1 SYNOPSYS

See check_end2end.pl -h


=head1 THRESHOLD FORMATS

=head2 FOREWORD

Every step configured in the configuration file (see L<CONFIGURATION FILE
FORMAT>) is performed regardless of the fact that you specify a threshold for
that step, a global threshold, or a single thresold that will be applied to
every step, because B<every step is checked for success or failure>.

A failure in one of the steps will cause the immediate exit of the check, with
a critical status, while if one or more steps are above their time thresholds
the check will continue and perform the remaining steps (unless the global
timeout is reached).

Overall status of the check will be reported at the end.

=head2 -C <CRIT>, -W <WARN>

Total-duration thresholds are just single values in the format specified by
L<https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>.
For example:

    -W 0.200:1.0

will give a warning if the total duration of the process is below 0.2s or
above 1.0s.


=head2 -c <crit>, -w <warn>

These are per-step duration thresholds. B<If only one value is specified,
that value will be applied to ALL steps in the process>, one by one.
The values still follow the format at
L<https://www.monitoring-plugins.org/doc/guidelines.html#THRESHOLDFORMAT>.

For example:

    -c 3

will give you a critical if B<any one> of the steps in you process will last
more than 3s (or less than 0 but that would mean your clock reset in the middle
of the process).

But single-steps thresholds can be specified as a B<comma-separated list of
values>; each individual value follows the already-named guidelines, and
omitted values will be taken as no-threshold for the corresponding step.
The thresholds are appled in order.

So, for example, if you have a 5-step check and only want to apply check to
some steps, you will have to specify:

    -w ,0.2,,,0.5 -c ,0.6,1.1

This will apply a warning threshold of 0.2s and a critical threshold of 0.6s
to the second step, a warning threshold of 0.5s to the fifth step, and a
critical threshold of 1.1s to the third step.

=head3 B<Omitting trailing commas>

You can omit trailing commas if you specify at least two values and don't need
others. For example, to specify thresholds only for the first two steps of a
7-steps process:

    -w 1,3 -c 3,6

will perform all the configured checks, but only the first and the second will
be checked against their thresholds. If you want to apply thresholds only to
the first step, you have to provide at least one trailing comma:

    -w 0.7,

speficies a warning threshold of 0.7s only for the first step.


=head1 CONFIGURATION FILE FORMAT

Here's a sample configuration file for this plugin

    #
    # login.cfg -- Configuration file for login check on www.example.com
    #


    ########## check_end2end -specific configuration directives
    #
    # Optional - override default "END2END" plugin name in outputs
    Monitoring::Plugin::shortname = "Check www.example.com Login"

    ########## LWP::UserAgent -specific configuration directives
    #
    # Optional - Override useragent string - defaults to check_end2end
    LWP::UserAgent::agent = "Nagios login check via check_end2end"


    ########## Custom configuration directives
    #
    # Optional - You can specify variables to be interpolated in the
    # following configuration
    BASE_URL = "https://www.example.com"



    ########## check_end2end REQUIRED CONFIGURATION
    #
    # This plugin requires you to specify a list of subsequent steps to be performed.
    # Steps will be performed IN ALPHABETICAL ORDER, so make sure you give them
    # names according to a proper sequence.
    #
    <Step "00 - Public login page">
        url = "$BASE_URL/login.html"
        method = GET
    </Step>

    # Lines can be split as in shell scripts, escaping the final newline with a \
    <Step "01 - Login verification">
        url = "$BASE_URL/login.html"
        binary_data = username=exampleuser&\
            password=examplepassword
        method = POST
    </Step>

    <Step "03 - Private login page">
        url = "$BASE_URL/pri/home.html"
        method = GET
    </Step>

=cut