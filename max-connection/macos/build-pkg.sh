#!/bin/bash
# Builds the Max Connection macOS installer package (runs on macOS; used by GitHub Actions).
# The package carries no payload, only the postinstall script and the connection helper,
# so one universal .pkg serves Apple silicon and Intel Macs.
set -euo pipefail
VERSION="${1:-0.1.0}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../dist/max-connection"
mkdir -p "$OUT"
chmod 0755 "$HERE/scripts/postinstall" "$HERE/scripts/connection-helper.sh"
sed -i '' "s/^VERSION=\".*\"/VERSION=\"$VERSION\"/" "$HERE/scripts/postinstall"
pkgbuild --nopayload \
  --scripts "$HERE/scripts" \
  --identifier io.akior.max-connection \
  --version "$VERSION" \
  "$OUT/Max-Connection-$VERSION-macos.pkg"
echo "Built $OUT/Max-Connection-$VERSION-macos.pkg"
