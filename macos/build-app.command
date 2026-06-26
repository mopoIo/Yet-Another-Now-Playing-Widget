#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="Yet Another Now Playing Widget.app"
ZIP="$(cd .. && pwd)/Yet Another Now Playing Widget (macOS).zip"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

mkdir -p "$BUILD/$APP/Contents/MacOS" "$BUILD/$APP/Contents/Resources"

# build both arches and fuse them so one app runs everywhere
swiftc -O -target arm64-apple-macos12.0  nowplaying.swift -o "$BUILD/np-arm64"
swiftc -O -target x86_64-apple-macos12.0 nowplaying.swift -o "$BUILD/np-x86_64"
lipo -create "$BUILD/np-arm64" "$BUILD/np-x86_64" -output "$BUILD/$APP/Contents/MacOS/nowplaying"

cp Info.plist "$BUILD/$APP/Contents/Info.plist"
cp -R ../wwwroot "$BUILD/$APP/Contents/Resources/wwwroot"

xattr -cr "$BUILD/$APP"
codesign --force -s - "$BUILD/$APP"
codesign --verify --strict "$BUILD/$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILD/$APP" "$ZIP"
echo "Built: $ZIP"
