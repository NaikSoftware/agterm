#!/bin/sh
# Exits 0 only when every agterm match is in skip.txt and every skip.txt credit rule still matches.
exec "$(dirname "$0")/rename.sh" --check
