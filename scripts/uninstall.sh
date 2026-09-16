#!/usr/bin/env bash
# Remove the binaries previously copied into /usr/local/bin.
#
#   sudo scripts/uninstall.sh

set -euo pipefail

dest="${DESTDIR:-}/usr/local/bin"
bins=(prolua)

rm_cmd=(rm -f)
if [ "$(id -u)" -ne 0 ]; then
    rm_cmd=(sudo "${rm_cmd[@]}")
fi

for name in "${bins[@]}"; do
    path="$dest/$name"
    if [ -e "$path" ] || [ -L "$path" ]; then
        "${rm_cmd[@]}" "$path"
        echo "removed $path"
    else
        echo "not installed: $path"
    fi
done
