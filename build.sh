#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$root/build}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
app="$output/Word Relay.app"
scratch="$(mktemp -d "$output/.wordrelay.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/Word Relay.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$root/Resources/Info.plist" "$bundle/Contents/"
cp "$root/Resources/"{words.txt,words-extra.txt,ESDB-Copyright.txt,WordRelay.icns,Fredoka.ttf,Fredoka-OFL.txt} "$bundle/Contents/Resources/"
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$arch-apple-macosx14.0" \
        "$root"/Sources/*.swift -o "$scratch/WordRelay-$arch"
done
xcrun lipo -create "$scratch/WordRelay-arm64" "$scratch/WordRelay-x86_64" \
    -output "$bundle/Contents/MacOS/WordRelay"
xattr -cr "$bundle"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
if [[ -e "$app" ]]; then
    mv "$app" "$scratch/previous.app"
fi
mv "$bundle" "$app"
printf '%s\n' "$app"
