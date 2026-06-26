#!/bin/bash
# builds, then launches the menu bar app - it lives in the status bar, quit from its menu
cd "$(dirname "$0")"
swiftc -O nowplaying.swift -o nowplaying || { echo "Build failed - see the errors above."; exit 1; }
./nowplaying "$@"
