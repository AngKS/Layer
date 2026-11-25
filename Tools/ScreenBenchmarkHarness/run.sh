#!/bin/sh
# Builds and runs the screen benchmark harness: a Swift package (Package.swift) that links the
# A2UI SDK and compiles the app's own outline and A2UI parsers, prompts and hosted model client
# for macOS. The on-device Apple Intelligence model is measured here, natively, since its calls
# fail in the simulator. See docs/benchmarks/screen-prompt.md.
#
# Usage:
#   Tools/ScreenBenchmarkHarness/run.sh check
#       builds, scores one canned outline answer and one canned A2UI answer, with no model, and holds the
#       hosted-default rule (HostedFormatRule) to its four cases.
#   Tools/ScreenBenchmarkHarness/run.sh outline [runs per brief, default 1]
#       the on-device model with ScreenPrompt's compact prompt, over the 8 briefs.
#   Tools/ScreenBenchmarkHarness/run.sh hosted <LM Studio model id> <outline|a2ui> [runs per brief]
#       a model served by LM Studio, through HostedModelClient, with no key.
#   Tools/ScreenBenchmarkHarness/run.sh hosted <LM Studio model id> both [runs per brief]
#       both formats, one after the other on each brief (A2UI first on the odd ones); each format's summary, then
#       "hosted default: ..." from HostedFormatRule.
#   Tools/ScreenBenchmarkHarness/run.sh rescore <log>
#       scores again, with today's readers and no model, every A2UI answer a hosted run printed to <log>.
set -eu
cd "$(dirname "$0")/../.."
R="$(pwd)"
H="$R/Tools/ScreenBenchmarkHarness"
APP="$H/Sources/ScreenBenchmarkHarness/App"

# The app's files, copied rather than linked: a package can't reach outside its own folder.
# A file that won't compile on macOS gets a stub in Tools/Shared/, never a change to suit this.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -p "$R"/Layer/Tree/*.swift "$R"/Layer/A2UI/*.swift "$STAGE/"
cp -p "$R/Layer/Model/Design.swift" "$R/Layer/Model/ShapeKind.swift" "$R/Layer/Model/TurnedRect.swift" "$STAGE/"
cp -p "$R/Layer/Components/ComponentSpec.swift" "$R/Layer/Components/Catalogue.swift" "$STAGE/"
cp -p "$R/Layer/Document/JSONValue.swift" "$STAGE/"
cp -p "$R/Layer/Sketch/PromptOverrides.swift" "$R/Layer/Sketch/ScreenPrompt.swift" \
    "$R/Layer/Sketch/ScreenStream.swift" "$R/Layer/Sketch/A2UIPrompt.swift" "$STAGE/"
cp -p "$R/Layer/Providers/HostedModelClient.swift" "$R/Layer/Providers/HostedProvider.swift" "$STAGE/"
cp -p "$R/Tools/SketchBenchmarkHarness/Stubs.swift" "$R"/Tools/Shared/*.swift "$STAGE/"
mkdir -p "$APP"
# Only changed files are rewritten, so the build stays incremental.
rsync -a --delete "$STAGE/" "$APP/"
# `exec` runs no EXIT trap, so the copies go now.
rm -rf "$STAGE"
trap - EXIT

exec swift run -c release --package-path "$H" ScreenBenchmarkHarness "$@"
