#!/bin/sh
# Compares the screen generator's old prompt with ScreenPrompt's compact one on the
# on-device Apple Intelligence model, natively on macOS (calls fail in the simulator).
# Each brief is written N times by each prompt; every screen is printed with its scores,
# then a summary line per prompt. See docs/benchmarks/screen-prompt.md.
#
# Usage: Tools/ScreenBenchmarkHarness/run.sh [runs per brief, default 1]
set -eu
cd "$(dirname "$0")/../.."
R="$(pwd)"
BIN="/tmp/ScreenBenchmarkHarness"
swiftc -parse-as-library -target arm64-apple-macos27.0 -O \
    "$R/Layer/Model/Design.swift" "$R/Layer/Model/ShapeKind.swift" "$R/Layer/Components/ComponentSpec.swift" "$R/Layer/Components/Catalogue.swift" \
    "$R/Layer/Document/JSONValue.swift" "$R/Layer/Sketch/PromptOverrides.swift" "$R/Layer/Sketch/SketchAnalyzer.swift" \
    "$R/Layer/Sketch/SketchInterpreter.swift" "$R/Layer/Sketch/ComponentRule.swift" "$R/Layer/Sketch/GlyphMatcher.swift" \
    "$R/Layer/Sketch/HandwritingRecognizer.swift" "$R/Layer/Sketch/AppleIntelligenceInterpreter.swift" \
    "$R/Layer/Sketch/ScreenPrompt.swift" "$R/Layer/Model/ScreenBlueprint.swift" \
    "$R/Layer/Tree/LookWords.swift" "$R/Layer/Tree/LayerNode.swift" "$R/Layer/Tree/LayerNode+Coding.swift" \
    "$R/Tools/SketchBenchmarkHarness/Stubs.swift" "$R/Tools/Shared/RotationStub.swift" "$R/Tools/ScreenBenchmarkHarness/LayoutStubs.swift" \
    "$R/Tools/ScreenBenchmarkHarness/Harness.swift" -o "$BIN"
exec "$BIN" "$@"
