#!/usr/bin/bash
# vim: se ts=4 et syn=sh:

# gen_doc.sh - mangle help message to be pasted on Nagios Exchange site
#
#     Copyright (C) 2016 Giacomo Montagner <giacomo@entirelyunlike.net>
#
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#
#   CHANGELOG:
#
#       2016-08-25T10:08:15+02:00
#           First release.
#

function die() {
    echo "FATAL :: $*" >&2
    exit 1
}

function convert() {
    sed -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

[ "$1" ] || die "Usage: $( basename $0 ) <plugin>"
plugin="$1"

BASEDIR="$(readlink -f $(dirname $0))"
PLUGINDIR="$(readlink -f $BASEDIR/..)"
DOCDIR="$(readlink -f $BASEDIR/../doc)"

docname="$DOCDIR/${plugin//./_}.txt"
[ -f "$docname" ] && cat "$docname" | convert

cat <<-EOH

	SYNOPSYS
	\$ $plugin -h
EOH

$PLUGINDIR/$plugin -h | convert

