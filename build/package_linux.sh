#!/bin/bash
# Package a desktop build into a distributable tarball for Linux.
# Usage: package_linux.sh <build_dir> <output_dir>

set -e

BUILD_DIR="$1"
OUTPUT_DIR="$2"

if [ -z "$BUILD_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: package_linux.sh <build_dir> <output_dir>"
    exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory not found: $BUILD_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Determine app name from the executable in bin/
APP_NAME=$(ls "$BUILD_DIR/bin/" | head -1)
if [ -z "$APP_NAME" ]; then
    echo "Error: No executable found in $BUILD_DIR/bin/"
    exit 1
fi

ARCHIVE_NAME="${APP_NAME}-linux-x86_64.tar.gz"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

echo "Creating Linux package: $ARCHIVE_PATH"

# Create tarball preserving directory structure
tar -czf "$ARCHIVE_PATH" -C "$(dirname "$BUILD_DIR")" "$(basename "$BUILD_DIR")"

echo "Package created: $ARCHIVE_PATH"
echo "Size: $(du -h "$ARCHIVE_PATH" | cut -f1)"
