#!/bin/bash
# Rebuild and restart c11 app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "c11" 2>/dev/null || true
pkill -9 -f "cmux" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/c11 .build/debug/c11.app/Contents/MacOS/

# Open the app
open .build/debug/c11.app
