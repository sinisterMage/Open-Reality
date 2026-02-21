#!/bin/bash
# Package a desktop build into a distributable ZIP for Windows.
# Usage: package_windows.sh <build_dir> <output_dir>
#
# This script can be run from WSL, Git Bash, or any bash-compatible shell.

set -e

BUILD_DIR="$1"
OUTPUT_DIR="$2"

if [ -z "$BUILD_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: package_windows.sh <build_dir> <output_dir>"
    exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory not found: $BUILD_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Determine app name from the executable in bin/
APP_NAME=$(ls "$BUILD_DIR/bin/"*.exe 2>/dev/null | head -1 | xargs basename 2>/dev/null | sed 's/\.exe$//')
if [ -z "$APP_NAME" ]; then
    APP_NAME=$(ls "$BUILD_DIR/bin/" | head -1)
fi

if [ -z "$APP_NAME" ]; then
    echo "Error: No executable found in $BUILD_DIR/bin/"
    exit 1
fi

ARCHIVE_NAME="${APP_NAME}-windows-x64.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

echo "Creating Windows package: $ARCHIVE_PATH"

cd "$(dirname "$BUILD_DIR")"
zip -r "$ARCHIVE_PATH" "$(basename "$BUILD_DIR")"

echo "Package created: $ARCHIVE_PATH"
echo "Size: $(du -h "$ARCHIVE_PATH" | cut -f1)"
