# nagios-plugins

Collection of plugins for Nagios.

check_certificates.pl: plugin to verify expiration dates of SSL certificates.

    Requires:

        - Data::Dumper (only if run with -d)

        - IO::Socket::SSL

        - IO::Socket::SSL::Utils

        - LWP::UserAgent

        - Monitoring::Plugin


check_end2end.pl: plugin to perform a web navigation (with time thresholds)

    Requires:

        - Config::General

        - Data::Dumper (only if run with -d)

        - HTTP::Headers

        - LWP::UserAgent

        - Monitoring::Plugin

        - URI::URL

        - (optional, for debug) Data::Dumper

    If you want to specify a proxy for scheme XXX (for example: http), you need to install:

        - LWP::Protocol::XXX  (with XXX == proxyed scheme)


