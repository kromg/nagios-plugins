# nagios-plugins

Collection of plugins for Nagios.


check_end2end.pl: plugin to perform a web navigation (with time thresholds)

    Requires:

        - Config::General

        - HTTP::Headers

        - LWP::UserAgent

        - Monitoring::Plugin

        - URI::URL

        - (optional, for debug) Data::Dumper

    If you want to specify a proxy for scheme XXX (for example: http), you need to install:

        - LWP::Protocol::XXX  (with XXX == proxyed scheme)


