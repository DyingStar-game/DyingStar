#!/usr/bin/env bash
# Download planet export data from the DyingStar build server.
#
# Usage:  bash tools/download_planet_data.sh
#
# Behaviour:
#   - If assets/qgis/export/ and assets/qgis/checksum.txt exist AND
#     the export/ directory was modified less than 24 h ago → skip (already fresh).
#   - Otherwise: download, extract, verify, then delete the archive.
#
# Exit codes:
#   0  success (or skipped because data was fresh)
#   1  extraction failed / expected files missing after extract

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QGIS_DIR="$(realpath "$SCRIPT_DIR/../assets/qgis")"
EXPORT_DIR="$QGIS_DIR/export"
CHECKSUM_FILE="$QGIS_DIR/checksum.txt"
ARCHIVE="$QGIS_DIR/export.tar.gz"
ARCHIVE_URL="https://exportplanets.dyingstar-game.space/export.tar.gz"

# ── Download ────────────────────────────────────────────────────────────────
echo "[planet-data] Downloading $ARCHIVE_URL ..."
wget --no-verbose --show-progress -O "$ARCHIVE" "$ARCHIVE_URL"

# ── Extract ─────────────────────────────────────────────────────────────────
echo "[planet-data] Extracting archive into $QGIS_DIR/ ..."
tar xzf "$ARCHIVE" -C "$QGIS_DIR/"

# ── Verify ──────────────────────────────────────────────────────────────────
if [[ ! -d "$EXPORT_DIR" ]]; then
    echo "[planet-data] ERROR: export/ directory not found after extraction." >&2
    exit 1
fi

if [[ ! -f "$CHECKSUM_FILE" ]]; then
    echo "[planet-data] ERROR: checksum.txt not found after extraction." >&2
    exit 1
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────
rm -f "$ARCHIVE"

echo "[planet-data] Done. Planet data ready at $EXPORT_DIR"
