#!/bin/sh
# Builds and runs the macOS voice benchmark harness. Apple Intelligence calls fail in the
# iPadOS Simulator, so how well the on-device model carries out spoken commands is
# measured here instead, compiling the app's own voice rules, tools and canvas picture for
# macOS. Those three files need nothing else from the app.
#
# Usage: Tools/VoiceBenchmarkHarness/run.sh [baseline|sampled|required|examples|canvasfirst|quoted|commandfirst]
#        Tools/VoiceBenchmarkHarness/run.sh latency [runs] [instructions,plain,quoted,quotedkeep,commandfirst]   (commands in a row)
# Results and what they led to: docs/benchmarks/voice-on-device.md
set -eu
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"
BIN="/tmp/VoiceBenchmarkHarness"

swiftc \
    -parse-as-library \
    -target arm64-apple-macos27.0 \
    -O \
    "$REPO_ROOT/Layer/Voice/VoiceTools.swift" \
    "$REPO_ROOT/Layer/Voice/VoiceRules.swift" \
    "$REPO_ROOT/Layer/Voice/CanvasPicture.swift" \
    "$REPO_ROOT/Tools/VoiceBenchmarkHarness/Harness.swift" \
    -o "$BIN"

exec "$BIN" "$@"
