#!/bin/sh
# Builds and runs the macOS sketch benchmark harness. Apple Intelligence calls fail in the
# iPadOS Simulator (see memory note `layer-apple-intelligence-findings`), so the
# model-dependent parts of the benchmark run here instead, compiling the real
# `Layer/Sketch` files for macOS with stubs for the two UIKit/PencilKit-only types they
# transitively need.
#
# Usage: Tools/SketchBenchmarkHarness/run.sh <generate|run|healthcheck> [args...]
set -eu
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"
BIN="/tmp/SketchBenchmarkHarness"

swiftc \
    -D DEBUG \
    -parse-as-library \
    -target arm64-apple-macos27.0 \
    -O \
    "$REPO_ROOT/Layer/Model/Design.swift" \
    "$REPO_ROOT/Layer/Model/ShapeKind.swift" \
    "$REPO_ROOT/Layer/Components/ComponentSpec.swift" \
    "$REPO_ROOT/Layer/Components/Catalogue.swift" \
    "$REPO_ROOT/Layer/Tree/DesignTokens.swift" \
    "$REPO_ROOT/Layer/Document/JSONValue.swift" \
    "$REPO_ROOT/Layer/Debug/SketchSamples.swift" \
    "$REPO_ROOT/Layer/Debug/SketchBenchmark.swift" \
    "$REPO_ROOT/Layer/Sketch/PromptOverrides.swift" \
    "$REPO_ROOT/Layer/Sketch/SketchAnalyzer.swift" \
    "$REPO_ROOT/Layer/Sketch/SketchInterpreter.swift" \
    "$REPO_ROOT/Layer/Sketch/GlyphMatcher.swift" \
    "$REPO_ROOT/Layer/Sketch/HandwritingRecognizer.swift" \
    "$REPO_ROOT/Layer/Sketch/SketchContextTool.swift" \
    "$REPO_ROOT/Layer/Sketch/ComponentRule.swift" \
    "$REPO_ROOT/Layer/Sketch/SketchReadingLog.swift" \
    "$REPO_ROOT/Layer/Sketch/RuleInterpreter.swift" \
    "$REPO_ROOT/Layer/Sketch/SketchEngine.swift" \
    "$REPO_ROOT/Layer/Sketch/AppleIntelligenceInterpreter.swift" \
    "$REPO_ROOT/Tools/SketchBenchmarkHarness/Stubs.swift" \
    "$REPO_ROOT/Tools/Shared/RotationStub.swift" \
    "$REPO_ROOT/Tools/SketchBenchmarkHarness/Generate.swift" \
    "$REPO_ROOT/Tools/SketchBenchmarkHarness/Harness.swift" \
    -o "$BIN"

exec "$BIN" "$@"
