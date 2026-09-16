#!/usr/bin/env bash
# Run a command under an address-space limit, in kilobytes: limitmem.sh <kB> cmd args...
ulimit -v "$1" || exit 1
shift
exec "$@"
