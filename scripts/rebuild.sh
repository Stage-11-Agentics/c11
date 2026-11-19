#!/bin/bash
# Rebuild and restart c11 app

set -e

cd "$(dirname "$0")/.."

# Path-scoped so a name kill cannot hit c11. Pattern contains c11 and .app/Contents/MacOS/.
pkill -9 -f "c11.app/Contents/MacOS/c11" 2>/dev/null || true

# Build
swift build

# Copy the package product into the c11 bundle. The SwiftPM executable stays named c11.
mkdir -p .build/debug/c11.app/Contents/MacOS
cp .build/debug/c11 .build/debug/c11.app/Contents/MacOS/c11

# Open the app
open .build/debug/c11.app
