#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/../Voice Command Agent.app"

mkdir -p "$APP/Contents/MacOS"
swiftc \
  -parse-as-library \
  -swift-version 5 \
  -framework AppKit \
  -framework AVFoundation \
  -framework ApplicationServices \
  -framework Speech \
  "$ROOT/VoiceCommandAgent.swift" \
  -o "$APP/Contents/MacOS/VoiceCommandAgent"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

printf 'Built: %s\n' "$APP"
