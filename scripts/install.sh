#!/usr/bin/env bash
# Copy the built binaries from zig-out/bin into /usr/local/bin.
#
#   zig build
#   sudo scripts/install.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/zig-out/bin"
dest="${DESTDIR:-}/usr/local/bin"
bins=(prolua)

missing=0
for name in "${bins[@]}"; do
    if [ ! -x "$src/$name" ]; then
        echo "missing $src/$name (run 'zig build')" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    exit 1
fi

install_cmd=(install -m 755)
if [ "$(id -u)" -ne 0 ]; then
    install_cmd=(sudo "${install_cmd[@]}")
fi

"${install_cmd[@]}" -d "$dest"
for name in "${bins[@]}"; do
    "${install_cmd[@]}" "$src/$name" "$dest/$name"
    echo "installed $dest/$name"
done
