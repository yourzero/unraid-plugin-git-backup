#!/bin/bash
# build.sh — Package the plugin for distribution
#
# Creates a .txz archive in archive/ that the .plg manifest downloads.
# Run this before tagging a release on GitHub.

set -euo pipefail

VERSION="${1:-$(date +%Y.%m.%d)}"
PLUGIN="git-backup"
ARCHIVE_DIR="archive"
OUTPUT="$ARCHIVE_DIR/${PLUGIN}-${VERSION}.txz"

echo "Building ${PLUGIN} v${VERSION}..."

# Create archive directory
mkdir -p "$ARCHIVE_DIR"

# Build the .txz from source/
cd source
tar -cJf "../$OUTPUT" .
cd ..

echo "Created: $OUTPUT"
echo "Size: $(du -h "$OUTPUT" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Update version in git-backup.plg"
echo "  2. Commit and push"
echo "  3. Create GitHub release with tag v${VERSION}"
echo "  4. Upload $OUTPUT to the release"
