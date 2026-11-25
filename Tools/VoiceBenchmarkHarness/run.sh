#!/bin/sh
# Builds and runs the macOS voice benchmark harness. Apple Intelligence calls fail in the
# iPadOS Simulator, so how well the on-device model carries out spoken commands is
# measured here instead, compiling the app's own voice rules, tools and canvas picture for
# macOS. Those three files need nothing else from the app but `Rotation.shown`, which
# Tools/Shared/RotationStub.swift copies.
#
# Usage: Tools/VoiceBenchmarkHarness/run.sh check   (builds, and puts a call's tools and canvas picture together, with no model)
#        Tools/VoiceBenchmarkHarness/run.sh [baseline|sampled|required|examples|canvasfirst|quoted|commandfirst]
#        Tools/VoiceBenchmarkHarness/run.sh newtools [runs] [baseline|sampled]   (the 2026-11-18 tools, each case several times)
#        Tools/VoiceBenchmarkHarness/run.sh structure [runs] [baseline|sampled]   (plan 6's structure tools over a nested screen, each case several times)
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
    "$REPO_ROOT/Tools/Shared/RotationStub.swift" \
    "$REPO_ROOT/Tools/VoiceBenchmarkHarness/Harness.swift" \
    -o "$BIN"

exec "$BIN" "$@"
