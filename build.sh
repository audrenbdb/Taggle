#!/bin/bash
set -e

APP_NAME="Taggle"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile
swiftc -O \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -framework Cocoa \
    -framework Carbon \
    -framework CoreGraphics \
    Taggle/main.swift

# Copy Info.plist
cp Taggle/Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "Built: $APP_BUNDLE"
echo ""
echo "To install: cp -r $APP_BUNDLE /Applications/"
echo "To run:     open $APP_BUNDLE"
