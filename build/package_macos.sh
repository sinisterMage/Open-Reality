#!/bin/bash
# Package a desktop build into a distributable .app bundle for macOS.
# Usage: package_macos.sh <build_dir> <output_dir>

set -e

BUILD_DIR="$1"
OUTPUT_DIR="$2"

if [ -z "$BUILD_DIR" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: package_macos.sh <build_dir> <output_dir>"
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

# The .app bundle should already exist if desktop_build.jl ran on macOS
APP_BUNDLE="$(dirname "$BUILD_DIR")/${APP_NAME}.app"

if [ -d "$APP_BUNDLE" ]; then
    echo "Found .app bundle: $APP_BUNDLE"
    # Create a DMG or zip
    ARCHIVE_NAME="${APP_NAME}-macos.zip"
    ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

    echo "Creating macOS package: $ARCHIVE_PATH"
    cd "$(dirname "$APP_BUNDLE")"
    zip -r "$ARCHIVE_PATH" "$(basename "$APP_BUNDLE")"

    echo "Package created: $ARCHIVE_PATH"
    echo "Size: $(du -h "$ARCHIVE_PATH" | cut -f1)"
else
    echo "No .app bundle found, creating tarball instead..."
    ARCHIVE_NAME="${APP_NAME}-macos.tar.gz"
    ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

    tar -czf "$ARCHIVE_PATH" -C "$(dirname "$BUILD_DIR")" "$(basename "$BUILD_DIR")"

    echo "Package created: $ARCHIVE_PATH"
fi
