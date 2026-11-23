#!/bin/bash
# Proves the SwiftUI Layer generates compiles. Runs GeneratedCodeExportTests, which writes
# generated files for each layout and title setting into a temporary folder, then typechecks
# each folder's files with swiftc. Exits 0 only when every file typechecks.
#
# LAYER_SIMULATOR and LAYER_DERIVED_DATA override the simulator and DerivedData folder.
set -euo pipefail

cd "$(dirname "$0")/.."
SIMULATOR="${LAYER_SIMULATOR:-Layer iPad Pro 11 (semantic-tree)}"
DERIVED_DATA="${LAYER_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree}"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

TEST_RUNNER_LAYER_CODE_OUT="$OUT" xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation -only-testing:LayerTests/GeneratedCodeExportTests >"$OUT/xcodebuild.log" 2>&1 \
  || { tail -40 "$OUT/xcodebuild.log"; echo "The export test failed" >&2; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
total=0
failed=0
for folder in "$OUT"/*/; do
  [ -d "$folder" ] || continue
  files=("$folder"*.swift)
  [ -e "${files[0]}" ] || continue
  if xcrun swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios27.0-simulator "${files[@]}"; then
    total=$((total + ${#files[@]}))
  else
    echo "Typecheck failed in $(basename "$folder")" >&2
    failed=1
  fi
done

if [ "$total" -eq 0 ]; then echo "No generated files were written" >&2; exit 1; fi
if [ "$failed" -ne 0 ]; then exit 1; fi
echo "$total files typecheck"
