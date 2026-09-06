#!/bin/sh
# Install moveto from this directory to /usr/local. Needs root.
#
#     sudo tools/moveto/install.sh
#
# This directory is the SOURCE; /usr/local holds a copy. They can drift, and
# nothing detects it — re-run this after changing anything here.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

install -d -m 755 /usr/local/share/moveto
install -m 755 "$here/moveto" /usr/local/bin/moveto
install -m 755 "$here/enter"  /usr/local/share/moveto/enter
install -m 644 "$here/rc"     /usr/local/share/moveto/rc

echo "moveto installed. Try: moveto --list"
