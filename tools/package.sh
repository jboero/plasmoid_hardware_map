#!/usr/bin/env bash
# Build the .plasmoid archive for KDE Store upload.
#
# A .plasmoid is just a zip of the package directory with metadata.json at its
# root. Note this ships the APPLET ONLY - the root collector cannot be
# installed by the store, so the listing must link back to the repository.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$SRC/plasmoid/org.kde.dimmMceMonitor"
VER="$(python3 -c "import json;print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
OUT="$SRC/dist/plasmoid_hardware_map-$VER.plasmoid"

mkdir -p "$SRC/dist"
rm -f "$OUT"
( cd "$PKG" && zip -qr "$OUT" . -x '*~' '*.bak' '.*' )

echo "built $OUT"
unzip -l "$OUT" | tail -3
echo
echo "Sanity check - metadata.json must be at the archive root:"
unzip -l "$OUT" | grep -q ' metadata.json$' && echo "  OK" || { echo "  MISSING"; exit 1; }
